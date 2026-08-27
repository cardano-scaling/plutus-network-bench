#!/usr/bin/env python3
"""Fit the knob->cost model and invert it to hit a target.

The msm_main cost is modelled as linear in the three CPU/mem knobs:

    ex_steps ~= a_n*n_points + a_k*k + a_m*m + c
    ex_mem   ~= b_n*n_points + b_k*k + b_m*m + d

`fit` reads calibration samples and produces least-squares coefficients (pure
Python normal equations; no numpy dependency). `solve` inverts the two fitted
lines to find (n_points, m) at k=1 that hit a target (ex_steps, ex_mem), then
converts n_points to a datum count.

  solve-knobs.py fit   --samples s.json --pparams pp.json --out calibration.json
  solve-knobs.py solve --calibration calibration.json \
                       --steps <int> --mem <int> --points-per-datum <int>
"""

import argparse
import json
import sys


# --- tiny linear algebra (no numpy) -------------------------------------------
def solve_linear(a, b):
    """Solve a*x = b for square matrix a (list of rows) via Gaussian elim."""
    n = len(a)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(m[r][col]))
        if abs(m[piv][col]) < 1e-12:
            raise ValueError("singular system (need more varied samples)")
        m[col], m[piv] = m[piv], m[col]
        pv = m[col][col]
        m[col] = [v / pv for v in m[col]]
        for r in range(n):
            if r != col:
                f = m[r][col]
                m[r] = [v - f * m[col][k] for k, v in enumerate(m[r])]
    return [m[i][n] for i in range(n)]


def least_squares(rows, ys):
    """rows: design matrix (each row a feature vector); ys: targets. Returns
    coefficients minimising ||rows*coef - ys||^2 via normal equations."""
    p = len(rows[0])
    ata = [[sum(rows[r][i] * rows[r][j] for r in range(len(rows)))
            for j in range(p)] for i in range(p)]
    aty = [sum(rows[r][i] * ys[r] for r in range(len(rows))) for i in range(p)]
    return solve_linear(ata, aty)


def fit_axis(samples, key):
    # features: [n_points, k, m, 1]
    rows = [[s["n_points"], s["k"], s["m"], 1.0] for s in samples]
    ys = [float(s[key]) for s in samples]
    a_n, a_k, a_m, c = least_squares(rows, ys)
    return {"a_n": a_n, "a_k": a_k, "a_m": a_m, "c": c}


def cmd_fit(args):
    samples = json.load(open(args.samples))
    samples = [s for s in samples if s.get("status", "ok") == "ok"]
    if len(samples) < 4:
        raise SystemExit(f"need >=4 ok samples to fit, have {len(samples)}")
    pp = json.load(open(args.pparams))
    out = {
        "schema_version": 1,
        "cost_model_source": "onchain",
        "limits": {
            "max_tx_ex_steps": pp["maxTxExecutionUnits"]["steps"],
            "max_tx_ex_mem": pp["maxTxExecutionUnits"]["memory"],
            "max_tx_size": pp["maxTxSize"],
        },
        "fits": {"steps": fit_axis(samples, "ex_steps"),
                 "mem": fit_axis(samples, "ex_mem")},
        "samples": samples,
    }
    json.dump(out, open(args.out, "w"), indent=2)
    fs, fm = out["fits"]["steps"], out["fits"]["mem"]
    print(f"steps ~= {fs['a_n']:.3g}*n + {fs['a_k']:.3g}*k + {fs['a_m']:.3g}*m + {fs['c']:.3g}")
    print(f"mem   ~= {fm['a_n']:.3g}*n + {fm['a_k']:.3g}*k + {fm['a_m']:.3g}*m + {fm['c']:.3g}")


def cmd_solve(args):
    cal = json.load(open(args.calibration))
    fs, fm = cal["fits"]["steps"], cal["fits"]["mem"]
    k = 1
    # two equations in (n, m):
    #   a_n_s*n + a_m_s*m = steps - c_s - a_k_s*k
    #   a_n_m*n + a_m_m*m = mem   - c_m - a_k_m*k
    A = [[fs["a_n"], fs["a_m"]], [fm["a_n"], fm["a_m"]]]
    B = [args.steps - fs["c"] - fs["a_k"] * k,
         args.mem - fm["c"] - fm["a_k"] * k]
    try:
        n, m = solve_linear(A, B)
    except ValueError:
        # mem axis nearly independent of n: solve m from mem, then n from steps
        m = (args.mem - fm["c"] - fm["a_k"] * k) / fm["a_m"]
        n = (args.steps - fs["c"] - fs["a_k"] * k - fs["a_m"] * m) / fs["a_n"]
    n = max(0, round(n)); m = max(0, round(m))

    # Clamp to the per-tx budget. The solved (n, m) can exceed a budget when the
    # requested (steps, mem) pair is jointly infeasible on this cost model — e.g.
    # saturating mem needs an `m` whose replicateByte work alone blows the steps
    # budget several times over. Reduce m (the steps-heavy knob) then n so both
    # predicted axes stay within budget, and warn with what was actually hit.
    def p_steps(nn, mm): return fs["a_n"] * nn + fs["a_k"] * k + fs["a_m"] * mm + fs["c"]
    def p_mem(nn, mm):   return fm["a_n"] * nn + fm["a_k"] * k + fm["a_m"] * mm + fm["c"]
    lim = cal.get("limits", {})
    # Clamp to a safety margin below the ceiling: the fit is an extrapolation, so
    # aiming at exactly 100% risks the odd tx tipping over maxTxExUnits (rejected).
    SAFETY = 0.98
    S = lim.get("max_tx_ex_steps"); M = lim.get("max_tx_ex_mem")
    Sc = S * SAFETY if S else None; Mc = M * SAFETY if M else None
    n0, m0 = n, m
    if S and M:
        caps = []
        if fs["a_m"] > 0: caps.append((Sc - fs["c"] - fs["a_k"] * k - fs["a_n"] * n) / fs["a_m"])
        if fm["a_m"] > 0: caps.append((Mc - fm["c"] - fm["a_k"] * k - fm["a_n"] * n) / fm["a_m"])
        if caps: m = max(0, min(m, int(min(caps))))
        if fs["a_n"] > 0:
            m_cap_n = int((Sc - fs["c"] - fs["a_k"] * k - fs["a_m"] * m) / fs["a_n"])
            n = max(0, min(n, m_cap_n))
        if (n, m) != (n0, m0):
            sys.stderr.write(
                "[solve-knobs] target infeasible within per-tx budget "
                f"(would be steps={p_steps(n0, m0)/S*100:.0f}% mem={p_mem(n0, m0)/M*100:.0f}%); "
                f"clamped to k={k} m={m} n={n} "
                f"(steps={p_steps(n, m)/S*100:.0f}% mem={p_mem(n, m)/M*100:.0f}% of budget)\n")

    n_datums = max(1, round(n / args.points_per_datum)) if n > 0 else 0
    out = {"k": k, "m": m, "n_points": n, "n_datums": n_datums,
           "predicted": {
               "ex_steps": fs["a_n"] * n + fs["a_k"] * k + fs["a_m"] * m + fs["c"],
               "ex_mem": fm["a_n"] * n + fm["a_k"] * k + fm["a_m"] * m + fm["c"]}}
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fit")
    f.add_argument("--samples", required=True)
    f.add_argument("--pparams", required=True)
    f.add_argument("--out", required=True)
    f.set_defaults(func=cmd_fit)
    s = sub.add_parser("solve")
    s.add_argument("--calibration", required=True)
    s.add_argument("--steps", type=int, required=True)
    s.add_argument("--mem", type=int, required=True)
    s.add_argument("--points-per-datum", type=int, required=True)
    s.set_defaults(func=cmd_solve)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
