#include "marque/recording/replay.hpp"
#include "marque/transport/session_seal.hpp"

#include <iostream>
#include <sstream>

using namespace marque;
namespace {
std::vector<std::uint8_t> unhex(const std::string &text) {
  std::vector<std::uint8_t> bytes;
  for (std::size_t i = 0; i < text.size(); i += 2)
    bytes.push_back(std::stoul(text.substr(i, 2), nullptr, 16));
  return bytes;
}
std::string hex(std::span<const std::uint8_t> bytes) {
  constexpr char digits[] = "0123456789abcdef";
  std::string out;
  for (auto b : bytes) {
    out += digits[b >> 4];
    out += digits[b & 15];
  }
  return out;
}
}
int main(int argc, char **argv) {
  if (argc == 3 &&
      (std::string(argv[1]) == "read" || std::string(argv[1]) == "container")) {
    auto file = recording::read(argv[2], wire::schema_hash);
    if (!file) {
      std::cout << "REFUSE " << recording::to_string(file.error()) << '\n';
      return 1;
    }
    if (std::string(argv[1]) == "container") {
      std::cout << "CONTAINER_PASS records=" << file->records.size()
                << " mode=" << int(file->mode) << '\n';
      return 0;
    }
    auto trace = recording::Replay::load(argv[2]);
    if (!trace) {
      std::cout << "REFUSE " << recording::to_string(trace.error()) << '\n';
      return 1;
    }
    auto result = trace->run();
    if (!result) {
      std::cout << "REFUSE " << recording::to_string(result.error()) << '\n';
      return 1;
    }
    std::cout << "REPLAY_PASS publications=" << result->publications
              << " terminal=" << int(result->terminal) << '\n';
    return 0;
  }
  if (argc != 3)
    return 2;
  const std::string mode = argv[2];
  auto seals = transport::session_seal(transport::Role::client, {});
  client::RuntimeLimits limits;
  if (mode == "capacity" || mode == "drain")
    limits.publications = 2;
  auto cfg = transport::default_config(wire::schema_hash);
  if (mode == "backlog")
    cfg.backlog_limit = 1024;
  client::Session session(std::move(seals.opener), std::move(seals.sealer),
                          {{{128, 0, {}}, "village", 2}}, limits, 0, cfg);
  if (!session.record_to(argv[1], 0))
    return 3;
  std::vector<std::vector<std::uint8_t>> observed;
  session.observe([&](const client::Publication &publication) {
    observed.push_back(recording::canonical(publication));
    const auto &tick = *publication.current;
    const auto &events = tick.events();
    auto remembered = tick.world().remembered(world::Item{7, 1});
    const auto entity = remembered.value_or(world::Item{7, 1});
    const auto *position = tick.world().table<wire::Transform>().find(entity);
    const auto *vitals = tick.world().table<wire::Vitals>().find(entity);
    std::uint32_t producing = 0;
    if (!events.changes.empty() &&
        std::holds_alternative<wire::Inventory>(events.changes.front()))
      producing = std::get<wire::Inventory>(events.changes.front()).tick();
    std::cout << "PUB " << tick.tick().value
              << " visible=" << tick.world().contains(entity)
              << " gen=" << world::generation(entity)
              << " x=" << (position ? position->x() : -1)
              << " hp=" << (vitals ? int(vitals->hp()) : -1)
              << " end=" << events.event_end << " cursor=" << events.next_intent
              << " producing=" << producing << " slots="
              << (events.owner->inventory
                      ? events.owner->inventory->slots().size()
                      : 0)
              << '\n';
  });
  std::string line;
  std::uint64_t last = 0;
  while (std::getline(std::cin, line)) {
    std::istringstream input(line);
    std::string operation;
    std::uint64_t now;
    input >> operation >> now;
    last = std::max(last, now);
    std::string disposition = "ok";
    if (operation == "recv") {
      std::string text;
      input >> text;
      auto bytes = unhex(text);
      auto value = session.receive(bytes, now);
      if (!value)
        disposition = transport::to_string(value.error());
    } else if (operation == "admit") {
      std::string text;
      input >> text;
      (void)session.admit(unhex(text), now);
    } else if (operation == "input") {
      double dx, dz;
      bool jump;
      input >> dx >> dz >> jump;
      (void)session.sample({dx, dz, jump}, now);
    } else if (operation == "turn") {
      for (const auto &bytes : session.turn(now))
        std::cout << "SEND " << hex(bytes) << '\n';
      if (auto pose = session.prediction())
        std::cout << "POSE tick=" << pose->tick << " x=" << pose->state.x
                  << " dx=" << pose->state.dx << " mode=" << int(pose->mode)
                  << '\n';
    } else if (operation == "take") {
      (void)session.take(now);
    } else
      return 4;
    std::cout << "OK " << disposition << " error=" << int(session.error())
              << " journal=" << session.journal_size() << '\n'
              << std::flush;
  }
  if (!session.finish_recording(last + 1))
    return 5;
  auto trace = recording::Replay::load(argv[1]);
  if (!trace) {
    std::cerr << recording::to_string(trace.error()) << '\n';
    return 6;
  }
  std::size_t compared = 0;
  bool equal = true;
  auto replay = trace->run([&](const client::Publication &publication) {
    if (compared >= observed.size() ||
        recording::canonical(publication) != observed[compared])
      equal = false;
    ++compared;
  });
  if (!replay) {
    std::cerr << recording::to_string(replay.error()) << '\n';
    return 7;
  }
  const auto live_pose = session.prediction();
  if (bool(live_pose) != bool(replay->prediction) ||
      (live_pose && (live_pose->state != replay->prediction->state ||
                     live_pose->tick != replay->prediction->tick ||
                     live_pose->mode != replay->prediction->mode)))
    return 9;
  const auto stats = session.stats();
  if (!equal || compared != observed.size() ||
      replay->publications != observed.size() ||
      replay->terminal != session.error() ||
      replay->stats.accepted != stats.accepted ||
      replay->stats.duplicate != stats.duplicate ||
      replay->stats.stale != stats.stale ||
      replay->stats.too_old != stats.too_old)
    return 8;
  std::cout << "REPLAY_PASS publications=" << observed.size()
            << " terminal=" << int(session.error())
            << " accepted=" << stats.accepted
            << " duplicate=" << stats.duplicate << " stale=" << stats.stale
            << '\n';
  return 0;
}
