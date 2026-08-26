{ pkgs, aikenCli, cardanoCli }:
pkgs.mkShell {
  packages = [
    aikenCli
    cardanoCli
    pkgs.jq
    pkgs.python3
    pkgs.coreutils
    pkgs.gnused
    pkgs.gawk
    pkgs.shellcheck
  ];
  shellHook = ''
    echo "== plutus-network-bench =="
    echo "  aiken:       $(aiken --version 2>/dev/null || echo MISSING)"
    echo "  cardano-cli: $(cardano-cli --version 2>/dev/null | head -1 || echo MISSING)"
  '';
}
