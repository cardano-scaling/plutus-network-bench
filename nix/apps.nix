# Wraps the bash tools as self-contained executables: the scripts/ tree is
# installed to libexec, runtime dependencies (cardano-cli, jq, python3, aiken, …)
# are put on PATH, and PLUTUS_BENCH_ARTIFACTS points at the nix-built validators.
{ pkgs, aikenCli, cardanoCli, validators, scriptsSrc }:
let
  lib = pkgs.lib;
  # Our helper tools go on the FRONT of PATH (we want exactly these). cardano-cli
  # is deliberately NOT here — see `fallback` below.
  helperInputs = [
    pkgs.bash
    aikenCli
    pkgs.jq
    pkgs.python3
    pkgs.coreutils
    pkgs.gnused
    pkgs.gawk
  ];

  # local-devnet deliberately does NOT bundle a cardano-cli/node: it uses the
  # ones the user brings on PATH (e.g. the ouroboros-leios dev-testnet devshell),
  # overridable via --cardano-cli / --cardano-node. It only needs curl + jq etc.
  devnetInputs = [ pkgs.bash pkgs.curl pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gawk pkgs.python3 ];

  # `inputs` go on the front of PATH; `fallback` goes on the BACK so the user's
  # own binaries (e.g. the leios cardano-cli in a dev-testnet shell) take
  # precedence, with our pinned build used only if none is on PATH.
  mkApp = { name, script, inputs ? helperInputs, fallback ? [ cardanoCli ], artifacts ? true }:
    pkgs.stdenv.mkDerivation {
      pname = name;
      version = "0.1.0";
      src = scriptsSrc;
      nativeBuildInputs = [ pkgs.makeWrapper ];
      dontConfigure = true;
      dontBuild = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/libexec/pnb $out/bin
        cp -r . $out/libexec/pnb/
        chmod +x $out/libexec/pnb/*.sh || true
        makeWrapper $out/libexec/pnb/${script} $out/bin/${name} \
          --prefix PATH : ${lib.makeBinPath inputs} \
          ${lib.optionalString (fallback != []) "--suffix PATH : ${lib.makeBinPath fallback}"} \
          ${lib.optionalString artifacts "--set-default PLUTUS_BENCH_ARTIFACTS ${validators}"}
        runHook postInstall
      '';
    };
in
{
  setup-bench  = mkApp { name = "setup-bench"; script = "setup-bench.sh"; };
  calibrate    = mkApp { name = "calibrate";   script = "calibrate.sh"; };
  run-bench    = mkApp { name = "run-bench";   script = "run-bench.sh"; };
  local-devnet = mkApp { name = "local-devnet"; script = "local-devnet.sh";
                         inputs = devnetInputs; fallback = []; artifacts = false; };
}
