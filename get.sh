#!/usr/bin/env bash
# =============================================================================
#  MCR Server OS — hosted one-liner bootstrap
#  Run on a fresh VPS:
#     curl -fsSL https://raw.githubusercontent.com/Xrack762/installer/main/get.sh | sudo bash
#     curl -fsSL https://raw.githubusercontent.com/Xrack762/installer/main/get.sh | sudo bash -s -- --domain example.com --email you@x.io
#  It downloads the whole installer suite from the GitHub repo and runs install.sh,
#  forwarding any extra arguments.
# =============================================================================
set -euo pipefail

# The suite tarball = the GitHub repo archive (all files). Override with MCR_SUITE_URL for a fork/branch/release.
SUITE_URL="${MCR_SUITE_URL:-https://github.com/Xrack762/installer/archive/refs/heads/main.tar.gz}"
# Expected sha256 of the tarball (filled in at release time; empty = skip-with-warning).
SUITE_SHA256="${MCR_SUITE_SHA256:-}"

say() { printf '\033[36m[mcr]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[mcr] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u 2>/dev/null || echo 0)" = "0" ] || die "run as root (pipe into 'sudo bash')"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "need curl or wget"
command -v tar  >/dev/null 2>&1 || die "need tar"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

say "Downloading MCR Server OS suite..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$SUITE_URL" -o suite.tar.gz
else
  wget -qO suite.tar.gz "$SUITE_URL"
fi

if [ -n "$SUITE_SHA256" ]; then
  got="$(sha256sum suite.tar.gz | awk '{print $1}')"
  [ "$got" = "$SUITE_SHA256" ] || die "suite sha256 mismatch (want $SUITE_SHA256 got $got)"
  say "suite sha256 verified"
else
  say "WARNING: no SUITE_SHA256 pinned; integrity not verified (set MCR_SUITE_SHA256)"
fi

mkdir -p suite
tar xzf suite.tar.gz -C suite
# tarball may have a top dir; find install.sh
install_sh="$(find suite -maxdepth 3 -name install.sh -type f | head -n1)"
[ -n "$install_sh" ] || die "install.sh not found in suite"
src_dir="$(dirname "$install_sh")"

say "Launching installer..."
chmod +x "$install_sh" "$src_dir/mcrctl" "$src_dir/mcr-agent" "$src_dir/uninstall.sh" 2>/dev/null || true
MCR_SRC_DIR="$src_dir" bash "$install_sh" "$@"
