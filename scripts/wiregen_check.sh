#!/usr/bin/env bash
set -euo pipefail

# Fails with a diff when the committed wiregen output differs from what the
# current schemas and generator produce. Fix a failure with scripts/wiregen.sh.

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

# The vector copy is wholly generated, so a copy whose source was deleted is stale too.
vectors="server/internal/wire/testdata/vectors"
for path in "${repo_root}/${vectors}"/*; do
    if [[ ! -e "${fresh}/${vectors}/$(basename "${path}")" ]]; then
        echo "${vectors}/$(basename "${path}") has no source in shared/wire/vectors" >&2
        stale=1
    fi
done

if [[ ${stale} -ne 0 ]]; then
    echo "wiregen output is stale; run scripts/wiregen.sh and commit the result" >&2
    exit 1
fi
echo "wiregen output is fresh"
