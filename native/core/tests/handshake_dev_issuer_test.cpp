#include <cstdint>
#include <variant>

#include "check.hpp"
#include "marque/transport/dev_issuer.hpp"
#include "marque/transport/handshake.hpp"

namespace {

namespace tr = marque::transport;
using marque::test::check;

}

int main() {
    constexpr std::uint64_t now = 1'800'000'000;
    tr::Address shard;
    shard.ip[10] = 0xff;
    shard.ip[11] = 0xff;
    shard.ip[12] = 127;
    shard.ip[15] = 1;
    shard.port = 7777;
    tr::Address client = shard;
    client.port = 40000;

    tr::Gate gate({.schema_hash = 1, .shard = shard, .issuer = tr::dev::kIssuerKey});
    auto tok = tr::dev::issue(7, 8, shard, now + 30);
    auto challenge = gate.handle(client, tok.request(1), now);
    check(challenge && std::holds_alternative<tr::Challenge>(*challenge), "a dev token earns a challenge");
    auto response = tok.respond(std::get<tr::Challenge>(*challenge).bytes);
    auto admitted = gate.handle(client, *response, now);
    tr::Admission want{.peer = client, .account = 7, .session = 8, .expires = now + 30, .keys = tok.keys};
    check(admitted && std::holds_alternative<tr::Admission>(*admitted) && std::get<tr::Admission>(*admitted) == want,
          "a shard holding the dev key admits account 7, session 8");
    check(tok.keys.client_to_server != tok.keys.server_to_client &&
              tr::dev::issue(7, 8, shard, now + 30).nonce != tok.nonce,
          "two issues draw different nonces and one token's two keys differ");
    return marque::test::check_finish();
}
