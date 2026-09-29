#include "marque/world.hpp"

#include <cstdio>
#include <cstring>
#include <vector>

static int failures = 0;

static void check(bool ok, const char* what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok) {
        ++failures;
    }
}

static std::vector<std::uint8_t> hp_frame(std::int64_t id, std::int32_t hp, std::int32_t max_hp) {
    std::vector<std::uint8_t> out(17);
    out[0] = 1;
    std::memcpy(out.data() + 1, &id, 8);
    std::memcpy(out.data() + 9, &hp, 4);
    std::memcpy(out.data() + 13, &max_hp, 4);
    return out;
}

static std::vector<std::uint8_t> despawn_frame(std::int64_t id) {
    std::vector<std::uint8_t> out(9);
    out[0] = 2;
    std::memcpy(out.data() + 1, &id, 8);
    return out;
}

int main() {
    marque::World world;
    marque::Replicator replicator(world);

    check(replicator.apply(hp_frame(7, 40, 50)).has_value(), "valid hp frame applies");
    auto v = world.vitals({7});
    check(v && v->hp == 40 && v->max_hp == 50, "world reads hp 40/50 for player 7");

    auto over = replicator.apply(hp_frame(7, 60, 50));
    check(!over && over.error() == "hp must satisfy 0 <= hp <= max_hp and max_hp >= 1", "hp above max is refused");
    check(world.vitals({7})->hp == 40, "refused frame leaves hp at 40");

    auto shortf = replicator.apply(std::vector<std::uint8_t>{1, 2, 3});
    check(!shortf && shortf.error() == "hp frame must be 17 bytes, got 3", "truncated frame is refused");

    auto unknown = replicator.apply(std::vector<std::uint8_t>{99});
    check(!unknown && unknown.error() == "unknown message kind 99", "unknown kind is refused");

    check(replicator.apply(despawn_frame(7)).has_value(), "despawn applies");
    check(!world.vitals({7}).has_value() && world.player_count() == 0, "player 7 is gone after despawn");

    std::printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
