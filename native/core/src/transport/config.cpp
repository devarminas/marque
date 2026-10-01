#include "marque/transport/config.hpp"

namespace marque::transport {

const char* to_string(ConfigError e) {
    switch (e) {
    case ConfigError::tick_budget_below_max_datagram:
        return "tick_budget_below_max_datagram";
    case ConfigError::backlog_limit_out_of_range:
        return "backlog_limit_out_of_range";
    case ConfigError::backlog_bytes_zero:
        return "backlog_bytes_zero";
    case ConfigError::resend_after_zero:
        return "resend_after_zero";
    case ConfigError::opener_missing:
        return "opener_missing";
    case ConfigError::sealer_missing:
        return "sealer_missing";
    }
    return "config_error?";
}

std::expected<void, ConfigError> Config::validate() const {
    if (tick_budget < kMaxDatagram) {
        return std::unexpected(ConfigError::tick_budget_below_max_datagram);
    }
    if (backlog_limit < 1 || backlog_limit > kMaxBacklogLimit) {
        return std::unexpected(ConfigError::backlog_limit_out_of_range);
    }
    if (backlog_bytes < 1) {
        return std::unexpected(ConfigError::backlog_bytes_zero);
    }
    if (resend_after == 0) {
        return std::unexpected(ConfigError::resend_after_zero);
    }
    return {};
}

}
