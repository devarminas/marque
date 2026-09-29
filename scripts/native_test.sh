#!/usr/bin/env bash
set -euo pipefail

# Configures, builds, and runs the native/ C++ test suite. Exit code is the
# verdict: 0 only if configure, build, and every ctest case succeed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_root}/native/build"

cmake -S "${repo_root}/native" -B "${build_dir}" -G Ninja
cmake --build "${build_dir}"
ctest --test-dir "${build_dir}" --output-on-failure
