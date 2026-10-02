#include "world_fixture/types.hpp"
#include "check.hpp"

using namespace world_fixture;
using marque::test::check;

struct OptionalCatalog : Components<Position, Health> {
    template<class T> static constexpr bool required(Kind entity_kind) {
        return std::is_same_v<T, Health> || entity_kind == Kind::player;
    }
    static Position interpolate(const Position& a, const Position& b, double alpha) {
        return Catalog::interpolate(a, b, alpha);
    }
};

int main() {
    auto world = *World::create();
    auto reader = world.reader();
    const Player id{7, 3};
    check(!reader.render_at({1000000}), "empty world has no render frame");
    check(world.apply(batch(10, {entry(id, 0)})).has_value(), "first sample anchors timeline");
    check(reader.latest()->sample_time() == Time{1000000}, "first receive time is sample anchor");
    auto one = reader.render_at({-1000000});
    check(one->sample<Position>(id) == Position{0, 1, 2}, "one sample renders without extrapolation");
    auto delta = batch(11, {Replace<Position>{id, {4, 1, 2}}, Replace<Health>{id, {80, 100, 20, 50}}});
    delta.received_at = {1070000};
    check(world.apply(std::move(delta)).has_value(), "jittered arrival accepted");
    check(reader.latest()->sample_time() == Time{1040000}, "later sample uses tick timeline rather than arrival jitter");
    auto frame = reader.render_at({1060000});
    check(frame->alpha() == 0.5 && frame->sample<Position>(id) == Position{2, 1, 2}, "40ms delay gives literal halfway position");
    check(frame->sample<Health>(id) == Health{90, 100, 20, 50}, "discrete values remain previous before new sample time");
    check(reader.render_at({1080000})->sample<Health>(id) == Health{80, 100, 20, 50}, "discrete values switch at new sample time");
    check(reader.render_at({1000000})->sample<Position>(id) == Position{0, 1, 2}, "early render target clamps to previous");
    check(reader.render_at({1120000})->sample<Position>(id) == Position{4, 1, 2}, "late render target clamps to latest");
    check(*reader.latest()->world().table<Position>().find(id) == Position{4, 1, 2}, "rendering does not write authoritative pose");
    check(world.apply(batch(12, {Leave{id}})).has_value(), "leave sample");
    check(reader.render_at({1119999})->sample<Position>(id) == Position{4, 1, 2}, "departed entity remains until newer sample time");
    check(!reader.render_at({1120000})->sample<Position>(id) && reader.render_at({1120000})->entities().empty(), "leave membership switches at newer sample time");
    check(world.apply(batch(13, {entry(id, 8)})).has_value(), "interest re-entry sample");
    check(!reader.render_at({1159999})->sample<Position>(id), "entered entity absent before newer sample time");
    check(reader.render_at({1160000})->sample<Position>(id) == Position{8, 1, 2}, "entered entity snaps to complete value at newer time");
    const Player next{7, 4};
    check(world.apply(batch(14, {entry(next, 100)})).has_value(), "generation reuse sample");
    auto reused = reader.render_at({1180000});
    check(reused->sample<Position>(id) == Position{8, 1, 2} && !reused->sample<Position>(next), "reuse renders old generation before transition without blending");
    check(reader.render_at({1200000})->sample<Position>(next) == Position{100, 1, 2} && !reader.render_at({1200000})->sample<Position>(id),
          "reuse switches handle and never interpolates across generations");
    check(world.apply(batch(17, {Replace<Position>{next, {112, 1, 2}}})).has_value(), "three-tick gap");
    check(reader.latest()->sample_time() == Time{1280000}, "gap advances timeline by three tick intervals");
    check(reader.render_at({1260000})->sample<Position>(next) == Position{106, 1, 2}, "gap interpolates between two explicit endpoints");
    check(frame->sample<Position>(id) == Position{2, 1, 2} && reused->sample<Position>(id) == Position{8, 1, 2}, "retained render frames survive many later publications");
    const auto pinned = reader.render_at({1260000});
    check(world.apply(batch(17, {})).error() == ApplyError::stale_tick, "failed tick cannot replace interpolation endpoints");
    check(reader.render_at({1260000})->sample<Position>(next) == pinned->sample<Position>(next), "failed apply preserves render values");

    auto short_delay = *World::create(Config{100, std::chrono::microseconds{40000}, std::chrono::microseconds{20000}});
    check(short_delay.apply(batch(10, {entry(id, 0)})).has_value(), "short-delay first sample");
    check(short_delay.apply(batch(11, {Replace<Position>{id, {4, 1, 2}}})).has_value(), "short-delay second sample");
    check(short_delay.reader().render_at({1040000})->sample<Position>(id) == Position{2, 1, 2}, "configurable 20ms jitter delay");
    check(!World::create(Config{0}) && World::create(Config{0}).error() == ConfigError::slot_limit, "zero slot limit refused");
    check(!World::create(Config{1, std::chrono::microseconds{30000}}), "tick faster than 30Hz refused");
    check(!World::create(Config{1, std::chrono::microseconds{50001}}), "tick slower than 20Hz refused");
    check(!World::create(Config{1, std::chrono::microseconds{40000}, std::chrono::microseconds{-1}}), "negative delay refused");
    check(World::create(Config{1, std::chrono::microseconds{33334}}).has_value() && World::create(Config{1, std::chrono::microseconds{50000}}).has_value(),
          "tick interval endpoints accepted");

    auto optional = *Applier<OptionalCatalog, int>::create();
    check(optional.apply({{1}, {1000000}, {Enter<OptionalCatalog>{Npc{1, 1}, {std::nullopt, Health{5, 10, 0, 0}}}}, 1}).has_value(), "kind catalog permits explicitly nonrequired component");
    check(!optional.reader().render_at({1000000})->sample<Position>(Npc{1, 1}), "missing optional transform returns no sample");
    check(optional.apply({{2}, {1040000}, {Replace<Position>{Npc{1, 1}, {4, 1, 2}}}, 2}).has_value(), "optional transform replacement");
    check(!optional.reader().render_at({1060000})->sample<Position>(Npc{1, 1}), "missing previous transform does not invent interpolation");
    check(optional.reader().render_at({1080000})->sample<Position>(Npc{1, 1}) == Position{4, 1, 2}, "new optional transform switches at membership time");
    auto overflow = *World::create();
    auto high = batch(1, {entry(id, 0)});
    high.received_at = {std::numeric_limits<std::int64_t>::max() - 1};
    check(overflow.apply(std::move(high)).has_value(), "high time anchor accepted");
    auto before = overflow.reader().latest();
    check(overflow.apply(batch(2, {})).error() == ApplyError::time_overflow && overflow.reader().latest() == before, "timeline overflow rejected transactionally");
    check(short_delay.reader().render_at({std::numeric_limits<std::int64_t>::min()})->sample<Position>(id) == Position{0, 1, 2}, "extreme negative render time safely clamps");
    return marque::test::check_finish();
}
