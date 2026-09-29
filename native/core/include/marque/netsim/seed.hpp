#pragma once

#include <cstdint>
#include <cstdlib>

namespace marque::netsim {

// The environment variable that overrides a test's seed, so a failure that
// prints "seed=<n> profile=<name>" can be reproduced with
// NETSIM_SEED=<n> against the same profile. Matches
// server/internal/netsim/seed.go's SeedEnvVar.
inline constexpr const char* kSeedEnvVar = "NETSIM_SEED";

// Returns the seed a test should run with: the value of NETSIM_SEED if set
// and parseable as a uint64, otherwise def.
inline std::uint64_t seed_from_env(std::uint64_t def) {
    const char* raw = std::getenv(kSeedEnvVar);
    if (raw == nullptr || *raw == '\0') {
        return def;
    }
    char* end = nullptr;
    unsigned long long v = std::strtoull(raw, &end, 10);
    if (end == raw) {
        return def;
    }
    return static_cast<std::uint64_t>(v);
}

}  // namespace marque::netsim
