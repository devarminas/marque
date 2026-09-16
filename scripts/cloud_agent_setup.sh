#!/usr/bin/env bash
#
# Cloud Agent environment bootstrap for Project Marque.
#
# Provisions the exact toolchains the repo needs and/or prepares the checked-out
# source. It has two independent halves so it can serve both the container image
# build and the per-checkout install step:
#
#   cloud_agent_setup.sh --tools-only   Install Go 1.27, Godot 4.7 (headless),
#                                        and PowerShell 7 into /usr/local. Used
#                                        from the Dockerfile (runs as root).
#   cloud_agent_setup.sh --repo-only    Fetch Go modules, build the server, and
#                                        warm the Godot import cache. Used as the
#                                        environment `install` command.
#   cloud_agent_setup.sh                 Both halves (handy for a fresh local
#                                        Linux checkout).
#
# The toolchain half is idempotent: an already-correct toolchain is left alone.
# The Linux desktop is headless here; the Godot editor/headless binary runs, but
# windowed *_demo.ps1 captures need a real display and are out of scope. The
# headless suite and scripts/interop_test.ps1 are the full-stack proof paths.
set -euo pipefail

GO_VERSION="1.27.1"
GODOT_VERSION="4.7-stable"
PWSH_VERSION="7.6.6"

MODE="all"
case "${1:-}" in
  --tools-only) MODE="tools" ;;
  --repo-only)  MODE="repo" ;;
  "")           MODE="all" ;;
  *) echo "usage: $0 [--tools-only|--repo-only]"; exit 2 ;;
esac

# Run privileged steps directly when already root (container build), else sudo.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

fetch() {
  # fetch <url> <output>: curl with retries.
  curl -fsSL --retry 4 --retry-delay 2 -o "$2" "$1"
}

install_tools() {
  local arch tmp
  arch="$(uname -m)"
  [ "$arch" = "x86_64" ] || { echo "unsupported arch: $arch (expected x86_64)"; exit 1; }

  # A cold image may lack unzip/curl; the archives need them.
  if ! command -v unzip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends unzip curl ca-certificates
  fi

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
    echo "go ${GO_VERSION} already installed"
  else
    echo "installing go ${GO_VERSION}"
    fetch "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" "$tmp/go.tar.gz"
    $SUDO rm -rf /usr/local/go
    $SUDO tar -C /usr/local -xzf "$tmp/go.tar.gz"
  fi
  $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
  $SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

  if [ -x /usr/local/bin/godot ] && /usr/local/bin/godot --version --headless 2>/dev/null | grep -q "^${GODOT_VERSION%-stable}.stable"; then
    echo "godot ${GODOT_VERSION} already installed"
  else
    echo "installing godot ${GODOT_VERSION}"
    fetch "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" "$tmp/godot.zip"
    ( cd "$tmp" && unzip -o godot.zip )
    $SUDO install -m 0755 "$tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot
  fi

  if [ -x /opt/microsoft/powershell/7/pwsh ] && /opt/microsoft/powershell/7/pwsh --version 2>/dev/null | grep -q "PowerShell ${PWSH_VERSION}"; then
    echo "powershell ${PWSH_VERSION} already installed"
  else
    echo "installing powershell ${PWSH_VERSION}"
    fetch "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" "$tmp/pwsh.tar.gz"
    $SUDO rm -rf /opt/microsoft/powershell/7
    $SUDO mkdir -p /opt/microsoft/powershell/7
    $SUDO tar -xzf "$tmp/pwsh.tar.gz" -C /opt/microsoft/powershell/7
    $SUDO chmod +x /opt/microsoft/powershell/7/pwsh
  fi
  $SUDO ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh

  hash -r
  echo "--- toolchain versions ---"
  go version
  godot --version --headless
  pwsh --version
  gcc --version | head -1
}

bootstrap_repo() {
  echo "--- fetching go modules and building ---"
  ( cd "$ROOT_DIR/server" && go mod download && go build ./... )
  echo "--- warming godot import cache ---"
  # Warms client/.godot (gitignored) so headless script runs do not fail parsing
  # global class_name scripts on a cold checkout.
  godot --headless --path "$ROOT_DIR/client" --editor --quit >/dev/null 2>&1 || true
}

if [ "$MODE" = "tools" ] || [ "$MODE" = "all" ]; then install_tools; fi
if [ "$MODE" = "repo" ]  || [ "$MODE" = "all" ]; then bootstrap_repo; fi

echo "cloud_agent_setup: done ($MODE)"
