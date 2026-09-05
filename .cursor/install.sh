#!/usr/bin/env bash
# Cloud Agent bootstrap for Project Marque.
#
# Idempotent: safe to run repeatedly and against a snapshot that already has the
# toolchains. Installs the pinned toolchains when they are missing, refreshes Go
# module state, and warms the gitignored Godot editor cache the headless suites
# need. Durable system tools land in /usr/local (already on PATH); per-checkout
# state (client/.godot, Go modules) is refreshed every run.
set -euo pipefail

GO_VERSION="1.27.0"
GODOT_VERSION="4.7.2"
GODOT_HASH="ed1daf0bf" # build id reported by `godot --version`, pinned in NOTES.md

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }

# Use sudo only when needed and available; fall back to plain when already root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

install_go() {
  if command -v go >/dev/null 2>&1 && [ "$(go env GOVERSION 2>/dev/null)" = "go${GO_VERSION}" ]; then
    log "Go ${GO_VERSION} already present"
    return
  fi
  log "installing Go ${GO_VERSION}"
  local tarball="/tmp/go${GO_VERSION}.linux-amd64.tar.gz"
  curl -fsSL -o "$tarball" "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  # Take precedence over any older /usr/bin/go on PATH.
  $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
  $SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

install_godot() {
  if command -v godot >/dev/null 2>&1 && godot --version 2>/dev/null | grep -q "^${GODOT_VERSION}\.stable.*${GODOT_HASH}"; then
    log "Godot ${GODOT_VERSION} already present"
    return
  fi
  log "installing Godot ${GODOT_VERSION}"
  local zip="/tmp/godot-${GODOT_VERSION}.zip"
  curl -fsSL -o "$zip" \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  local tmpdir
  tmpdir="$(mktemp -d)"
  unzip -o -q "$zip" -d "$tmpdir"
  $SUDO mv "$tmpdir/Godot_v${GODOT_VERSION}-stable_linux.x86_64" /usr/local/bin/godot
  $SUDO chmod +x /usr/local/bin/godot
  rm -rf "$zip" "$tmpdir"
}

install_powershell() {
  # The repository's canonical verification harnesses (scripts/*.ps1, including
  # the full-stack scripts/interop_test.ps1) are PowerShell.
  if command -v pwsh >/dev/null 2>&1; then
    log "PowerShell already present"
    return
  fi
  log "installing PowerShell"
  local deb="/tmp/packages-microsoft-prod.deb"
  # shellcheck disable=SC1091
  . /etc/os-release
  curl -fsSL -o "$deb" "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  $SUDO dpkg -i "$deb"
  rm -f "$deb"
  $SUDO apt-get update -qq
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq powershell
}

warm_godot_cache() {
  # client/.godot is gitignored and per-checkout. Without it, headless Godot
  # fails to parse scripts that name a global class_name (NOTES.md). The editor
  # import pass builds the cache.
  if [ -d "${REPO_ROOT}/client/.godot" ]; then
    log "Godot editor cache already warm"
    return
  fi
  log "warming Godot editor cache"
  godot --headless --path "${REPO_ROOT}/client" --editor --quit >/dev/null 2>&1 || true
  # The warm-up litters *.gd.uid companion files; they are not part of the repo.
  find "${REPO_ROOT}/client" -name '*.gd.uid' -delete 2>/dev/null || true
}

fetch_go_modules() {
  log "downloading Go modules"
  (cd "${REPO_ROOT}/server" && go mod download)
}

install_go
install_godot
install_powershell
fetch_go_modules
warm_godot_cache

log "bootstrap complete"
go version
godot --version
