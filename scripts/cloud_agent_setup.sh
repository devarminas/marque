#!/usr/bin/env bash
#
# Cloud Agent environment bootstrap for Project Marque.
#
# Installs the exact toolchains the repo needs (Go 1.27, Godot 4.7 headless,
# PowerShell 7) into /usr/local, then fetches Go modules and warms the Godot
# import cache. It is idempotent: already-correct toolchains are left alone, so
# it is safe to run as the environment `install` command on every build.
#
# The Linux desktop is headless here: the Godot editor/headless binary runs, but
# windowed *_demo.ps1 captures need a real display and are out of scope. The
# headless suite and scripts/interop_test.ps1 are the full-stack proof paths.
set -euo pipefail

GO_VERSION="1.27.1"
GODOT_VERSION="4.7-stable"
PWSH_VERSION="7.6.6"

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || { echo "unsupported arch: $ARCH (expected x86_64)"; exit 1; }

# The base image already ships gcc (for `go test -race`) and curl, but a cold
# image may lack unzip, which the Godot archive needs.
if ! command -v unzip >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "installing unzip/curl"
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends unzip curl ca-certificates
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() {
  # fetch <url> <output>: curl with retries.
  curl -fsSL --retry 4 --retry-delay 2 -o "$2" "$1"
}

install_go() {
  if [ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION} "; then
    echo "go ${GO_VERSION} already installed"
  else
    echo "installing go ${GO_VERSION}"
    fetch "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" "$TMP/go.tar.gz"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$TMP/go.tar.gz"
  fi
  sudo ln -sf /usr/local/go/bin/go /usr/local/bin/go
  sudo ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

install_godot() {
  if [ -x /usr/local/bin/godot ] && /usr/local/bin/godot --version --headless 2>/dev/null | grep -q "^${GODOT_VERSION%-stable}.stable"; then
    echo "godot ${GODOT_VERSION} already installed"
  else
    echo "installing godot ${GODOT_VERSION}"
    fetch "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" "$TMP/godot.zip"
    ( cd "$TMP" && unzip -o godot.zip )
    sudo install -m 0755 "$TMP/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot
  fi
}

install_pwsh() {
  if [ -x /opt/microsoft/powershell/7/pwsh ] && /opt/microsoft/powershell/7/pwsh --version 2>/dev/null | grep -q "PowerShell ${PWSH_VERSION}"; then
    echo "powershell ${PWSH_VERSION} already installed"
  else
    echo "installing powershell ${PWSH_VERSION}"
    fetch "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" "$TMP/pwsh.tar.gz"
    sudo rm -rf /opt/microsoft/powershell/7
    sudo mkdir -p /opt/microsoft/powershell/7
    sudo tar -xzf "$TMP/pwsh.tar.gz" -C /opt/microsoft/powershell/7
    sudo chmod +x /opt/microsoft/powershell/7/pwsh
  fi
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
}

install_go
install_godot
install_pwsh

hash -r

echo "--- toolchain versions ---"
go version
godot --version --headless
pwsh --version
gcc --version | head -1

echo "--- fetching go modules and building ---"
( cd "$(dirname "$0")/../server" && go mod download && go build ./... )

echo "--- warming godot import cache ---"
# Warms client/.godot (gitignored) so headless script runs do not fail parsing
# global class_name scripts on a cold checkout.
godot --headless --path "$(dirname "$0")/../client" --editor --quit >/dev/null 2>&1 || true

echo "cloud_agent_setup: done"
