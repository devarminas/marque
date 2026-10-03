#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fresh="$(mktemp -d)"
trap 'rm -rf "${fresh}"' EXIT

(cd "${repo_root}/server" && go run ./cmd/wiregen gen -src "${repo_root}" -root "${fresh}")

stale=0
while IFS= read -r path; do
    if ! diff -u --label "committed/${path}" --label "generated/${path}" \
        "${repo_root}/${path}" "${fresh}/${path}"; then
        stale=1
    fi
done < <(cd "${fresh}" && find . -type f | sed 's|^\./||' | sort)

if [[ ${stale} -ne 0 ]]; then
    echo "wiregen output is stale; run scripts/wiregen.sh and commit the result" >&2
    exit 1
fi
echo "wiregen output is fresh"
