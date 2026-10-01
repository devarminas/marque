#include "marque/transport/endpoint.hpp"

namespace marque::transport {

std::expected<Endpoint, ConfigError> Endpoint::create(Role role, const Config& cfg, std::shared_ptr<Opener> opener,
                                                     std::shared_ptr<Sealer> sealer, std::uint64_t now) {
    auto rx = Receiver::create(role, cfg, std::move(opener));
    if (!rx) {
        return std::unexpected(rx.error());
    }
    auto tx = Sender::create(role, cfg, std::move(sealer), now);
    if (!tx) {
        return std::unexpected(tx.error());
    }
    return Endpoint(std::move(*rx), std::move(*tx));
}

std::expected<Received, Error> Endpoint::receive(std::span<const std::uint8_t> datagram, std::uint64_t now) {
    if (tx_.state() != State::open) {
        return std::unexpected(Error::closed);
    }
    auto r = rx_.receive(datagram);
    if (r) {
        tx_.observe(r->peer_ack, r->own_ack, now);
    }
    return r;
}

}
