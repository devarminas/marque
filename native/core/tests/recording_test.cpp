#include "marque/recording/replay.hpp"
#include "marque/transport/session_seal.hpp"

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <unistd.h>

using namespace marque;
void require(bool value, const char *message) {
  if (!value) {
    std::cerr << message << '\n';
    std::exit(1);
  }
}
std::vector<std::uint8_t> data(const std::filesystem::path &path) {
  std::ifstream file(path, std::ios::binary);
  return {(std::istreambuf_iterator<char>(file)), {}};
}
std::vector<std::uint8_t> config() {
  std::vector<std::uint8_t> bytes;
  wire::codec::Writer w(bytes);
  w.u64(4800);
  w.u64(1024);
  w.u64(262144);
  w.u64(200000);
  w.u64(256);
  w.u64(128 * 1024 * 1024);
  w.u32(0);
  require(w.finish().has_value(), "literal config encoded");
  return bytes;
}
int main() {
  auto pattern =
      (std::filesystem::temp_directory_path() / "marque-recording-XXXXXX")
          .string();
  std::vector<char> name(pattern.begin(), pattern.end());
  name.push_back(0);
  require(mkdtemp(name.data()) != nullptr, "private recording directory");
  const std::filesystem::path directory(name.data());
  auto invalid_path = recording::Writer::create(
      directory / std::string(300, 'x'), recording::Mode::client_receive,
      wire::schema_hash, 100);
  require(!invalid_path && invalid_path.error() == recording::Error::io,
          "overlong path returns recording IO failure without throwing");
  const auto invalid_terminal_path = directory / "invalid-terminal.bin";
  auto invalid_terminal = recording::Writer::create(
      invalid_terminal_path, recording::Mode::client_receive,
      wire::schema_hash, 100);
  require(bool(invalid_terminal) &&
              (*invalid_terminal)->append(recording::Kind::begin, 100, config()),
          "invalid terminal fixture begins");
  require(!(*invalid_terminal)->finish(200, 255) &&
              (*invalid_terminal)->error() == recording::Error::footer &&
              !(*invalid_terminal)->finish(201, 0) &&
              !std::filesystem::exists(invalid_terminal_path),
          "invalid terminal latches failure and never publishes");
  bool retained_partial = false;
  for (const auto &entry : std::filesystem::directory_iterator(directory))
    retained_partial |= entry.path().filename().string().starts_with(
        "invalid-terminal.bin.partial.");
  require(retained_partial, "invalid terminal preserves owned partial");
  const auto target = directory / "record.bin";
  auto writer = recording::Writer::create(
      target, recording::Mode::client_receive, wire::schema_hash, 100);
  require(bool(writer), "new file writer");
  require((*writer)->append(recording::Kind::begin, 100, config()),
          "typed begin written");
  require((*writer)->append(recording::Kind::turn, 200, {}),
          "record original core time");
  std::vector<std::uint8_t> empty_drain = {0, 0, 0, 0, 0};
  require((*writer)->append(recording::Kind::drain, 300, empty_drain),
          "drain serialized later");
  require((*writer)->append(recording::Kind::turn, 250, {}),
          "worker core time retained behind consumer envelope");
  require((*writer)->finish(301, 0), "checked finalization");
  auto replay = recording::Replay::load(target);
  require(bool(replay), "validated complete trace");
  auto result = replay->run();
  require(bool(result) && result->publications == 0 &&
              result->terminal == client::LocalError::none,
          "cold trace never manufactures publication");
  auto file = recording::read(target, wire::schema_hash);
  require(file && file->records.size() == 5 && file->records[3].time == 250,
          "original core time round trips");
  auto existing = recording::Writer::create(
      target, recording::Mode::client_receive, wire::schema_hash, 100);
  require(!existing && existing.error() == recording::Error::exists,
          "existing final file untouched");
  const auto partial = directory / "owned.partial.bin";
  auto partial_writer = recording::Writer::create(
      partial, recording::Mode::client_receive, wire::schema_hash, 100);
  require(!partial_writer, "reserved partial destination refused");
  std::filesystem::copy_file(target, partial);
  require(!recording::read(partial, wire::schema_hash),
          "valid footer in failed partial remains refused");
  auto failed = recording::Writer::create(directory / "failed.bin",
                                          recording::Mode::client_receive,
                                          wire::schema_hash, 100);
  require(bool(failed) &&
              (*failed)->append(recording::Kind::begin, 100, config()),
          "failed capture begins");
  require(!(*failed)->append(recording::Kind::turn, 99, {}),
          "pre-origin capture refused");
  require((*failed)->error() == recording::Error::time &&
              !(*failed)->finish(200, 0) &&
              !std::filesystem::exists(directory / "failed.bin"),
          "failed capture cannot finalize");
  auto end = recording::Writer::create(directory / "end.bin",
                                       recording::Mode::client_receive,
                                       wire::schema_hash, 100);
  require(bool(end) && (*end)->append(recording::Kind::begin, 100, config()),
          "explicit end capture begins");
  require(!(*end)->append(recording::Kind::end, 200, {}) &&
              !(*end)->finish(201, 0),
          "caller cannot author completion footer");
  auto seals = transport::session_seal(transport::Role::client, {});
  client::Session session(std::move(seals.opener), std::move(seals.sealer), {},
                          {}, 100);
  require(session.record_to(directory / "session.bin", 100),
          "session trace admitted cold");
  require(!session.record_to(directory / "second.bin", 100),
          "second writer cannot take capture ownership");
  auto applier = world::Applier<client::Catalog, client::Events>::create();
  require(bool(applier), "canonical world created");
  client::Events events{
      std::make_shared<const client::OwnerState>(), {}, {}, 88, 1, 0, 1, {}};
  require(applier
              ->apply({world::Tick{1},
                       world::Time{40000},
                       {world::Leave{world::Item{7, 1}}},
                       events})
              .has_value(),
          "invisible generation fence applied");
  auto one = applier->reader().latest();
  require(one->world().entities().empty() &&
              one->world().remembered(world::Item{7, 99}) ==
                  world::Entity{world::Item{7, 1}},
          "actual hidden fence retained");
  auto other = world::Applier<client::Catalog, client::Events>::create();
  require(other
              ->apply({world::Tick{1},
                       world::Time{40000},
                       {world::Leave{world::Item{7, 2}}},
                       events})
              .has_value(),
          "second hidden generation fence applied");
  client::Publication a{nullptr, one, {}, 0},
      b{nullptr, other->reader().latest(), {}, 0};
  require(recording::canonical(a) != recording::canonical(b),
          "canonical comparison includes invisible remembered generation");
  std::filesystem::remove_all(directory);
  std::cout << "ARM361_NATIVE_RECORDING_BOUNDARIES_PASS\n";
  return 0;
}
