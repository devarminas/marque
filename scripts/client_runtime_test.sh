#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmake -S "$repo_root/native" -B "$repo_root/native/build" -G Ninja
cmake --build "$repo_root/native/build" --target marque_gdext_register client_domain_test client_runtime_peer recording_peer --parallel 2
"$repo_root/native/build/client_domain_test"
python3 "$repo_root/scripts/verify_core_properties.py"
cd "$repo_root/server"
MARQUE_RECORDING_PEER="$repo_root/native/build/recording_peer" MARQUE_RUNTIME_PEER="$repo_root/native/build/client_runtime_peer" MARQUE_RUNTIME_CLIENT="$repo_root/client" CGO_ENABLED=1 go test -race ./internal/clientruntime ./internal/eventstream -count=1 -timeout=60s -v
