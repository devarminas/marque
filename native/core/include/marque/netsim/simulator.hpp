#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include "marque/netsim/profile.hpp"

namespace marque::netsim {

enum class Direction {
    kAToB,
    kBToA,
};

struct Delivery {
    std::vector<std::uint8_t> packet;
    std::uint64_t at = 0;
};

class DirectionSim;

class Simulator {
public:
    Simulator(Profile profile, std::uint64_t seed);
    ~Simulator();

    Simulator(const Simulator&) = delete;
    Simulator& operator=(const Simulator&) = delete;

    void send(Direction dir, std::vector<std::uint8_t> packet, std::uint64_t now);

    std::vector<Delivery> poll(Direction dir, std::uint64_t now);

private:
    DirectionSim& stream(Direction dir);

    Profile profile_;
    std::unique_ptr<DirectionSim> ab_;
    std::unique_ptr<DirectionSim> ba_;
};

}
