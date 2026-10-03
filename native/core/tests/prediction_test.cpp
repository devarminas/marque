#include "check.hpp"
#include "marque/motion/prediction.hpp"
#include "world_fixture/types.hpp"

#include <cmath>
#include <cstdlib>
#include <limits>

using marque::test::check;
template <class T>
void required(std::expected<T, marque::motion::PredictionError> value) {
    if (!value) {
        check(false, "fixture prediction operation refused");
        std::abort();
    }
}
namespace mo = marque::motion;
namespace w = marque::wire;

w::OwnerMotionFields fields(std::uint32_t tick = 0, std::uint32_t cursor = 0) {
    w::OwnerMotionFields f;
    f.stream = 7;
    f.epoch = 2;
    f.player = {1, 1};
    f.tick = tick;
    f.input_seq = cursor;
    f.grounded = true;
    f.mode = w::MotionMode::free;
    f.map_id = "fixture";
    f.map_revision = 1;
    f.half_extent = 128;
    f.tick_interval_us = 40000;
    return f;
}
mo::PublishedBaseline baseline(w::OwnerMotionFields f) {
    return *mo::PublishedBaseline::complete(*w::OwnerMotion::build(f), f.tick);
}
mo::Prediction prediction(w::OwnerMotionFields f = fields()) {
    return *mo::Prediction::create(baseline(f), {{}, "fixture", 1}, 0);
}

int main() {
    auto p = prediction();
    const auto pinned = p.pose();
    auto remote = *world_fixture::World::create();
    check(remote
              .apply(world_fixture::batch(
                  1, {world_fixture::entry(world_fixture::Player{1, 1}, 11),
                      world_fixture::entry(world_fixture::Player{2, 1}, 22)}))
              .has_value(),
          "authoritative local and remote fixture publication");
    const auto server_snapshot = remote.reader().latest();
    check(p.sample({1, 0, false}).has_value(),
          "valid wish samples without network roundtrip");
    check(p.advance(400000) == 10, "ten canonical tick slots integrate");
    check(std::abs(p.pose()->state.x - 1.2) < 1e-9,
          "held local wish advances ten actual kernel ticks");
    check(pinned->state.x == 0 && server_snapshot == remote.reader().latest(),
          "pinned prediction and authoritative reader stay unchanged");
    auto repeat = p.inputs();
    check(repeat.size() == 8 && repeat.front().seq() == 10 &&
              repeat.back().seq() == 3,
          "eight newest first repeated sequence records");
    check(p.sample({0, 0, false}).has_value() && p.advance(440000) == 1,
          "fresh stop canonical slot");
    check(std::abs(p.pose()->state.x - 1.2) < 1e-9,
          "horizontal stop takes effect at next local tick");
    auto f = fields(10, 8);
    f.x = 1.2f;
    f.dx = 1;
    check(p.reconcile(baseline(f)) == 1,
          "older pending stop folds into first replay tick");
    check(std::abs(p.pose()->state.x - 1.2) < 1e-7,
          "old pending stop is not lost behind newer authoritative tick");
    auto good = fields(11, 11);
    good.x = 1.56f;
    check(p.reconcile(baseline(good)) == 0,
          "grounded authoritative stop publishes immediately");
    check(p.pose()->state.x == static_cast<double>(good.x),
          "server stop wins exactly at serialized position");
    const auto before = p.pose();
    check(!p.reconcile(baseline(good)), "duplicate tick rejected");
    f = fields(12, 12);
    check(!p.reconcile(baseline(f)), "future unsent cursor rejected");
    f = fields(12, 9);
    check(!p.reconcile(baseline(f)), "backwards input cursor rejected");
    f = fields(12, 11);
    f.player.gen = 2;
    check(!p.reconcile(baseline(f)), "wrong full handle generation rejected");
    f.player.gen = 1;
    f.epoch = 3;
    check(!p.reconcile(baseline(f)), "wrong lease rejected");
    f.epoch = 2;
    f.map_revision = 2;
    check(!p.reconcile(baseline(f)), "wrong immutable map revision rejected");
    check(p.pose() == before, "invalid baseline cannot mutate published pose");
    check(!p.advance(430000) && p.pose() == before,
          "backwards monotonic clock cannot mutate pose");
    check(!p.sample({2, 0, false}), "out of range caller wish rejected");
    auto airborne = prediction();
    required(airborne.sample({0, 0, true}));
    required(airborne.advance(40000));
    required(airborne.sample({0, 0, false}));
    required(airborne.advance(160000));
    check(std::abs(airborne.pose()->state.y - 0.48) < 1e-9 &&
              std::abs(airborne.pose()->state.vy - 1.8) < 1e-9,
          "airborne horizontal stop continues gravity");
    auto edge = airborne.inputs();
    int jumps = 0;
    for (const auto &i : edge)
        jumps += i.jump();
    check(jumps == 1 && edge.back().seq() == 1,
          "jump edge retains one original sequence across repeats");
    auto coalesced = prediction();
    for (int i = 0; i < 10000; ++i)
        required(coalesced.sample({i % 2 ? 1.0 : 0.0, 0, i == 0}));
    required(coalesced.advance(40000));
    check(coalesced.retained() == 1 && coalesced.inputs()[0].jump(),
          "arbitrary sampling coalesces into one bounded canonical edge");
    f = fields();
    f.mode = w::MotionMode::rooted;
    f.cast_end = 3;
    auto rooted = prediction(f);
    required(rooted.sample({1, 0, true}));
    required(rooted.advance(160000));
    check(std::abs(rooted.pose()->state.x - 0.12) < 1e-9 &&
              std::abs(rooted.pose()->state.y - 0.48) < 1e-9,
          "jump before rooted wish and fresh held wish resumes after root end");
    f = fields();
    f.mode = w::MotionMode::interrupt_on_move;
    f.cast_end = 20;
    auto interrupt = prediction(f);
    required(interrupt.sample({1, 0, false}));
    required(interrupt.advance(40000));
    check(std::abs(interrupt.pose()->state.x - 0.12) < 1e-9,
          "interrupt mode uses actual remaining cast grace");
    f = fields();
    f.dx = 1;
    auto approach = prediction(f);
    required(approach.advance(40000));
    check(std::abs(approach.pose()->state.x - .12) < 1e-9 &&
              approach.inputs().empty(),
          "passive tick integrates authoritative approach without invented "
          "input");
    required(approach.sample({0, 0, false}));
    required(approach.advance(80000));
    check(std::abs(approach.pose()->state.x - .12) < 1e-9 &&
              approach.inputs().front().seq() == 1,
          "explicit zero stops approach even without prior local held wish");
    required(approach.advance(120000));
    required(approach.advance(160000));
    check(approach.inputs().size() == 1 && approach.inputs().front().seq() == 1,
          "unconsumed deliberate stop repeats original sequence without fresh "
          "zeros");
    f = fields(4, 1);
    f.x = .12f;
    required(approach.reconcile(baseline(f)));
    f = fields(5, 1);
    f.x = .24f;
    f.dx = 1;
    required(approach.reconcile(baseline(f)));
    required(approach.advance(200000));
    check(approach.inputs().empty() &&
              std::abs(approach.pose()->state.x -
                       (static_cast<double>(f.x) + .12)) < 1e-9,
          "consumed stop becomes passive and later approach progresses");
    auto server_approach = prediction();
    f = fields(10);
    f.x = 1.2f;
    f.dx = 1;
    required(server_approach.reconcile(baseline(f)));
    check(server_approach.pose()->state.dx == 1 &&
              server_approach.pose()->state.x == static_cast<double>(f.x),
          "full authoritative approach wish applies without inferred input "
          "cursor");
    auto ramp_mesh =
        *mo::Mesh::create({{-2, -1, -2}, {2, 1, -2}, {2, 1, 2}, {-2, -1, 2}},
                          {{0, 1, 2}, {0, 2, 3}});
    f = fields();
    f.x = 1.2f;
    f.y = .6f;
    auto ramp_prediction = *mo::Prediction::create(
        baseline(f), {{128, 0, ramp_mesh}, "fixture", 1}, 0);
    required(ramp_prediction.sample({0, 0, true}));
    required(ramp_prediction.advance(40000));
    check(std::abs(ramp_prediction.pose()->state.y -
                   (static_cast<double>(f.x) * .5 + .168)) < 1e-9 &&
              std::abs(ramp_prediction.pose()->state.vy - 4.2) < 1e-9,
          "serialized grounded ramp restores collision height before jump");
    auto exhausted = prediction();
    required(exhausted.sample({1, 0, true}));
    required(exhausted.advance(10240000));
    required(exhausted.advance(10280000));
    check(exhausted.pose()->mode == mo::PredictionMode::awaiting_baseline &&
              exhausted.pose()->state.x == 0,
          "history exhaustion adopts latest complete authoritative pose");
    check(exhausted.recovery_sequence() == 257 && !exhausted.inputs()[0].jump(),
          "bounded recovery emits fresh wish with no old jump");
    f = fields(258, 256);
    f.x = 2;
    required(exhausted.reconcile(baseline(f)));
    check(exhausted.pose()->mode == mo::PredictionMode::awaiting_baseline &&
              exhausted.pose()->state.x == 2,
          "unacknowledged recovery remains stopped at fresh baseline");
    f = fields(259, 257);
    f.x = 3;
    required(exhausted.reconcile(baseline(f)));
    check(exhausted.pose()->mode == mo::PredictionMode::predicting &&
              exhausted.retained() == 0 && exhausted.pose()->state.x == 3,
          "matching recovery baseline resumes with obsolete history cleared");
    auto catchup = prediction();
    check(catchup.advance(40000ULL * 1000000) == 256 &&
              catchup.pose()->mode == mo::PredictionMode::awaiting_baseline &&
              catchup.retained() <= 8,
          "huge clock gap has bounded work and memory");
    auto clock_end = prediction();
    check(!clock_end.advance(std::numeric_limits<std::uint64_t>::max()) &&
              clock_end.pose()->mode == mo::PredictionMode::ended,
          "estimated tick exhaustion ends lease before clock catchup");
    f = fields(0, std::numeric_limits<std::uint32_t>::max() - 2);
    auto seq_end = prediction(f);
    required(seq_end.sample({1, 0, false}));
    required(seq_end.advance(40000));
    check(!seq_end.advance(80000) &&
              seq_end.pose()->mode == mo::PredictionMode::ended,
          "sequence exhaustion ends lease without wrapping");
    f = fields();
    f.dx = 1;
    auto passive_recovery = prediction(f);
    required(passive_recovery.advance(10280000));
    check(passive_recovery.pose()->mode ==
                  mo::PredictionMode::awaiting_baseline &&
              passive_recovery.inputs().empty() &&
              passive_recovery.recovery_sequence() == 0,
          "passive history exhaustion never sends server steering as input");
    f = fields(258);
    f.x = 2;
    f.dx = 1;
    required(passive_recovery.reconcile(baseline(f)));
    check(passive_recovery.pose()->mode == mo::PredictionMode::predicting &&
              passive_recovery.inputs().empty(),
          "new same lease complete baseline resumes passive recovery without "
          "cursor invention");
    required(passive_recovery.advance(10320000));
    check(std::abs(passive_recovery.pose()->state.x - 2.12) < 1e-9,
          "passive recovery resumes authoritative approach motion");
    f = fields(std::numeric_limits<std::uint32_t>::max() - 2);
    auto tick_end = prediction(f);
    required(tick_end.advance(40000));
    check(!tick_end.advance(80000) &&
              tick_end.pose()->mode == mo::PredictionMode::ended,
          "tick exhaustion uses same lease termination");
    f = fields();
    f.x = 129;
    check(!mo::PublishedBaseline::complete(*w::OwnerMotion::build(f), 0),
          "typed boundary rejects legal f32 outside map extent");
    f = fields();
    check(!mo::PublishedBaseline::complete(*w::OwnerMotion::build(f), 1),
          "baseline tick must belong to completed publication");
    check(!mo::Prediction::create(baseline(f), {{}, "fixture", 2}, 0),
          "initial collision data must match known map revision");
    check(server_snapshot == remote.reader().latest(),
          "all local sample advance reconcile paths preserve authoritative "
          "remote table");
    check(*remote.reader()
                      .latest()
                      ->world()
                      .table<world_fixture::Position>()
                      .find(world_fixture::Player{1, 1}) ==
                  world_fixture::Position{11, 1, 2} &&
              *remote.reader()
                      .latest()
                      ->world()
                      .table<world_fixture::Position>()
                      .find(world_fixture::Player{2, 1}) ==
                  world_fixture::Position{22, 1, 2},
          "populated authoritative local and remote poses remain literal "
          "unchanged values");
    return marque::test::check_finish();
}
