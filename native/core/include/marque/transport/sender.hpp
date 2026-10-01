#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <expected>
#include <span>
#include <vector>

#include "marque/transport/config.hpp"
#include "marque/transport/packet.hpp"

namespace marque::transport {

struct StartAt;

enum class State : std::uint8_t { open, timed_out, slow_client };

const char* to_string(State s);

struct Flushed {
    std::vector<std::vector<std::uint8_t>> datagrams;
    std::size_t unreliable_sent = 0;
    State state = State::open;
};

class Sender {
public:
    static std::expected<Sender, ConfigError> create(Role role, const Config& cfg, std::uint64_t now);

    std::expected<void, Error> send(std::span<const std::uint8_t> msg);

    void observe(AckWindow peer_ack, AckWindow own_ack, std::uint64_t now);

    std::expected<Flushed, Error> flush(std::uint64_t now, const Unreliable& unreliable = {});

    State state() const { return state_; }

    std::size_t backlog() const { return queue_.size(); }

private:
    struct OutFragment {
        bool acked = false;
        bool sent = false;
        std::uint64_t last_sent = 0;
    };

    struct OutMessage {
        std::vector<std::uint8_t> data;
        std::vector<OutFragment> fragments;
    };

    struct FragmentRef {
        std::uint64_t serial = 0;
        std::uint8_t index = 0;
    };

    struct SentDatagram {
        bool live = false;
        std::uint16_t seq = 0;
        std::vector<FragmentRef> fragments;
    };

    struct Datagram;

    Sender(Role role, const Config& cfg, std::uint64_t now);

    void close(State state);
    void ack(std::uint16_t seq);

    friend struct StartAt;

    Role role_;
    Config cfg_;
    std::uint16_t next_seq_ = 0;
    std::array<SentDatagram, 256> ring_;
    AckWindow own_;
    std::uint64_t front_ = 0;
    std::deque<OutMessage> queue_;
    std::size_t queued_bytes_ = 0;
    std::uint64_t last_send_;
    std::uint64_t last_receive_;
    State state_ = State::open;
};

}
