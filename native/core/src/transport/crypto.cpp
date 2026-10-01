#include "crypto.hpp"

#include <sodium.h>

#include <algorithm>
#include <array>
#include <cstdlib>

#include "format.hpp"

namespace marque::transport::crypto {

namespace {

void ready() {
    static const int once = sodium_init();
    if (once < 0) {
        std::abort();
    }
}

std::array<std::uint8_t, crypto_aead_chacha20poly1305_ietf_NPUBBYTES> ietf_nonce(std::uint64_t n) {
    std::array<std::uint8_t, crypto_aead_chacha20poly1305_ietf_NPUBBYTES> b{};
    for (int i = 0; i < 8; ++i) {
        b[4 + i] = static_cast<std::uint8_t>(n >> (8 * i));
    }
    return b;
}

}

void put_address(std::vector<std::uint8_t>& out, const Address& a) {
    out.insert(out.end(), a.ip.begin(), a.ip.end());
    format::put_u16(out, a.port);
}

Address get_address(std::span<const std::uint8_t> b) {
    Address a;
    std::copy_n(b.begin(), a.ip.size(), a.ip.begin());
    a.port = static_cast<std::uint16_t>(b[16] | b[17] << 8);
    return a;
}

void xseal(const Key& key, std::span<const std::uint8_t> nonce, std::span<const std::uint8_t> plain,
           std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out) {
    ready();
    auto at = out.size();
    out.resize(at + plain.size() + kTagSize);
    unsigned long long n = 0;
    crypto_aead_xchacha20poly1305_ietf_encrypt(out.data() + at, &n, plain.data(), plain.size(), ad.data(), ad.size(),
                                               nullptr, nonce.data(), key.data());
}

bool xopen(const Key& key, std::span<const std::uint8_t> nonce, std::span<const std::uint8_t> sealed,
           std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out) {
    ready();
    if (sealed.size() < kTagSize) {
        return false;
    }
    auto at = out.size();
    out.resize(at + sealed.size() - kTagSize);
    unsigned long long n = 0;
    if (crypto_aead_xchacha20poly1305_ietf_decrypt(out.data() + at, &n, nullptr, sealed.data(), sealed.size(),
                                                   ad.data(), ad.size(), nonce.data(), key.data()) != 0) {
        out.resize(at);
        return false;
    }
    return true;
}

void ietf_seal(const Key& key, std::uint64_t nonce, std::span<const std::uint8_t> plain,
               std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out) {
    ready();
    auto npub = ietf_nonce(nonce);
    auto at = out.size();
    out.resize(at + plain.size() + kTagSize);
    unsigned long long n = 0;
    crypto_aead_chacha20poly1305_ietf_encrypt(out.data() + at, &n, plain.data(), plain.size(), ad.data(), ad.size(),
                                              nullptr, npub.data(), key.data());
}

bool ietf_open(const Key& key, std::uint64_t nonce, std::span<const std::uint8_t> sealed,
               std::span<const std::uint8_t> ad, std::vector<std::uint8_t>& out) {
    ready();
    if (sealed.size() < kTagSize) {
        return false;
    }
    auto npub = ietf_nonce(nonce);
    auto at = out.size();
    out.resize(at + sealed.size() - kTagSize);
    unsigned long long n = 0;
    if (crypto_aead_chacha20poly1305_ietf_decrypt(out.data() + at, &n, nullptr, sealed.data(), sealed.size(),
                                                  ad.data(), ad.size(), npub.data(), key.data()) != 0) {
        out.resize(at);
        return false;
    }
    return true;
}

void random(std::span<std::uint8_t> out) {
    ready();
    randombytes_buf(out.data(), out.size());
}

}
