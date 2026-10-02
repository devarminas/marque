#pragma once

#include <cstdint>
#include <cstdlib>

namespace marque::netsim {

inline constexpr const char* kSeedEnvVar = "NETSIM_SEED";

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

}
