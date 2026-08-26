{
  description =
    "General worst-case Plutus V3 transaction benchmark: nix-built validators + a cardano-cli setup/submit/calibrate harness, retargetable to any Cardano network.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # Pinned aiken fork exposing native bls12_381_G1_multiScalarMul + replicateByte.
    # Do NOT move off this rev without re-verifying that
    # `bls12_381_g1_multi_scalar_mul` and `replicate_byte` still compile.
    aiken.url =
      "github:cardano-scaling/aiken/178d444d757e40784a15986ccc93547c9cee529b";

    # Default cardano-cli source. Kept as its own input so the CLI version is
    # trivially swappable at build time:
    #   nix run .#setup-bench --override-input cardano-node github:IntersectMBO/cardano-node/<tag>
    # (and at runtime, without rebuilding, via the --cardano-cli flag / $CARDANO_CLI.)
    cardano-node.url = "github:IntersectMBO/cardano-node/10.5.1";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      perSystem = { system, pkgs, ... }:
        let
          aikenCli = inputs.aiken.packages.${system}.default;
          cardanoCli = inputs.cardano-node.packages.${system}.cardano-cli;

          stdlibSrc = import ./nix/stdlib.nix { inherit pkgs; };

          aikenSrc = pkgs.lib.cleanSourceWith {
            src = ./aiken;
            filter = path: _type:
              let b = baseNameOf path; in b != "build" && b != "artifacts";
          };

          validators = import ./nix/validators.nix {
            inherit pkgs aikenCli stdlibSrc aikenSrc;
            applyScript = ./scripts/lib/apply-instances.py;
          };

          scriptsSrc = pkgs.lib.cleanSource ./scripts;

          apps' = import ./nix/apps.nix {
            inherit pkgs aikenCli cardanoCli scriptsSrc;
            validators = validators.applied;
          };
        in
        {
          packages = {
            aiken = aikenCli;
            cardano-cli = cardanoCli;
            validators-base = validators.base;
            validators = validators.applied;
            setup-bench = apps'.setup-bench;
            calibrate = apps'.calibrate;
            run-bench = apps'.run-bench;
            local-devnet = apps'.local-devnet;
            default = validators.applied;
          };

          apps.setup-bench  = { type = "app"; program = "${apps'.setup-bench}/bin/setup-bench"; };
          apps.calibrate    = { type = "app"; program = "${apps'.calibrate}/bin/calibrate"; };
          apps.run-bench    = { type = "app"; program = "${apps'.run-bench}/bin/run-bench"; };
          apps.local-devnet = { type = "app"; program = "${apps'.local-devnet}/bin/local-devnet"; };

          devShells.default =
            import ./nix/devshell.nix { inherit pkgs aikenCli cardanoCli; };
        };
    };
}
