# Wraps the bash tools as self-contained executables: the scripts/ tree is
# installed to libexec, runtime dependencies (cardano-cli, jq, python3, aiken, …)
# are put on PATH, and PLUTUS_BENCH_ARTIFACTS points at the nix-built validators.
{ pkgs, aikenCli, cardanoCli, validators, scriptsSrc }:
let
  lib = pkgs.lib;
  runtimeInputs = [
    pkgs.bash
    cardanoCli
    aikenCli
    pkgs.jq
    pkgs.python3
    pkgs.coreutils
    pkgs.gnused
    pkgs.gawk
  ];

  mkApp = { name, script }:
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
          --prefix PATH : ${lib.makeBinPath runtimeInputs} \
          --set-default PLUTUS_BENCH_ARTIFACTS ${validators}
        runHook postInstall
      '';
    };
in
{
  setup-bench = mkApp { name = "setup-bench"; script = "setup-bench.sh"; };
  calibrate   = mkApp { name = "calibrate";   script = "calibrate.sh"; };
  run-bench   = mkApp { name = "run-bench";   script = "run-bench.sh"; };
}
