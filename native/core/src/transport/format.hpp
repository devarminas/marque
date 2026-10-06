#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>
#include <vector>

#include "marque/transport/packet.hpp"

namespace marque::transport::format {

inline constexpr std::size_t kUnreliableSectionHeader = 1 + 4 + 2;
inline constexpr std::size_t kReliableSectionHeader = 1 + 2;
inline constexpr std::size_t kEntryHeader = 2 + 1 + 1;

struct Header {
    std::uint32_t protocol = 0;
    std::uint64_t hash = 0;
    std::uint16_t seq = 0;
    AckWindow ack;
};

struct Entry {
    std::uint16_t id = 0;
    std::uint8_t index = 0;
    std::uint8_t count = 0;
    std::span<const std::uint8_t> data;
};

struct UnreliableSection {
    std::uint32_t stamp = 0;
    std::vector<std::span<const std::uint8_t>> items;
};

struct Body {
    std::optional<UnreliableSection> unreliable;
    std::vector<Entry> entries;
};

constexpr std::size_t length_size(std::size_t n) { return n < 0x80 ? 1 : 2; }

constexpr std::size_t item_size(std::size_t n) { return length_size(n) + n; }

constexpr std::size_t entry_size(std::size_t n) { return kEntryHeader + item_size(n); }

void put_header(std::vector<std::uint8_t>& out, const Header& h);

Header read_header(std::span<const std::uint8_t> datagram);

void put_body(std::vector<std::uint8_t>& out, Role from, std::uint32_t stamp,
              std::span<const std::vector<std::uint8_t>> items, std::span<const Entry> entries);

std::optional<Body> parse_body(std::span<const std::uint8_t> body, Role from);

}
