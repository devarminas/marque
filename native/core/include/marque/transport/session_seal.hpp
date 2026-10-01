#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "marque/transport/handshake.hpp"
#include "marque/transport/packet.hpp"
#include "marque/transport/seal.hpp"

namespace marque::transport {

inline constexpr std::size_t kSessionOverhead = 8 + kTagSize;
inline constexpr std::uint64_t kReplayWindow = 64;

class SessionSeal final : public Seal {
public:
    SessionSeal(Role role, const SessionKeys& keys);

    std::size_t overhead() const override { return kSessionOverhead; }

    void seal(std::span<const std::uint8_t> header, std::span<const std::uint8_t> body,
              std::vector<std::uint8_t>& out) override;

    bool open(std::span<const std::uint8_t> header, std::span<const std::uint8_t> sealed,
              std::vector<std::uint8_t>& out) override;

private:
    bool fresh(std::uint64_t nonce) const;
    void accept(std::uint64_t nonce);

    Key send_key_;
    std::uint64_t send_nonce_ = 0;

    Key recv_key_;
    bool have_ = false;
    std::uint64_t newest_ = 0;
    std::uint64_t bits_ = 0;
};

}
