#pragma once

#include <cstdint>

#include "marque/netsim/profile.hpp"
#include "marque/netsim/rng.hpp"

namespace marque::netsim {

enum class FateKind {
    kDropped,
    kDeliverOnce,
    kDeliverTwice,
};

struct Fate {
    FateKind kind;
    std::uint64_t at = 0;
    std::uint64_t at2 = 0;
};

inline Fate compute_fate(Rng& r, const Profile& p, std::uint64_t now) {
    if (bernoulli_ppm(r, p.drop_ppm)) {
        return Fate{.kind = FateKind::kDropped};
    }

    std::uint64_t jitter = uniform_micros(r, p.jitter_range_micros);
    std::uint64_t at = now + p.delay_base_micros + jitter;

    if (bernoulli_ppm(r, p.reorder_ppm)) {
        at += uniform_micros(r, p.reorder_window_micros);
    }

    if (bernoulli_ppm(r, p.duplicate_ppm)) {
        std::uint64_t at2 = at + uniform_micros(r, p.jitter_range_micros);
        return Fate{.kind = FateKind::kDeliverTwice, .at = at, .at2 = at2};
    }

    return Fate{.kind = FateKind::kDeliverOnce, .at = at};
}

}
