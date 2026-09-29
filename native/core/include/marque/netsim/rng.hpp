#pragma once

#include <cstdint>

// marque::netsim mirrors server/internal/netsim byte for byte. Any change
// to the RNG algorithm, draw order, or profile numbers here must be made
// identically in the Go package, or the two languages' golden vectors
// under shared/wire/vectors/netsim stop matching.

namespace marque::netsim {

// Rng is splitmix64: one 64-bit state word advanced by a fixed increment,
// mixed through fixed shift/multiply constants. Unsigned 64-bit
// add/xor/multiply wrap identically in C++ and Go, so the same seed
// produces the same draw sequence in both languages.
class Rng {
public:
    explicit Rng(std::uint64_t seed) : state_(seed) {}

    std::uint64_t next() {
        state_ += 0x9E3779B97F4A7C15ULL;
        std::uint64_t z = state_;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
        return z ^ (z >> 31);
    }

private:
    std::uint64_t state_;
};

inline constexpr std::uint64_t kPpmScale = 1'000'000;

// Reports whether one draw lands inside a parts-per-million probability.
// Always consumes a draw, even for ppm 0 or 1'000'000, so the stream stays
// aligned with the Go implementation regardless of the profile's numbers.
inline bool bernoulli_ppm(Rng& r, std::uint32_t ppm) {
    return r.next() % kPpmScale < static_cast<std::uint64_t>(ppm);
}

// Returns a draw uniformly distributed over [0, range_micros], always
// consuming exactly one draw. A zero range still consumes a draw and
// always returns 0.
inline std::uint64_t uniform_micros(Rng& r, std::uint64_t range_micros) {
    std::uint64_t draw = r.next();
    if (range_micros == 0) {
        return 0;
    }
    return draw % (range_micros + 1);
}

}  // namespace marque::netsim
