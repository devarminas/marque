#include "marque/netsim/golden.hpp"
#include "marque/netsim/profile.hpp"
#include "marque/netsim/seed.hpp"

#include <cstdio>
#include <string>

#include "check.hpp"

// Seed the committed golden files were generated with. Kept in sync with
// server/internal/netsim/netsim_test.go's goldenSeed.
constexpr std::uint64_t kGoldenSeed = 424242;

int main() {
    using marque::test::check;
    using namespace marque::netsim;

    std::uint64_t seed = seed_from_env(kGoldenSeed);
    constexpr int kTotal = 100'000;

    auto lines = golden_lines(kLossy5Pct, seed, kTotal);
    int drops = 0, delivers = 0, duplicates = 0;
    for (auto& line : lines) {
        if (line.find("DROP") != std::string::npos) {
            ++drops;
        } else if (line.find("DUPLICATE") != std::string::npos) {
            ++duplicates;
        } else if (line.find("DELIVER") != std::string::npos) {
            ++delivers;
        }
    }

    char what[192];

    // Literal counts at seed=kGoldenSeed: a regression that changes the
    // draw order, the RNG, or lossy_5pct's numbers changes these exactly,
    // not approximately. Kept in sync with the Go test's wantDrops etc.
    if (seed == kGoldenSeed) {
        constexpr int kWantDrops = 4990;
        constexpr int kWantDelivers = 94912;
        constexpr int kWantDuplicates = 98;
        std::snprintf(what, sizeof(what),
                       "seed=%llu profile=lossy_5pct: drops=%d delivers=%d duplicates=%d matches Go",
                       static_cast<unsigned long long>(seed), drops, delivers, duplicates);
        check(drops == kWantDrops && delivers == kWantDelivers && duplicates == kWantDuplicates, what);
    }

    double drop_pct = static_cast<double>(drops) / static_cast<double>(kTotal) * 100.0;
    std::snprintf(what, sizeof(what), "seed=%llu profile=lossy_5pct: drop rate %.2f%% within [4%%, 6%%]",
                  static_cast<unsigned long long>(seed), drop_pct);
    check(drop_pct >= 4.0 && drop_pct <= 6.0, what);

    std::snprintf(what, sizeof(what), "seed=%llu profile=lossy_5pct: drops+delivers+duplicates == total",
                  static_cast<unsigned long long>(seed));
    check(drops + delivers + duplicates == kTotal, what);

    return marque::test::check_finish();
}
