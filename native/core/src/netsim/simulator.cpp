#include "marque/netsim/simulator.hpp"

#include <algorithm>

#include "marque/netsim/fate.hpp"
#include "marque/netsim/rng.hpp"

namespace marque::netsim {

namespace {

constexpr std::uint64_t kDirSaltAToB = 0xA5A5A5A5A5A5A5A5ULL;
constexpr std::uint64_t kDirSaltBToA = 0x5A5A5A5A5A5A5A5AULL;

}

struct Scheduled {
    std::uint64_t seq = 0;
    std::uint8_t copy_index = 0;
    std::uint64_t at = 0;
    std::vector<std::uint8_t> packet;
};

class DirectionSim {
public:
    explicit DirectionSim(std::uint64_t seed) : rng_(seed) {}

    void send(const Profile& profile, std::vector<std::uint8_t> packet, std::uint64_t now) {
        Fate f = compute_fate(rng_, profile, now);
        std::uint64_t seq = next_seq_++;

        switch (f.kind) {
            case FateKind::kDropped:
                return;
            case FateKind::kDeliverOnce:
                pending_.push_back(Scheduled{seq, 0, f.at, packet});
                return;
            case FateKind::kDeliverTwice:
                pending_.push_back(Scheduled{seq, 0, f.at, packet});
                pending_.push_back(Scheduled{seq, 1, f.at2, std::move(packet)});
                return;
        }
    }

    std::vector<Delivery> poll(std::uint64_t now) {
        std::vector<Scheduled> due;
        std::vector<Scheduled> rest;
        due.reserve(pending_.size());
        rest.reserve(pending_.size());
        for (auto& s : pending_) {
            if (s.at <= now) {
                due.push_back(std::move(s));
            } else {
                rest.push_back(std::move(s));
            }
        }
        pending_ = std::move(rest);

        std::sort(due.begin(), due.end(), [](const Scheduled& a, const Scheduled& b) {
            if (a.at != b.at) return a.at < b.at;
            if (a.seq != b.seq) return a.seq < b.seq;
            return a.copy_index < b.copy_index;
        });

        std::vector<Delivery> out;
        out.reserve(due.size());
        for (auto& s : due) {
            out.push_back(Delivery{std::move(s.packet), s.at});
        }
        return out;
    }

private:
    Rng rng_;
    std::uint64_t next_seq_ = 0;
    std::vector<Scheduled> pending_;
};

Simulator::Simulator(Profile profile, std::uint64_t seed)
    : profile_(profile),
      ab_(std::make_unique<DirectionSim>(seed ^ kDirSaltAToB)),
      ba_(std::make_unique<DirectionSim>(seed ^ kDirSaltBToA)) {}

Simulator::~Simulator() = default;

void Simulator::send(Direction dir, std::vector<std::uint8_t> packet, std::uint64_t now) {
    stream(dir).send(profile_, std::move(packet), now);
}

std::vector<Delivery> Simulator::poll(Direction dir, std::uint64_t now) {
    return stream(dir).poll(now);
}

DirectionSim& Simulator::stream(Direction dir) {
    return dir == Direction::kAToB ? *ab_ : *ba_;
}

}
