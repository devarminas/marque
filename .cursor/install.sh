#!/usr/bin/env bash
#
# Idempotent repository bootstrap for Project Marque Cloud Agents.
#
# Toolchains (Go 1.27.0, Godot 4.7.2) come from the base image; this script only
# prepares state that depends on the checked-out source, so it is safe to run
# repeatedly. Runs from the repository root.
set -euo pipefail

echo "== go modules =="
(cd server && go mod download)

echo "== build server (warms the Go build cache) =="
(cd server && go build -o bin/marqued ./cmd/marqued)

# Warm the Godot editor cache. client/.godot/ is gitignored, and without it
# headless Godot fails to parse scripts that name a global class_name and
# cascades into unrelated errors (NOTES.md, "Godot authoring traps").
echo "== warm Godot import/class cache =="
godot --headless --path client --editor --quit >/dev/null 2>&1 || true
if [ ! -d client/.godot ]; then
    echo "error: client/.godot was not created by the Godot warm-up" >&2
    exit 1
fi

echo "install complete"
