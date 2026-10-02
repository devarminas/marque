#include "world_fixture/types.hpp"
#include "check.hpp"

using namespace world_fixture;
using marque::test::check;

int main() {
    auto applier = *World::create();
    auto reader = applier.reader();
    check(!reader.latest(), "no publication before a complete tick");
    const Player id{7, 3};
    check(applier.apply(batch(10, {entry(id, 0)}, 41)).has_value(), "complete entry at tick 10");
    auto first = reader.latest();
    auto pinned_table = first->world().table<Position>();
    check(first->tick().value == 10 && first->events() == Events{{10, 41}}, "tick 10 state and events publish together");
    check(*pinned_table.find(id) == Position{0, 1, 2}, "entry position is literal 0 1 2");
    check(*first->world().table<Health>().find(id) == Health{90, 100, 20, 50}, "complete entry health");
    check(applier.apply(batch(11, {Replace<Position>{id, {4, 1, 2}}}, 42)).has_value(), "component replacement");
    auto second = reader.latest();
    check(*second->world().table<Position>().find(id) == Position{4, 1, 2}, "tick 11 position");
    check(*second->world().table<Health>().find(id) == Health{90, 100, 20, 50}, "omitted health unchanged");
    check(second->world().table<Casting>().find(id)->spell == 17, "omitted optional component unchanged");
    check(applier.apply(batch(12, {Leave{id}}, 43)).has_value(), "leave accepted");
    check(!reader.latest()->world().contains(id) && reader.latest()->world().table<Position>().find(id) == nullptr,
          "leave removes membership and values");
    auto absent = reader.latest();
    auto failed = applier.apply(batch(13, {Replace<Position>{id, {8, 1, 2}}}, 44));
    check(!failed && failed.error() == ApplyError::unknown_entity && reader.latest() == absent,
          "partial re-entry rejects whole publication");
    auto incomplete = entry(id, 8);
    std::get<std::optional<Health>>(incomplete.values).reset();
    failed = applier.apply(batch(13, {incomplete}, 44));
    check(!failed && failed.error() == ApplyError::incomplete_entry && reader.latest() == absent,
          "incomplete full entry rejected");
    check(applier.apply(batch(13, {entry(id, 8, 70)}, 44)).has_value(), "complete same-generation interest re-entry");
    check(*reader.latest()->world().table<Health>().find(id) == Health{70, 100, 20, 50}, "re-entry uses new health");
    const Player next{7, 4};
    check(applier.apply(batch(14, {Leave{id}, entry(next, 100, 50)}, 45)).has_value(), "old leave before new-generation entry");
    check(!reader.latest()->world().contains(id) && reader.latest()->world().contains(next), "reuse retires old handle");
    check(*reader.latest()->world().table<Position>().find(next) == Position{100, 1, 2}, "replacement generation does not inherit pose");
    check(applier.apply(batch(15, {Replace<Position>{id, {-9, 0, 0}}, Leave{id}, Replace<Position>{next, {104, 1, 2}}}, 46)).has_value(),
          "stale lower generations filtered before conflict validation");
    check(*reader.latest()->world().table<Position>().find(next) == Position{104, 1, 2}, "valid replacement survives stale changes");
    auto before_failure = reader.latest();
    failed = applier.apply(batch(16, {Replace<Health>{next, {1, 100, 0, 50}}, Replace<Position>{next, {8, 1, 2}}, Replace<Position>{next, {9, 1, 2}}}, 99));
    check(!failed && failed.error() == ApplyError::conflicting_change, "conflicting duplicate component rejected");
    check(reader.latest() == before_failure && reader.latest()->events() == Events{{15, 46}}, "failure preserves publication pointer and events");
    check(*reader.latest()->world().table<Health>().find(next) == Health{50, 100, 20, 50}, "failure rolls back earlier valid changes");
    failed = applier.apply(batch(15, {}, 99));
    check(!failed && failed.error() == ApplyError::stale_tick && reader.latest() == before_failure, "duplicate tick rejected without repeat events");
    check(applier.apply(batch(16, {Replace<Casting>{next, {std::nullopt}}}, 47)).has_value(), "present component clears nested optional");
    check(!reader.latest()->world().table<Casting>().find(next)->spell, "cast clear remains a present component");
    check(applier.apply(batch(18, {}, 48)).has_value(), "empty state tick publishes events and preserves omitted entity");
    check(reader.latest()->world().contains(next) && reader.latest()->tick().value == 18 && reader.latest()->events() == Events{{18, 48}},
          "empty tick has simultaneous state and events");
    Batch event_bundle{{20}, {9000000}, {}, {{19, 71}, {20, 72}}};
    check(applier.apply(std::move(event_bundle)).has_value(), "owning event bundle with embedded metadata accepted");
    check(reader.latest()->events() == Events{{19, 71}, {20, 72}}, "opaque event values preserve embedded metadata and order");
    check(*pinned_table.find(id) == Position{0, 1, 2} && first->events() == Events{{10, 41}}, "old retained table and publication remain readable");
    check(*second->world().table<Position>().find(id) == Position{4, 1, 2}, "retained second tick survives leave and reuse");

    auto reversed = *World::create();
    check(reversed.apply(batch(10, {entry(id, 0)})).has_value(), "reversed-order fixture entry");
    check(reversed.apply(batch(14, {entry(next, 100, 50), Leave{id}})).has_value(), "new generation before old leave");
    check(*reversed.reader().latest()->world().table<Position>().find(next) == Position{100, 1, 2}, "both change orders produce literal replacement");
    check(reversed.apply(batch(15, {Leave{Player{7, 5}}})).has_value(), "higher generation leave advances retirement ledger");
    check(reversed.apply(batch(16, {entry(next, -10), Leave{next}})).has_value(), "conflicting stale generation ignored after higher leave");
    check(reversed.reader().latest()->world().entities().empty(), "higher retirement prevents lower-generation resurrection");
    check(reversed.apply(batch(17, {entry(Player{7, 5}, 12), entry(Npc{7, 5}, 30)})).has_value(), "kinds use independent sparse slots");
    check(reversed.reader().latest()->world().entities().size() == 2, "same numeric slot in two kinds yields two entities");
    check(reversed.apply(batch(18, {Leave{Npc{7, 5}}})).has_value(), "npc leave");
    check(reversed.reader().latest()->world().contains(Player{7, 5}), "npc leave does not retire player");
    check(reversed.apply(batch(19, {Leave{Player{7, 5}}, entry(Player{7, 5}, 1)})).error() == ApplyError::conflicting_change,
          "same-generation enter and leave conflict");

    auto sparse = *World::create(Config{2});
    check(sparse.apply(batch(1, {entry(Item{4000000000u, 7}, 11), Leave{Node{2, 8}}}, 5)).has_value(), "large sparse index and unknown-slot retirement");
    auto sparse_before = sparse.reader().latest();
    check(sparse_before->world().known_slots() == 2 && sparse_before->world().table<Position>().stored_rows() == 2,
          "large index uses exactly two compact rows");
    failed = sparse.apply(batch(2, {Replace<Position>{Item{4000000000u, 7}, {12, 1, 2}}, entry(Player{3, 1}, 20)}, 6));
    check(!failed && failed.error() == ApplyError::slot_limit && sparse.reader().latest() == sparse_before,
          "capacity rejects entire tick including valid earlier update");
    check(*sparse.reader().latest()->world().table<Position>().find(Item{4000000000u, 7}) == Position{11, 1, 2}, "capacity failure preserves sparse pose");
    check(sparse.apply(batch(2, {entry(Node{2, 7}, 99)})).has_value(), "stale entry at retired slot ignored");
    check(!sparse.reader().latest()->world().contains(Node{2, 7}), "unknown-slot leave preserved generation high-water");
    check(sparse.apply(batch(3, {Replace<Position>{Item{4000000000u, 8}, {1, 2, 3}}})).error() == ApplyError::incomplete_entry,
          "higher-generation delta cannot create entity");

    check(sparse.apply(batch(3, {Replace<Position>{Player{99, 1}, {1, 2, 3}}})).error() == ApplyError::unknown_entity,
          "delta for wholly unknown slot rejected without manufacturing entity");
    check(applier.apply(batch(21, {Replace<Position>{next, {110, 1, 2}}, Replace<Position>{next, {110, 1, 2}}})).has_value(),
          "identical duplicate replacement is harmless");
    check(*reader.latest()->world().table<Position>().find(next) == Position{110, 1, 2}, "duplicate replacement has literal result");
    first.reset();
    check(*pinned_table.find(id) == Position{0, 1, 2}, "table alone owns its retained const backing");
    auto orphan_reader = [] {
        auto owner = *World::create();
        check(owner.apply(batch(1, {entry(Player{9, 2}, 16)}, 91)).has_value(), "orphan reader fixture entry");
        return owner.reader();
    }();
    check(orphan_reader.latest()->events() == Events{{1, 91}} && *orphan_reader.latest()->world().table<Position>().find(Player{9, 2}) == Position{16, 1, 2},
          "reader stays readable after applier destruction");

    using Small = Components<int>;
    auto small = *Applier<Small, int>::create();
    check(small.apply({{0}, {0}, {Enter<Small>{Player{1, 1}, {4}}}, 7}).has_value(), "catalog without transform and tick zero supported");
    check(*small.reader().latest()->world().table<int>().find(Player{1, 1}) == 4, "schema-neutral catalog reads literal integer");
    return marque::test::check_finish();
}
