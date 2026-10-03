#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmake -S "$repo_root/native" -B "$repo_root/native/build" -G Ninja
cmake --build "$repo_root/native/build" --target motion_peer
test -x "$repo_root/native/build/motion_peer"
cd "$repo_root/server"
MARQUE_MOTION_PEER="$repo_root/native/build/motion_peer" CGO_ENABLED=1 go test -race ./internal/intents -run '^TestMotion(Interop|ApproachInterop)$' -count=1 -v
