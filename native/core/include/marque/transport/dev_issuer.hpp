#pragma once

#include <cstdint>

#include "marque/transport/handshake.hpp"

namespace marque::transport::dev {

extern const Key kIssuerKey;

ConnectToken issue(std::uint64_t account, std::uint64_t session, const Address& shard, std::uint64_t expires);

}
