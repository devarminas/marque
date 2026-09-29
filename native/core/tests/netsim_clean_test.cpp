#include "marque/netsim/profile.hpp"
#include "marque/netsim/seed.hpp"
#include "marque/netsim/simulator.hpp"

#include <cstdio>

#include "check.hpp"

// Seed the committed golden files were generated with. Kept in sync with
// server/internal/netsim/netsim_test.go's goldenSeed.
constexpr std::uint64_t kGoldenSeed = 424242;

int main() {
    using marque::test::check;
    using namespace marque::netsim;

    std::uint64_t seed = seed_from_env(kGoldenSeed);
    Simulator sim(kClean, seed);

    constexpr int kCount = 200;
    for (int i = 0; i < kCount; ++i) {
        sim.send(Direction::kAToB, {static_cast<std::uint8_t>(i)}, static_cast<std::uint64_t>(i));
    }

    auto got = sim.poll(Direction::kAToB, kCount - 1);

    char what[160];
    std::snprintf(what, sizeof(what), "seed=%llu profile=clean: delivered all %d packets",
                   static_cast<unsigned long long>(seed), kCount);
    check(got.size() == static_cast<std::size_t>(kCount), what);

    bool in_order_zero_delay = true;
    for (int i = 0; i < static_cast<int>(got.size()); ++i) {
        if (got[i].packet.size() != 1 || got[i].packet[0] != static_cast<std::uint8_t>(i) ||
            got[i].at != static_cast<std::uint64_t>(i)) {
            in_order_zero_delay = false;
            break;
        }
    }
    std::snprintf(what, sizeof(what),
                   "seed=%llu profile=clean: delivered in send order with zero delay",
                   static_cast<unsigned long long>(seed));
    check(in_order_zero_delay, what);

    return marque::test::check_finish();
}
