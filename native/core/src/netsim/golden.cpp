#include "marque/netsim/golden.hpp"

#include <algorithm>
#include <cstdio>
#include <unordered_map>

#include "marque/netsim/simulator.hpp"

namespace marque::netsim {

namespace {

// One send every 1ms of simulated time. Must match
// server/internal/netsim/golden.go's goldenSendGapMicros.
constexpr std::uint64_t kSendGapMicros = 1000;

std::vector<std::uint8_t> packet_payload(std::uint32_t index) {
    return {
        static_cast<std::uint8_t>(index >> 24),
        static_cast<std::uint8_t>(index >> 16),
        static_cast<std::uint8_t>(index >> 8),
        static_cast<std::uint8_t>(index),
    };
}

std::uint32_t packet_index(const std::vector<std::uint8_t>& payload) {
    return (static_cast<std::uint32_t>(payload[0]) << 24) |
           (static_cast<std::uint32_t>(payload[1]) << 16) |
           (static_cast<std::uint32_t>(payload[2]) << 8) |
           static_cast<std::uint32_t>(payload[3]);
}

std::string format_line(std::uint32_t index, std::vector<std::uint64_t>& arrivals) {
    std::sort(arrivals.begin(), arrivals.end());
    char buf[128];
    switch (arrivals.size()) {
        case 0:
            std::snprintf(buf, sizeof(buf), "%u DROP", index);
            break;
        case 1:
            std::snprintf(buf, sizeof(buf), "%u DELIVER %llu", index,
                           static_cast<unsigned long long>(arrivals[0]));
            break;
        case 2:
            std::snprintf(buf, sizeof(buf), "%u DUPLICATE %llu %llu", index,
                           static_cast<unsigned long long>(arrivals[0]),
                           static_cast<unsigned long long>(arrivals[1]));
            break;
        default:
            std::snprintf(buf, sizeof(buf), "%u ARRIVED_UNEXPECTEDLY %zu_TIMES", index, arrivals.size());
            break;
    }
    return std::string(buf);
}

}  // namespace

std::vector<std::string> golden_lines(const Profile& profile, std::uint64_t seed, int count) {
    Simulator sim(profile, seed);

    for (int i = 0; i < count; ++i) {
        sim.send(Direction::kAToB, packet_payload(static_cast<std::uint32_t>(i)),
                  static_cast<std::uint64_t>(i) * kSendGapMicros);
    }

    // Every fate's arrival time is bounded by the last send time plus the
    // slowest possible path through compute_fate: base delay, jitter,
    // reorder push, and (for a duplicate) one more jitter draw. Polling
    // once past that bound drains every surviving packet in one call.
    std::uint64_t last_send = static_cast<std::uint64_t>(count - 1) * kSendGapMicros;
    std::uint64_t max_extra = profile.delay_base_micros + profile.jitter_range_micros +
                               profile.reorder_window_micros + profile.jitter_range_micros;
    auto deliveries = sim.poll(Direction::kAToB, last_send + max_extra + 1);

    std::unordered_map<std::uint32_t, std::vector<std::uint64_t>> arrivals_by_index;
    arrivals_by_index.reserve(static_cast<std::size_t>(count));
    for (auto& d : deliveries) {
        arrivals_by_index[packet_index(d.packet)].push_back(d.at);
    }

    std::vector<std::string> lines;
    lines.reserve(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i) {
        auto index = static_cast<std::uint32_t>(i);
        lines.push_back(format_line(index, arrivals_by_index[index]));
    }
    return lines;
}

}  // namespace marque::netsim
