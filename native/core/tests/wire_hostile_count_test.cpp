// A list count the remaining bytes cannot hold must fail before the decoder
// sizes an allocation from it. This executable replaces global operator new to
// count heap allocations around the decode.

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <vector>

#include "check.hpp"
#include "marque/wire/gen/probe.hpp"

namespace {
std::size_t allocations = 0;
}

void* operator new(std::size_t n) {
    ++allocations;
    if (void* p = std::malloc(n == 0 ? 1 : n)) return p;
    throw std::bad_alloc();
}

void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

int main() {
    using marque::test::check;
    namespace probe = marque::wire::probe;

    // Crowd's list bound is 65535 and each Pair is at least 6 bytes, so 03 ff7f
    // claims 16383 pairs (98298 bytes) with none behind it.
    const std::vector<std::uint8_t> hostile{0x03, 0xff, 0x7f};
    const std::vector<std::uint8_t> one_pair{0x03, 0x01, 0x05, 0x00, 0x00, 0x00, 0x80, 0x3f};

    const auto before_ok = allocations;
    auto ok = probe::decode_events(one_pair);
    check(ok.has_value() && std::get<probe::Crowd>(*ok).pairs.size() == 1, "a crowd of one pair decodes");
    check(allocations > before_ok, "the allocation counter sees the decoder's list allocation");

    const auto before = allocations;
    auto got = probe::decode_events(hostile);
    const auto during = allocations - before;
    check(!got.has_value() && got.error() == marque::wire::codec::Error::truncated, "hostile count is truncated");
    check(during == 0, "hostile count allocates nothing");
    return marque::test::check_finish();
}
