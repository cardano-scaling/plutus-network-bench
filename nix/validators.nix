# Two-stage validator build:
#   base    — `aiken build` of the unapplied blueprint. Runs fully offline: the
#             pinned stdlib is pre-populated into build/packages so aiken never
#             touches the network in the sandbox.
#   applied — `aiken blueprint apply` for N io_ref tags + N msm_main indices.
#             Operates purely on the local blueprint (no package resolution).
#
# Instance counts are overridable derivation args, so changing concurrency is a
# cached rebuild rather than a source edit.
{ pkgs
, aikenCli
, stdlibSrc
, aikenSrc
, applyScript
, nIoRef ? 16
, ioParamBytes ? 16000
, nMsmIndices ? 64
, namespace ? "plutus-bench"
}:
let
  packagesToml = pkgs.writeText "packages.toml" ''
    [[packages]]
    name = "aiken-lang/stdlib"
    version = "v3.1.0"
    source = "github"
  '';

  base = pkgs.stdenv.mkDerivation {
    pname = "plutus-network-bench-validators-base";
    version = "0.1.0";
    src = aikenSrc;
    nativeBuildInputs = [ aikenCli ];

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      chmod -R u+w .
      # Pre-populate the package cache so the build runs fully offline (no network
      # in the sandbox). Everything under build/ must be writable: aiken rewrites
      # packages.toml and lockfiles during resolution.
      mkdir -p build/packages/aiken-lang-stdlib
      cp -r --no-preserve=mode,ownership ${stdlibSrc}/. build/packages/aiken-lang-stdlib/
      cp ${packagesToml} build/packages/packages.toml
      chmod -R u+w build
      aiken build --trace-level silent
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp plutus.json $out/plutus.json
      runHook postInstall
    '';
  };

  applied = pkgs.stdenv.mkDerivation {
    pname = "plutus-network-bench-validators";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ aikenCli pkgs.python3 ];
    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      mkdir -p $out
      python3 ${applyScript} \
        --blueprint ${base}/plutus.json \
        --out $out \
        --namespace ${namespace} \
        --n-io-ref ${toString nIoRef} \
        --io-param-bytes ${toString ioParamBytes} \
        --n-msm-indices ${toString nMsmIndices}
      cp ${base}/plutus.json $out/plutus.json
      runHook postBuild
    '';
    dontInstall = true;
  };
in
{ inherit base applied; }
