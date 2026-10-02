#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
cmake -S "$repo_root/native" -B "$build_dir" -G Ninja -DMARQUE_DEV_ISSUER=OFF
cmake --build "$build_dir" --target transport_interop_client --parallel 2
test -x "$build_dir/transport_interop_client"
cd "$repo_root/server"
TRANSPORT_INTEROP_CLIENT="$build_dir/transport_interop_client" go test -race ./internal/transport/interop -run '^TestGoCppInterop$' -count=1 -timeout=5m -v
