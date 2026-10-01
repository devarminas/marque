#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rev="${1:-HEAD}"
repo="${2:-$repo_root}"
if [[ "$repo" == "$repo_root" ]]; then
    rev="$(git -C "$repo_root" rev-parse "$rev")"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
clone="$work/marque"

git clone -q "$repo" "$clone"
git -C "$clone" checkout -q "$rev"
echo "clone: $repo @ $(git -C "$clone" rev-parse --short HEAD)"

if ! "$clone/scripts/native_test.sh" > "$work/native.log" 2>&1; then
    tail -20 "$work/native.log"
    echo "native build failed"
    exit 2
fi
echo "native build: ok ($(ls "$clone/client/bin"/*.so))"

preload=""
if [[ -z "${REPRO_NO_RACE_SHIM:-}" ]]; then
    doc_cache="${XDG_CACHE_HOME:-$HOME/.cache}/godot/editor_doc_cache-4.7.res"
    if [[ ! -f "$doc_cache" ]]; then
        mkdir "$work/empty"
        echo "config_version=5" > "$work/empty/project.godot"
        godot --headless --path "$work/empty" --editor --quit > /dev/null 2>&1
        echo "doc cache warmed: $doc_cache"
    fi
    cc -shared -fPIC -O2 -o "$work/doc_race.so" "$clone/scripts/repro_gdext_doc_race.c"
    preload="$work/doc_race.so"
fi
status=0
LD_PRELOAD="$preload" godot --headless --path "$clone/client" --import > "$work/import.log" 2>&1 || status=$?

grep -a "repro_gdext_doc_race" "$work/import.log" || true
tail -3 "$work/import.log"
echo "first import exit status: $status"

if [[ -n "$preload" ]] && ! grep -aq "repro_gdext_doc_race: shim loaded" "$work/import.log"; then
    echo "shim marker missing: cannot tell race fixed from shim never loaded"
    exit 3
fi

exit "$status"
