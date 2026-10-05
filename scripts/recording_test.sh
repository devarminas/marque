#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmake -S "$repo_root/native" -B "$repo_root/native/build" -G Ninja
cmake --build "$repo_root/native/build" --target recording_peer client_runtime_peer --parallel 2
test -x "$repo_root/native/build/recording_peer"
cd "$repo_root/server"
MARQUE_RECORDING_PEER="$repo_root/native/build/recording_peer" CGO_ENABLED=1 go test -race ./internal/clientrecording ./internal/recording ./cmd/wiregen/dump -count=1 -timeout=60s -v
MARQUE_RUNTIME_PEER="$repo_root/native/build/client_runtime_peer" CGO_ENABLED=1 go test -race ./internal/clientruntime -run TestLiveRuntimeFailure -count=1 -timeout=60s -v
printf 'ARM361_RECORDING_REPLAY_PASS\n'
