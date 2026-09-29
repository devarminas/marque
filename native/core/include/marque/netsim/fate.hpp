#pragma once

#include <cstdint>

#include "marque/netsim/profile.hpp"
#include "marque/netsim/rng.hpp"

namespace marque::netsim {

// A packet's outcome, modeled as a sum type rather than a
// dropped/duplicated pair of booleans: a dropped packet has no arrival
// time, and a once-delivered packet has no second arrival time, so callers
// switch on kind instead of checking flag combinations.
enum class FateKind {
    kDropped,
    kDeliverOnce,
    kDeliverTwice,
};

struct Fate {
    FateKind kind;
    std::uint64_t at = 0;   // valid for kDeliverOnce and kDeliverTwice
    std::uint64_t at2 = 0;  // valid for kDeliverTwice only
};

// compute_fate is the one place that decides what happens to a packet sent
// at now. It draws from r in a fixed order that the Go implementation
// (server/internal/netsim/fate.go) mirrors exactly:
//
//  1. drop roll                               (always drawn)
//  2. jitter roll                              (only if not dropped)
//  3. reorder roll                             (only if not dropped)
//  4. reorder-extra roll                       (only if reordered)
//  5. duplicate roll                           (only if not dropped)
//  6. duplicate-jitter roll                    (only if duplicated)
//
// Keeping this order identical in both languages is what makes the same
// seed and profile produce the same fate sequence in Go and C++.
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

}  // namespace marque::netsim
