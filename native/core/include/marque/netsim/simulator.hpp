#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include "marque/netsim/profile.hpp"

namespace marque::netsim {

// Direction picks which of the simulator's two independent packet streams
// a call applies to.
enum class Direction {
    kAToB,
    kBToA,
};

// A packet due to arrive: the opaque payload plus the time the simulated
// network delivers it. Returned from Simulator::poll in delivery order.
struct Delivery {
    std::vector<std::uint8_t> packet;
    std::uint64_t at = 0;
};

class DirectionSim;  // defined in simulator.cpp; owns one direction's RNG
                      // stream and pending-delivery queue.

// Simulator sits between two endpoints and decides, deterministically from
// a seed and a Profile, whether each sent packet is dropped, delayed,
// duplicated, or reordered before poll hands it back. It never inspects
// packet contents and never reads wall time; every packet moves as an
// opaque byte vector and every delay is relative to the now callers pass.
class Simulator {
public:
    // Constructs a simulator for profile, seeded so that the same seed and
    // profile always produce the same fate sequence in both directions and
    // across runs.
    Simulator(Profile profile, std::uint64_t seed);
    ~Simulator();

    Simulator(const Simulator&) = delete;
    Simulator& operator=(const Simulator&) = delete;

    // Hands the simulator a packet sent at time now (caller-owned clock,
    // never wall time). Its fate (drop, delay, duplicate, reorder) is
    // decided immediately, deterministically, from the direction's RNG
    // stream.
    void send(Direction dir, std::vector<std::uint8_t> packet, std::uint64_t now);

    // Drains and returns every packet due at or before now, in delivery
    // order.
    std::vector<Delivery> poll(Direction dir, std::uint64_t now);

private:
    DirectionSim& stream(Direction dir);

    Profile profile_;
    std::unique_ptr<DirectionSim> ab_;
    std::unique_ptr<DirectionSim> ba_;
};

}  // namespace marque::netsim
