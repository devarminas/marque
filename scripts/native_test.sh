#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_root}/native/build"

cmake -S "${repo_root}/native" -B "${build_dir}" -G Ninja -DMARQUE_DEV_ISSUER=ON
cmake --build "${build_dir}"
ctest --test-dir "${build_dir}" --output-on-failure
