#!/usr/bin/env bash
#
# Cloud Agent environment bootstrap for Project Marque.
#
# Provisions the toolchains the repo needs and/or prepares the checked-out
# source. Two independent halves let it serve both the container image build and
# the per-checkout install step:
#
#   cloud_agent_setup.sh --tools-only   Install Go, Godot 4.7 (headless), and
#                                        PowerShell 7. Used from the Dockerfile
#                                        (runs as root).
#   cloud_agent_setup.sh --repo-only    Fetch Go modules, build the server, and
#                                        warm the Godot import cache. Used as the
#                                        environment `install` command.
#   cloud_agent_setup.sh                 Both halves (handy for a fresh local
#                                        Linux checkout).
#
# Install methods (Ubuntu):
#   * Go        - apt `golang-go`. Go's automatic toolchain management then
#                 fetches the exact version server/go.mod pins (`go 1.27.0`) on
#                 first build, so the apt version only needs to be recent enough
#                 to honour the toolchain directive.
#   * PowerShell- Microsoft PMC apt repository (packages.microsoft.com), the
#                 method documented at
#                 https://learn.microsoft.com/powershell/scripting/install/install-ubuntu
#   * Godot     - official Linux headless-capable binary from the GitHub release
#                 (snap/flatpak are desktop-oriented and do not work inside an
#                 image build; the binary is the identical 4.7 engine).
#
# The toolchain half is idempotent: an already-working toolchain is left alone.
# The Linux desktop is headless here; the Godot editor/headless binary runs, but
# windowed *_demo.ps1 captures need a real display and are out of scope. The
# headless suite and scripts/interop_test.ps1 are the full-stack proof paths.
set -euo pipefail

GODOT_VERSION="4.7-stable"

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

install_tools() {
  local arch tmp
  arch="$(uname -m)"
  [ "$arch" = "x86_64" ] || { echo "unsupported arch: $arch (expected x86_64)"; exit 1; }

  $SUDO apt-get update -y
  $SUDO apt-get install -y --no-install-recommends \
    ca-certificates curl wget git unzip apt-transport-https

  # Go: apt provides the toolchain manager; go.mod's `go 1.27.0` directive makes
  # `go` fetch 1.27.x automatically on first build.
  if command -v go >/dev/null 2>&1; then
    echo "go already present: $(go version)"
  else
    echo "installing go via apt"
    $SUDO apt-get install -y --no-install-recommends golang-go
  fi

  # Godot 4.7 headless binary.
  if [ -x /usr/local/bin/godot ] && /usr/local/bin/godot --version --headless 2>/dev/null | grep -q "^${GODOT_VERSION%-stable}.stable"; then
    echo "godot ${GODOT_VERSION} already installed"
  else
    echo "installing godot ${GODOT_VERSION}"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 4 --retry-delay 2 \
      -o "$tmp/godot.zip" \
      "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip"
    ( cd "$tmp" && unzip -o godot.zip )
    $SUDO install -m 0755 "$tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot
    rm -rf "$tmp"
  fi

  # PowerShell 7 from Microsoft's PMC apt repository.
  if command -v pwsh >/dev/null 2>&1 && pwsh --version 2>/dev/null | grep -q "PowerShell 7"; then
    echo "powershell already installed: $(pwsh --version)"
  else
    echo "installing powershell via microsoft apt repo"
    $SUDO apt-get install -y --no-install-recommends software-properties-common
    local rel deb
    rel="$(. /etc/os-release && echo "$VERSION_ID")"
    deb="$(mktemp --suffix=.deb)"
    curl -fsSL --retry 4 --retry-delay 2 \
      -o "$deb" \
      "https://packages.microsoft.com/config/ubuntu/${rel}/packages-microsoft-prod.deb"
    $SUDO dpkg -i "$deb"
    rm -f "$deb"
    $SUDO apt-get update -y
    $SUDO apt-get install -y powershell
  fi

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
