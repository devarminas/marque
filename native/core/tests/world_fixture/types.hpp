#pragma once

#include "marque/world.hpp"
#include <array>
#include <string>

namespace world_fixture {

using namespace marque::world;

struct Position {
    double x;
    double y;
    double z;
    bool operator==(const Position&) const = default;
};

struct Health {
    int hp;
    int max_hp;
    int mana;
    int max_mana;
    bool operator==(const Health&) const = default;
};

struct Equipment {
    std::array<std::uint32_t, 8> slots;
    std::string label;
    bool operator==(const Equipment&) const = default;
};

struct Casting {
    std::optional<std::uint32_t> spell;
    bool operator==(const Casting&) const = default;
};

struct Appearance {
    std::string name;
    std::uint32_t model;
    bool operator==(const Appearance&) const = default;
};

struct Catalog : Components<Position, Health, Equipment, Casting, Appearance> {
    static Position interpolate(const Position& a, const Position& b, double alpha) {
        return {a.x + (b.x - a.x) * alpha, a.y + (b.y - a.y) * alpha, a.z + (b.z - a.z) * alpha};
    }
};

struct Event {
    std::uint32_t tick;
    int marker;
    bool operator==(const Event&) const = default;
};

using Events = std::vector<Event>;
using World = Applier<Catalog, Events>;
using Batch = CompleteTick<Catalog, Events>;

inline Enter<Catalog> entry(Entity id, double x, int hp = 90) {
    return {id, {Position{x, 1, 2}, Health{hp, 100, 20, 50},
                 Equipment{{1, 2, 3, 4, 5, 6, 7, 8}, "fixture equipment owned label 32"},
                 Casting{17}, Appearance{"fixture appearance owned name 32", 9}}};
}

inline Batch batch(std::uint32_t tick, std::vector<Change<Catalog>> changes, int marker = 0) {
    return {{tick}, {1000000}, std::move(changes), {{tick, marker}}};
}

}
