#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "marque/wire/codec.hpp"

namespace marque::transport {

inline constexpr std::uint32_t kProtocolId = 'M' | 'R' << 8 | 'Q' << 16 | static_cast<std::uint32_t>('1') << 24;
inline constexpr std::size_t kMaxDatagram = 1200;
inline constexpr std::size_t kHeaderSize = 20;
inline constexpr std::size_t kFragmentSize = 1024;
inline constexpr std::size_t kMaxFragments = 64;
inline constexpr std::size_t kMaxMessage = kFragmentSize * kMaxFragments;
inline constexpr std::size_t kWindowMessages = 256;
inline constexpr std::size_t kWindowBytes = kMaxMessage;
inline constexpr std::uint16_t kAckBits = 32;
inline constexpr std::uint64_t kKeepaliveAfter = 100'000;
inline constexpr std::uint64_t kTimeoutAfter = 5'000'000;

enum class Error : std::uint8_t { malformed, foreign, duplicate, too_old, closed, message, item };

const char* to_string(Error e);

enum class Role : std::uint8_t { server, client };

const char* to_string(Role r);

constexpr Role peer(Role r) { return r == Role::server ? Role::client : Role::server; }

constexpr wire::codec::Channel unreliable_channel(Role r) {
    return r == Role::server ? wire::codec::Channel::state : wire::codec::Channel::input;
}

constexpr wire::codec::Channel reliable_channel(Role r) {
    return r == Role::server ? wire::codec::Channel::events : wire::codec::Channel::intents;
}

struct AckWindow {
    std::uint16_t latest = 0xffff;
    std::uint32_t bits = 0;

    friend bool operator==(const AckWindow&, const AckWindow&) = default;
};

inline constexpr AckWindow kNoAcks{};

struct Unreliable {
    std::uint32_t stamp = 0;
    std::vector<std::vector<std::uint8_t>> items;
};

}
