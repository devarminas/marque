#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <functional>
#include <map>
#include <optional>
#include <span>
#include <variant>
#include <vector>

namespace marque::transport {

inline constexpr std::size_t kKeySize = 32;
inline constexpr std::size_t kTokenNonceSize = 24;
inline constexpr std::size_t kTagSize = 16;
inline constexpr std::size_t kAddressSize = 18;
inline constexpr std::uint32_t kTokenVersion = 0x3154524d;
inline constexpr std::uint32_t kHandshakeId = 0x3148524d;
inline constexpr std::size_t kPrivateSize = 8 + 8 + kAddressSize + 2 * kKeySize;
inline constexpr std::size_t kPrivateSealedSize = kPrivateSize + kTagSize;
inline constexpr std::size_t kTokenSize = 4 + 8 + kTokenNonceSize + kAddressSize + 2 * kKeySize + kPrivateSealedSize;
inline constexpr std::size_t kRequestSize = 512;
inline constexpr std::uint64_t kChallengeLifetime = 10;
inline constexpr std::size_t kChallengePlain = kTokenNonceSize + 8 + 8 + 8 + 8 + kAddressSize + 2 * kKeySize;
inline constexpr std::size_t kChallengeSize = 5 + kTokenNonceSize + kChallengePlain + kTagSize;
inline constexpr std::size_t kResponseSize = kChallengeSize + kTagSize;

using Key = std::array<std::uint8_t, kKeySize>;
using TokenNonce = std::array<std::uint8_t, kTokenNonceSize>;

struct Address {
    std::array<std::uint8_t, 16> ip{};
    std::uint16_t port = 0;

    friend bool operator==(const Address&, const Address&) = default;
};

struct SessionKeys {
    Key client_to_server{};
    Key server_to_client{};

    friend bool operator==(const SessionKeys&, const SessionKeys&) = default;
};

struct Grant {
    std::uint64_t account = 0;
    std::uint64_t session = 0;
    Address shard;
    std::uint64_t expires = 0;
    SessionKeys keys;
};

enum class HandshakeError : std::uint8_t {
    malformed,
    foreign,
    expired,
    forged,
    wrong_shard,
    replayed,
    address,
};

const char* to_string(HandshakeError e);

struct ConnectToken {
    std::uint64_t expires = 0;
    TokenNonce nonce{};
    Address shard;
    SessionKeys keys;
    std::array<std::uint8_t, kPrivateSealedSize> sealed{};

    static std::optional<ConnectToken> parse(std::span<const std::uint8_t> bytes);

    std::vector<std::uint8_t> bytes() const;

    std::vector<std::uint8_t> request(std::uint64_t schema_hash) const;

    std::expected<std::vector<std::uint8_t>, HandshakeError> respond(std::span<const std::uint8_t> challenge) const;

    friend bool operator==(const ConnectToken&, const ConnectToken&) = default;
};

ConnectToken issue_token(const Key& issuer, const TokenNonce& nonce, const Grant& grant);

struct GateConfig {
    std::uint64_t schema_hash = 0;
    Address shard;
    Key issuer{};
};

struct Challenge {
    std::vector<std::uint8_t> bytes;
};

struct Admission {
    Address peer;
    std::uint64_t account = 0;
    std::uint64_t session = 0;
    std::uint64_t expires = 0;
    SessionKeys keys;

    friend bool operator==(const Admission&, const Admission&) = default;
};

using Outcome = std::variant<Challenge, Admission>;

struct GateRandom;

class Gate {
public:
    explicit Gate(const GateConfig& cfg);

    std::expected<Outcome, HandshakeError> handle(const Address& from, std::span<const std::uint8_t> packet,
                                                  std::uint64_t now);

    std::size_t admissions() const { return admitted_.size(); }

private:
    std::expected<Outcome, HandshakeError> request(const Address& from, std::span<const std::uint8_t> d,
                                                   std::uint64_t now);
    std::expected<Outcome, HandshakeError> response(const Address& from, std::span<const std::uint8_t> d,
                                                    std::uint64_t now);

    friend struct GateRandom;

    GateConfig cfg_;
    Key challenge_key_{};
    std::function<void(std::span<std::uint8_t>)> random_;
    std::map<TokenNonce, std::uint64_t> admitted_;
};

}
