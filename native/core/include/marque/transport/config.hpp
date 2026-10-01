#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>

#include "marque/transport/packet.hpp"

namespace marque::transport {

class Seal;

inline constexpr std::size_t kDefaultTickBudget = 4800;
inline constexpr std::size_t kDefaultBacklogLimit = 1024;
inline constexpr std::size_t kDefaultBacklogBytes = 4 * kMaxMessage;
inline constexpr std::size_t kMaxBacklogLimit = 65536 - kWindowMessages;
inline constexpr std::uint64_t kDefaultResendAfter = 200'000;

enum class ConfigError : std::uint8_t {
    tick_budget_below_max_datagram,
    backlog_limit_out_of_range,
    backlog_bytes_zero,
    resend_after_zero,
    seal_missing,
};

const char* to_string(ConfigError e);

struct Config {
    std::uint64_t schema_hash = 0;
    std::size_t tick_budget = kDefaultTickBudget;
    std::size_t backlog_limit = kDefaultBacklogLimit;
    std::size_t backlog_bytes = kDefaultBacklogBytes;
    std::uint64_t resend_after = kDefaultResendAfter;

    std::expected<void, ConfigError> validate(const Seal* seal) const;
};

inline Config default_config(std::uint64_t schema_hash) {
    Config c;
    c.schema_hash = schema_hash;
    return c;
}

}
