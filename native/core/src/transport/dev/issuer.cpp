#include "marque/transport/dev_issuer.hpp"

#include <algorithm>
#include <string_view>

#include "../crypto.hpp"

namespace marque::transport::dev {

namespace {

constexpr std::string_view kKeyText = "marque-dev-issuer-key-not-secret";

}

const Key kIssuerKey = [] {
    static_assert(kKeyText.size() == kKeySize);
    Key k{};
    std::ranges::copy(kKeyText, k.begin());
    return k;
}();

ConnectToken issue(std::uint64_t account, std::uint64_t session, const Address& shard, std::uint64_t expires) {
    TokenNonce nonce{};
    Grant g{.account = account, .session = session, .shard = shard, .expires = expires, .keys = {}};
    crypto::random(nonce);
    crypto::random(g.keys.client_to_server);
    crypto::random(g.keys.server_to_client);
    return issue_token(kIssuerKey, nonce, g);
}

}
