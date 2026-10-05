#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <expected>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <vector>

#include "marque/transport/config.hpp"
#include "marque/transport/packet.hpp"
#include "marque/transport/seal.hpp"

namespace marque::transport {

struct StartAt;
using PlaintextObserver=std::function<void(std::span<const std::uint8_t>,std::span<const std::uint8_t>)>;

struct Received {
    AckWindow peer_ack;
    AckWindow own_ack;
    std::optional<Unreliable> unreliable;
    bool stale = false;
    std::vector<std::vector<std::uint8_t>> reliable;
};

struct Stats {
    std::uint64_t accepted = 0;
    std::uint64_t duplicate = 0;
    std::uint64_t too_old = 0;
    std::uint64_t malformed = 0;
    std::uint64_t foreign = 0;
    std::uint64_t stale = 0;

    friend bool operator==(const Stats&, const Stats&) = default;
};

class Receiver {
public:
    static std::expected<Receiver, ConfigError> create(Role role, const Config& cfg, std::shared_ptr<Opener> opener, PlaintextObserver observer={});

    std::expected<Received, Error> receive(std::span<const std::uint8_t> datagram);

    const Stats& stats() const { return stats_; }

private:
    struct Fragment {
        std::uint8_t index = 0;
        std::vector<std::uint8_t> data;
    };

    struct Partial {
        std::uint8_t count = 0;
        std::vector<Fragment> fragments;
    };

    Receiver(Role role, const Config& cfg, std::shared_ptr<Opener> opener);

    void store(std::uint16_t id, std::uint8_t index, std::uint8_t count, std::span<const std::uint8_t> data);

    friend struct StartAt;
    friend class Endpoint;
    std::expected<Received,Error> consume(std::span<const std::uint8_t> header,std::span<const std::uint8_t> body);
    PlaintextObserver observer_;

    Role from_;
    std::uint64_t hash_;
    std::shared_ptr<Opener> opener_;
    std::optional<AckWindow> window_;
    std::optional<std::uint32_t> newest_stamp_;
    std::uint16_t next_ = 0;
    std::array<Partial, kWindowMessages> partial_;
    std::size_t buffered_ = 0;
    Stats stats_;
    std::vector<std::uint8_t> scratch_;
};

}
