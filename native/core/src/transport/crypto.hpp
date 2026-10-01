#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

#include "marque/transport/handshake.hpp"

namespace marque::transport::crypto {

void put_address(std::vector<std::uint8_t>& out, const Address& a);
Address get_address(std::span<const std::uint8_t> b);

void xseal(const Key& key, std::span<const std::uint8_t> nonce, std::span<const std::uint8_t> plain,
           std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out);
bool xopen(const Key& key, std::span<const std::uint8_t> nonce, std::span<const std::uint8_t> sealed,
           std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out);

void ietf_seal(const Key& key, std::uint64_t nonce, std::span<const std::uint8_t> plain,
               std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out);
bool ietf_open(const Key& key, std::uint64_t nonce, std::span<const std::uint8_t> sealed,
               std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out);

void random(std::span<std::uint8_t> out);

}
