#include <algorithm>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "check.hpp"
#include "marque/transport/endpoint.hpp"
#include "marque/transport/handshake.hpp"
#include "marque/transport/session_seal.hpp"

namespace {

namespace tr = marque::transport;
using marque::test::check;

constexpr std::uint64_t kHash = 0x0123456789abcdef;
constexpr std::uint64_t kNow = 1'800'000'000;

tr::Address v4(std::uint8_t a, std::uint8_t b, std::uint8_t c, std::uint8_t d, std::uint16_t port) {
    tr::Address out;
    out.ip[10] = 0xff;
    out.ip[11] = 0xff;
    out.ip[12] = a;
    out.ip[13] = b;
    out.ip[14] = c;
    out.ip[15] = d;
    out.port = port;
    return out;
}

const tr::Address kShard = v4(198, 51, 100, 10, 7777);
const tr::Address kClient = v4(203, 0, 113, 7, 40000);

tr::Key filled(std::uint8_t start) {
    tr::Key k{};
    for (std::size_t i = 0; i < k.size(); ++i) {
        k[i] = static_cast<std::uint8_t>(start + i);
    }
    return k;
}

const tr::Key kIssuer = filled(0x40);
const tr::SessionKeys kKeys{filled(0x00), filled(0x20)};

tr::ConnectToken token_for(std::uint32_t account) {
    tr::TokenNonce nonce{};
    for (std::size_t i = 0; i < 4; ++i) {
        nonce[i] = static_cast<std::uint8_t>(account >> (8 * i));
    }
    return tr::issue_token(kIssuer, nonce,
                           {.account = account, .session = account + 1000, .shard = kShard, .expires = kNow + 30,
                            .keys = kKeys});
}

void unanswered_requests_leave_no_state() {
    tr::Gate gate({.schema_hash = kHash, .shard = kShard, .issuer = kIssuer});
    int challenges = 0;
    std::size_t largest_reply = 0;
    for (std::uint32_t i = 0; i < 10'000; ++i) {
        auto request = token_for(i).request(kHash);
        auto o = gate.handle(v4(10, 0, static_cast<std::uint8_t>(i >> 8), static_cast<std::uint8_t>(i), 5000), request,
                             kNow);
        if (o && std::holds_alternative<tr::Challenge>(*o)) {
            ++challenges;
            largest_reply = std::max(largest_reply, std::get<tr::Challenge>(*o).bytes.size());
        }
    }
    check(challenges == 10'000, "10000 valid requests each earn a challenge");
    check(largest_reply == 183, "every challenge is 183 bytes against a 512-byte request");
    check(gate.admissions() == 0, "the gate holds 0 admissions after 10000 unanswered requests");
}

void every_handshake_reply_fits_its_request() {
    tr::Gate gate({.schema_hash = kHash, .shard = kShard, .issuer = kIssuer});
    auto tok = token_for(7);
    auto request = tok.request(kHash);
    auto challenge = gate.handle(kClient, request, kNow);
    check(request.size() == 512 && challenge && std::get<tr::Challenge>(*challenge).bytes.size() == 183,
          "a 512-byte request earns a 183-byte challenge");
    auto response = tok.respond(std::get<tr::Challenge>(*challenge).bytes);
    check(response && response->size() == 199, "the response is 199 bytes");
    auto admitted = gate.handle(kClient, *response, kNow + 1);
    tr::Admission want{.peer = kClient, .account = 7, .session = 1007, .expires = kNow + 30, .keys = kKeys};
    check(admitted && std::holds_alternative<tr::Admission>(*admitted) && std::get<tr::Admission>(*admitted) == want,
          "the response is admitted with no reply bytes, carrying account 7 and session 1007");
    check(gate.admissions() == 1, "the gate holds 1 admission after one completed handshake");
}

void tampered_sealed_datagram_is_refused() {
    auto cfg = tr::default_config(kHash);
    auto cli =
        tr::Endpoint::create(tr::Role::client, cfg, std::make_shared<tr::SessionSeal>(tr::Role::client, kKeys), 0);
    check(cli && cli->send(std::vector<std::uint8_t>{0x05, 0x01}).has_value(), "client queues one intent");
    auto flushed = cli->flush(100000, {.stamp = 1, .items = {{0x01}}});
    const auto good = flushed->datagrams.at(0);
    std::map<std::string, std::size_t> got;
    for (std::size_t i = 0; i < good.size(); ++i) {
        auto srv =
            tr::Endpoint::create(tr::Role::server, cfg, std::make_shared<tr::SessionSeal>(tr::Role::server, kKeys), 0);
        auto bad = good;
        bad[i] ^= 0x01;
        auto r = srv->receive(bad, 100000);
        const auto& st = srv->stats();
        got[std::string(r ? "ok" : tr::to_string(r.error())) + " malformed=" + std::to_string(st.malformed) +
            " foreign=" + std::to_string(st.foreign) + " accepted=" + std::to_string(st.accepted)]++;
    }
    std::map<std::string, std::size_t> want{
        {"foreign malformed=0 foreign=1 accepted=0", 12},
        {"malformed malformed=1 foreign=0 accepted=0", good.size() - 12},
    };
    check(got == want, "a flipped byte in the 12 id and hash bytes is foreign, anywhere else malformed");
    auto srv =
        tr::Endpoint::create(tr::Role::server, cfg, std::make_shared<tr::SessionSeal>(tr::Role::server, kKeys), 0);
    auto r = srv->receive(good, 100000);
    check(r && r->reliable == std::vector<std::vector<std::uint8_t>>{{0x05, 0x01}}, "the untouched datagram delivers");
    auto again = srv->receive(good, 100000);
    check(!again && again.error() == tr::Error::malformed, "the same datagram again is malformed");
}

}

int main() {
    unanswered_requests_leave_no_state();
    every_handshake_reply_fits_its_request();
    tampered_sealed_datagram_is_refused();
    return marque::test::check_finish();
}
