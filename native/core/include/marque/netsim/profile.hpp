#pragma once

#include <cstdint>
#include <string_view>

namespace marque::netsim {

// Profile is the set of independent knobs the simulator draws against. All
// probabilities are parts per million (0..1'000'000) and all durations are
// microseconds: exact integers, no cross-language floating-point drift.
struct Profile {
    std::uint32_t drop_ppm = 0;
    std::uint64_t delay_base_micros = 0;
    std::uint64_t jitter_range_micros = 0;
    std::uint32_t duplicate_ppm = 0;
    std::uint32_t reorder_ppm = 0;
    std::uint64_t reorder_window_micros = 0;
};

// Named profiles. Numbers live here once per language; the golden vector
// tests under shared/wire/vectors/netsim are what proves the C++ and Go
// numbers are equal, since a mismatch would change the committed fate
// sequence in one language but not the other.

// Clean never drops, delays, duplicates, or reorders.
inline constexpr Profile kClean{};

// Lossy5Pct models an imperfect but usable connection: 5% loss and modest
// delay, with duplication and reordering rare.
inline constexpr Profile kLossy5Pct{
    .drop_ppm = 50'000,               // 5%
    .delay_base_micros = 20'000,      // 20ms
    .jitter_range_micros = 10'000,    // +-10ms
    .duplicate_ppm = 1'000,           // 0.1%
    .reorder_ppm = 2'000,             // 0.2%
    .reorder_window_micros = 30'000,  // 30ms
};

// BadWifi models a congested access point: heavy loss and delay, with
// duplication and reordering an order of magnitude more common than
// Lossy5Pct.
inline constexpr Profile kBadWifi{
    .drop_ppm = 150'000,                // 15%
    .delay_base_micros = 80'000,        // 80ms
    .jitter_range_micros = 60'000,      // +-60ms
    .duplicate_ppm = 5'000,             // 0.5%
    .reorder_ppm = 20'000,              // 2%
    .reorder_window_micros = 120'000,   // 120ms
};

// profile_by_name returns the named profile (matching the Go package's
// Profiles map keys "clean", "lossy_5pct", "bad_wifi") or kClean if name is
// not recognized.
inline const Profile& profile_by_name(std::string_view name) {
    if (name == "lossy_5pct") return kLossy5Pct;
    if (name == "bad_wifi") return kBadWifi;
    return kClean;
}

}  // namespace marque::netsim
