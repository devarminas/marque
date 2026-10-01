#include "marque/transport/handshake.hpp"

#include <algorithm>
#include <ranges>

#include "crypto.hpp"
#include "format.hpp"

namespace marque::transport {

namespace {

constexpr std::uint8_t kKindRequest = 1;
constexpr std::uint8_t kKindChallenge = 2;
constexpr std::uint8_t kKindResponse = 3;
constexpr std::size_t kRequestTokenEnd = 5 + 8 + 8 + kTokenNonceSize + kPrivateSealedSize;

std::vector<std::uint8_t> token_ad(std::uint64_t expires) {
    std::vector<std::uint8_t> ad;
    format::put_u32(ad, kTokenVersion);
    format::put_u64(ad, expires);
    return ad;
}

std::vector<std::uint8_t> address_bytes(const Address& a) {
    std::vector<std::uint8_t> b;
    crypto::put_address(b, a);
    return b;
}

template <std::size_t N>
std::array<std::uint8_t, N> take(std::span<const std::uint8_t> b) {
    std::array<std::uint8_t, N> out{};
    std::copy_n(b.begin(), N, out.begin());
    return out;
}

}

const char* to_string(HandshakeError e) {
    switch (e) {
    case HandshakeError::malformed:
        return "malformed";
    case HandshakeError::foreign:
        return "foreign";
    case HandshakeError::expired:
        return "expired";
    case HandshakeError::forged:
        return "forged";
    case HandshakeError::wrong_shard:
        return "wrong_shard";
    case HandshakeError::replayed:
        return "replayed";
    case HandshakeError::address:
        return "address";
    }
    return "handshake_error?";
}

ConnectToken issue_token(const Key& issuer, const TokenNonce& nonce, const Grant& g) {
    ConnectToken t{.expires = g.expires, .nonce = nonce, .shard = g.shard, .keys = g.keys};
    std::vector<std::uint8_t> plain;
    format::put_u64(plain, g.account);
    format::put_u64(plain, g.session);
    crypto::put_address(plain, g.shard);
    plain.insert(plain.end(), g.keys.client_to_server.begin(), g.keys.client_to_server.end());
    plain.insert(plain.end(), g.keys.server_to_client.begin(), g.keys.server_to_client.end());
    std::vector<std::uint8_t> sealed;
    crypto::xseal(issuer, nonce, plain, token_ad(g.expires), sealed);
    std::ranges::copy(sealed, t.sealed.begin());
    return t;
}

std::optional<ConnectToken> ConnectToken::parse(std::span<const std::uint8_t> b) {
    if (b.size() != kTokenSize || format::load_le(b.first(4)) != kTokenVersion) {
        return std::nullopt;
    }
    ConnectToken t;
    t.expires = format::load_le(b.subspan(4, 8));
    b = b.subspan(12);
    t.nonce = take<kTokenNonceSize>(b);
    b = b.subspan(kTokenNonceSize);
    t.shard = crypto::get_address(b);
    b = b.subspan(kAddressSize);
    t.keys.client_to_server = take<kKeySize>(b);
    b = b.subspan(kKeySize);
    t.keys.server_to_client = take<kKeySize>(b);
    b = b.subspan(kKeySize);
    t.sealed = take<kPrivateSealedSize>(b);
    return t;
}

std::vector<std::uint8_t> ConnectToken::bytes() const {
    std::vector<std::uint8_t> b;
    format::put_u32(b, kTokenVersion);
    format::put_u64(b, expires);
    b.insert(b.end(), nonce.begin(), nonce.end());
    crypto::put_address(b, shard);
    b.insert(b.end(), keys.client_to_server.begin(), keys.client_to_server.end());
    b.insert(b.end(), keys.server_to_client.begin(), keys.server_to_client.end());
    b.insert(b.end(), sealed.begin(), sealed.end());
    return b;
}

std::vector<std::uint8_t> ConnectToken::request(std::uint64_t schema_hash) const {
    std::vector<std::uint8_t> d;
    format::put_u32(d, kHandshakeId);
    d.push_back(kKindRequest);
    format::put_u64(d, schema_hash);
    format::put_u64(d, expires);
    d.insert(d.end(), nonce.begin(), nonce.end());
    d.insert(d.end(), sealed.begin(), sealed.end());
    d.resize(kRequestSize);
    return d;
}

std::expected<std::vector<std::uint8_t>, HandshakeError> ConnectToken::respond(
    std::span<const std::uint8_t> challenge) const {
    if (challenge.size() != kChallengeSize || format::load_le(challenge.first(4)) != kHandshakeId ||
        challenge[4] != kKindChallenge) {
        return std::unexpected(HandshakeError::malformed);
    }
    std::vector<std::uint8_t> r(challenge.begin(), challenge.end());
    r[4] = kKindResponse;
    std::vector<std::uint8_t> ad = r;
    crypto::xseal(keys.client_to_server, challenge.subspan(5, kTokenNonceSize), {}, ad, r);
    return r;
}

Gate::Gate(const GateConfig& cfg) : cfg_(cfg), random_(crypto::random) { random_(challenge_key_); }

std::expected<Outcome, HandshakeError> Gate::handle(const Address& from, std::span<const std::uint8_t> d,
                                                    std::uint64_t now) {
    if (d.size() < 5 || format::load_le(d.first(4)) != kHandshakeId) {
        return std::unexpected(HandshakeError::malformed);
    }
    switch (d[4]) {
    case kKindRequest:
        return request(from, d, now);
    case kKindResponse:
        return response(from, d, now);
    }
    return std::unexpected(HandshakeError::malformed);
}

std::expected<Outcome, HandshakeError> Gate::request(const Address& from, std::span<const std::uint8_t> d,
                                                     std::uint64_t now) {
    if (d.size() != kRequestSize || !std::ranges::all_of(d.subspan(kRequestTokenEnd), [](auto b) { return b == 0; })) {
        return std::unexpected(HandshakeError::malformed);
    }
    if (format::load_le(d.subspan(5, 8)) != cfg_.schema_hash) {
        return std::unexpected(HandshakeError::foreign);
    }
    auto expires = format::load_le(d.subspan(13, 8));
    if (now >= expires) {
        return std::unexpected(HandshakeError::expired);
    }
    auto nonce = take<kTokenNonceSize>(d.subspan(21));
    std::vector<std::uint8_t> plain;
    if (!crypto::xopen(cfg_.issuer, nonce, d.subspan(45, kPrivateSealedSize), token_ad(expires), plain)) {
        return std::unexpected(HandshakeError::forged);
    }
    std::span<const std::uint8_t> p = plain;
    if (crypto::get_address(p.subspan(16)) != cfg_.shard) {
        return std::unexpected(HandshakeError::wrong_shard);
    }
    if (admitted_.contains(nonce)) {
        return std::unexpected(HandshakeError::replayed);
    }

    TokenNonce challenge_nonce{};
    random_(challenge_nonce);
    std::vector<std::uint8_t> box(nonce.begin(), nonce.end());
    box.insert(box.end(), p.begin(), p.begin() + 16);
    format::put_u64(box, expires);
    format::put_u64(box, now + kChallengeLifetime);
    crypto::put_address(box, from);
    box.insert(box.end(), p.begin() + 16 + kAddressSize, p.end());

    Challenge c;
    format::put_u32(c.bytes, kHandshakeId);
    c.bytes.push_back(kKindChallenge);
    c.bytes.insert(c.bytes.end(), challenge_nonce.begin(), challenge_nonce.end());
    std::vector<std::uint8_t> ad(c.bytes.begin(), c.bytes.begin() + 4);
    crypto::xseal(challenge_key_, challenge_nonce, box, ad, c.bytes);
    return c;
}

std::expected<Outcome, HandshakeError> Gate::response(const Address& from, std::span<const std::uint8_t> d,
                                                      std::uint64_t now) {
    if (d.size() != kResponseSize) {
        return std::unexpected(HandshakeError::malformed);
    }
    auto challenge_nonce = d.subspan(5, kTokenNonceSize);
    std::vector<std::uint8_t> box;
    if (!crypto::xopen(challenge_key_, challenge_nonce, d.subspan(5 + kTokenNonceSize, kChallengePlain + kTagSize),
                       d.first(4), box)) {
        return std::unexpected(HandshakeError::forged);
    }
    std::span<const std::uint8_t> b = box;
    auto nonce = take<kTokenNonceSize>(b);
    auto r = b.subspan(kTokenNonceSize);
    Admission a{
        .peer = from,
        .account = format::load_le(r.subspan(0, 8)),
        .session = format::load_le(r.subspan(8, 8)),
        .expires = format::load_le(r.subspan(16, 8)),
        .keys = {},
    };
    auto deadline = format::load_le(r.subspan(24, 8));
    if (now >= a.expires || now >= deadline) {
        return std::unexpected(HandshakeError::expired);
    }
    if (!std::ranges::equal(r.subspan(32, kAddressSize), address_bytes(from))) {
        return std::unexpected(HandshakeError::address);
    }
    a.keys.client_to_server = take<kKeySize>(r.subspan(32 + kAddressSize));
    a.keys.server_to_client = take<kKeySize>(r.subspan(32 + kAddressSize + kKeySize));
    std::vector<std::uint8_t> empty;
    if (!crypto::xopen(a.keys.client_to_server, challenge_nonce, d.subspan(kChallengeSize), d.first(kChallengeSize),
                       empty)) {
        return std::unexpected(HandshakeError::forged);
    }
    if (admitted_.contains(nonce)) {
        return std::unexpected(HandshakeError::replayed);
    }
    std::erase_if(admitted_, [now](const auto& entry) { return now >= entry.second; });
    admitted_.emplace(nonce, a.expires);
    return a;
}

}
