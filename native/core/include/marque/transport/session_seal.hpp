#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "marque/transport/handshake.hpp"
#include "marque/transport/packet.hpp"
#include "marque/transport/seal.hpp"

namespace marque::transport {

inline constexpr std::size_t kSessionOverhead = 8 + kTagSize;
inline constexpr std::uint64_t kReplayWindow = 64;

struct SessionSeal;

SessionSeal session_seal(Role role, const SessionKeys& keys);

class SessionOpener final : public Opener {
public:
    SessionOpener(const SessionOpener&) = delete;
    SessionOpener& operator=(const SessionOpener&) = delete;

    std::size_t overhead() const override { return kSessionOverhead; }

    bool open(std::span<const std::uint8_t> header, std::span<const std::uint8_t> sealed,
              std::vector<std::uint8_t>& out) override;

private:
    explicit SessionOpener(const Key& key) : key_(key) {}
    friend SessionSeal session_seal(Role role, const SessionKeys& keys);

    bool fresh(std::uint64_t nonce) const;
    void accept(std::uint64_t nonce);

    Key key_;
    bool have_ = false;
    std::uint64_t newest_ = 0;
    std::uint64_t bits_ = 0;
};

class SessionSealer final : public Sealer {
public:
    SessionSealer(const SessionSealer&) = delete;
    SessionSealer& operator=(const SessionSealer&) = delete;

    std::size_t overhead() const override { return kSessionOverhead; }

    void seal(std::span<const std::uint8_t> header, std::span<const std::uint8_t> body,
              std::vector<std::uint8_t>& out) override;

private:
    explicit SessionSealer(const Key& key) : key_(key) {}
    friend SessionSeal session_seal(Role role, const SessionKeys& keys);

    Key key_;
    std::uint64_t nonce_ = 0;
};

struct SessionSeal {
    std::unique_ptr<SessionOpener> opener;
    std::unique_ptr<SessionSealer> sealer;
};

}
