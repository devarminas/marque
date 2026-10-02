#include "world_fixture/types.hpp"
#include "world_fixture/allocation.hpp"
#include "check.hpp"

using namespace world_fixture;
using marque::test::check;

int main() {
    std::uint64_t failures = 0;
    bool complete = false;
    bool preserved = true;
    for (std::uint64_t nth = 0; nth < 1000; ++nth) {
        auto world = *World::create();
        check(world.apply(batch(1, {entry(Player{7, 3}, 0)}, 41)).has_value(), "allocation fixture entry");
        auto before = world.reader().latest();
        auto old_table = before->world().table<Position>();
        auto input = batch(2, {entry(Player{7, 4}, 100, 50), entry(Npc{8, 1}, 20), Leave{Node{4000000000u, 3}}}, 42);
        world_allocation::begin(nth);
        try {
            const auto result = world.apply(std::move(input));
            world_allocation::end();
            complete = result.has_value();
            check(complete && world.reader().latest()->tick().value == 2 && world.reader().latest()->events() == Events{{2, 42}},
                  "all allocations allowed publishes whole state and events");
            check(*old_table.find(Player{7, 3}) == Position{0, 1, 2}, "retained allocation fixture survives successful publication");
            std::printf("injected_allocation_failures=%llu\n", static_cast<unsigned long long>(failures));
            break;
        } catch (const std::bad_alloc&) {
            world_allocation::end();
            ++failures;
            preserved &= world.reader().latest() == before && before->events() == Events{{1, 41}};
            preserved &= *old_table.find(Player{7, 3}) == Position{0, 1, 2};
            preserved &= !before->world().contains(Player{7, 4}) && !before->world().contains(Npc{8, 1});
        }
    }
    world_allocation::end();
    check(failures > 10 && complete, "every allocation point before successful publication was exercised");
    check(preserved, "each injected allocation failure preserved publication and retained reads");
    return marque::test::check_finish();
}
