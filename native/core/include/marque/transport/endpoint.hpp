#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <memory>
#include <span>
#include <utility>

#include "marque/transport/config.hpp"
#include "marque/transport/packet.hpp"
#include "marque/transport/receiver.hpp"
#include "marque/transport/sender.hpp"

namespace marque::client { class Session; }

namespace marque::transport {

struct StartAt;

class Endpoint {
public:
    static std::expected<Endpoint, ConfigError> create(Role role, const Config& cfg, std::shared_ptr<Opener> opener,
                                                       std::shared_ptr<Sealer> sealer, std::uint64_t now, PlaintextObserver observer={});

    std::expected<Received, Error> receive(std::span<const std::uint8_t> datagram, std::uint64_t now);

    std::expected<void, Error> send(std::span<const std::uint8_t> msg) { return tx_.send(msg); }

    std::expected<Flushed, Error> flush(std::uint64_t now, const Unreliable& unreliable = {}) {
        return tx_.flush(now, unreliable);
    }

    void capture(OutboundObserver observer) { tx_.capture(std::move(observer)); }
    State state() const { return tx_.state(); }

    std::size_t backlog() const { return tx_.backlog(); }

    const Stats& stats() const { return rx_.stats(); }

private:
    Endpoint(Receiver rx, Sender tx) : rx_(std::move(rx)), tx_(std::move(tx)) {}

    friend struct StartAt;
    friend class marque::client::Session;
    std::expected<Received,Error> consume(std::span<const std::uint8_t> header,std::span<const std::uint8_t> body,std::uint64_t now);

    Receiver rx_;
    Sender tx_;
};

}
