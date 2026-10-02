#pragma once

#include <cstdint>

namespace marque::netsim {

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

inline bool bernoulli_ppm(Rng& r, std::uint32_t ppm) {
    return r.next() % kPpmScale < static_cast<std::uint64_t>(ppm);
}

inline std::uint64_t uniform_micros(Rng& r, std::uint64_t range_micros) {
    std::uint64_t draw = r.next();
    if (range_micros == 0) {
        return 0;
    }
    return draw % (range_micros + 1);
}

}
