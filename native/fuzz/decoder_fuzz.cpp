#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "marque/wire/gen/probe.hpp"
#include "marque/wire/gen/schema.hpp"

#define MARQUE_PASTE(a, b) a##b
#define MARQUE_JOIN(a, b) MARQUE_PASTE(a, b)
#define MARQUE_CHANNEL_FN(prefix) MARQUE_FUZZ_NS::MARQUE_JOIN(prefix, MARQUE_FUZZ_CHANNEL)

extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data, std::size_t size) {
    const std::span<const std::uint8_t> in(data, size);
    auto m = MARQUE_CHANNEL_FN(decode_)(in);
    if (!m) return 0;
    (void)MARQUE_CHANNEL_FN(text_)(*m);
    std::vector<std::uint8_t> out;
    if (!MARQUE_CHANNEL_FN(encode_)(*m, out) || !std::ranges::equal(out, in)) __builtin_trap();
    return 0;
}
