#!/usr/bin/env bash
set -euo pipefail

# Fuzzes every generated wire decoder for <seconds> each, all at once: the Go
# channel decoders under Go's native fuzzer, and the C++ ones under libFuzzer
# with ASan and UBSan (clang). Both start from the inputs in
# shared/wire/vectors. Each run's log lands in native/build/wire-fuzz/logs, and the
# script prints each run's final stats line. Exit 0 only if every run ends
# without a crash.
#
# Usage: scripts/wire_fuzz.sh <seconds>

seconds="${1:?usage: scripts/wire_fuzz.sh <seconds>}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="${repo_root}/native/build/wire-fuzz"
logs="${build}/logs"
schemas=(wire probe)
channels=(state events input intents)

CC=clang CXX=clang++ cmake -S "${repo_root}/native" -B "${build}" -G Ninja -DMARQUE_FUZZ=ON >/dev/null
cmake --build "${build}"
rm -rf "${logs}" "${build}/corpus"
mkdir -p "${logs}"

# One seed file per vector line, in the corpus of the decoder it names.
for vec in "${repo_root}"/shared/wire/vectors/*.vec; do
    schema=""
    while read -r verdict name channel hex _; do
        case "${verdict}" in
        schema) schema="${name}" ;;
        accept | reject)
            dir="${build}/corpus/${schema}_${channel}"
            mkdir -p "${dir}"
            printf '%b' "$(sed 's/../\\x&/g' <<<"${hex}")" >"${dir}/${name}"
            ;;
        esac
    done <"${vec}"
done

pids=()
names=()
for schema in "${schemas[@]}"; do
    for channel in "${channels[@]}"; do
        target="${schema}_${channel}"
        mkdir -p "${build}/corpus/${target}"
        (cd "${repo_root}/server" && go test -run '^$' -fuzz "^Fuzz${schema^}${channel^}\$" \
            -fuzztime "${seconds}s" -parallel 1 ./internal/wire/) >"${logs}/go_${target}.log" 2>&1 &
        pids+=($!)
        names+=("go_${target}")
        "${build}/fuzz/fuzz_${target}" "${build}/corpus/${target}" -max_total_time="${seconds}" \
            -print_final_stats=1 -artifact_prefix="${logs}/cpp_${target}-" >"${logs}/cpp_${target}.log" 2>&1 &
        pids+=($!)
        names+=("cpp_${target}")
    done
done

failed=0
for i in "${!pids[@]}"; do
    status=0
    wait "${pids[$i]}" || status=$?
    log="${logs}/${names[$i]}.log"
    if [[ "${names[$i]}" == go_* ]]; then
        stats="$(grep '^fuzz: elapsed' "${log}" | tail -1 || true)"
    else
        stats="$(grep -E '^Done [0-9]+ runs' "${log}" | tail -1 || true)"
    fi
    if [[ ${status} -ne 0 ]]; then
        failed=1
        echo "CRASH ${names[$i]} (exit ${status}); see ${log}"
    else
        echo "ok    ${names[$i]}: ${stats}"
    fi
done

if [[ ${failed} -ne 0 ]]; then
    echo "wire fuzz found a crash" >&2
    exit 1
fi
echo "wire fuzz clean: ${#pids[@]} runs of ${seconds}s"
