#pragma once

#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <variant>

namespace marque {

struct PlayerId {
    std::int64_t value;
};

struct Vitals {
    std::int32_t hp;
    std::int32_t max_hp;
};

struct HpMsg {
    PlayerId id;
    Vitals vitals;
};

struct DespawnMsg {
    PlayerId id;
};

using ServerMsg = std::variant<HpMsg, DespawnMsg>;

std::expected<ServerMsg, std::string> decode(std::span<const std::uint8_t> frame);

class World {
public:
    std::optional<Vitals> vitals(PlayerId id) const;
    std::size_t player_count() const { return vitals_.size(); }

private:
    friend class Replicator;
    std::unordered_map<std::int64_t, Vitals> vitals_;
};

class Replicator {
public:
    explicit Replicator(World& world) : world_(world) {}
    std::expected<void, std::string> apply(std::span<const std::uint8_t> frame);

private:
    World& world_;
};

}
