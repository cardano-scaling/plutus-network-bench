# Pinned aiken-lang/stdlib source, placed into build/packages/ so the aiken
# build runs fully offline inside the nix sandbox (no network fetch).
# Version must match aiken/aiken.toml and aiken/aiken.lock (v3.1.0).
{ pkgs }:
pkgs.fetchFromGitHub {
  owner = "aiken-lang";
  repo = "stdlib";
  rev = "v3.1.0";
  hash = "sha256-CQGjyi/UBK6PquKkc2TPjoAwrTqdd8MeYB2QzrciQmc=";
}
