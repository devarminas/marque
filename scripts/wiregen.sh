#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}/server"
go run ./cmd/wiregen gen -src "${repo_root}" -root "${repo_root}"
