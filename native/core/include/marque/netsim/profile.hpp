#pragma once

#include <cstdint>
#include <string_view>

namespace marque::netsim {

struct Profile {
    std::uint32_t drop_ppm = 0;
    std::uint64_t delay_base_micros = 0;
    std::uint64_t jitter_range_micros = 0;
    std::uint32_t duplicate_ppm = 0;
    std::uint32_t reorder_ppm = 0;
    std::uint64_t reorder_window_micros = 0;
};

inline constexpr Profile kClean{};

inline constexpr Profile kLossy5Pct{
    .drop_ppm = 50'000,
    .delay_base_micros = 20'000,
    .jitter_range_micros = 10'000,
    .duplicate_ppm = 1'000,
    .reorder_ppm = 2'000,
    .reorder_window_micros = 30'000,
};

inline constexpr Profile kBadWifi{
    .drop_ppm = 150'000,
    .delay_base_micros = 80'000,
    .jitter_range_micros = 60'000,
    .duplicate_ppm = 5'000,
    .reorder_ppm = 20'000,
    .reorder_window_micros = 120'000,
};

inline const Profile& profile_by_name(std::string_view name) {
    if (name == "lossy_5pct") return kLossy5Pct;
    if (name == "bad_wifi") return kBadWifi;
    return kClean;
}

}
