#include "marque/recording/replay.hpp"

#include <bit>
#include <cmath>

#include "../transport/format.hpp"
#include "marque/transport/session_seal.hpp"

namespace marque::recording {
namespace {
class OfflineSeal final : public transport::Opener, public transport::Sealer {
public:
  std::size_t overhead() const override { return transport::kSessionOverhead; }
  bool open(std::span<const std::uint8_t>, std::span<const std::uint8_t>,
            std::vector<std::uint8_t> &) override {
    return false;
  }
  void seal(std::span<const std::uint8_t>, std::span<const std::uint8_t> body,
            std::vector<std::uint8_t> &out) override {
    out.insert(out.end(), body.begin(), body.end());
    out.resize(out.size() + overhead());
  }
};
std::expected<void, Error>
validate_packet(std::span<const std::uint8_t> bytes) {
  if (bytes.size() < transport::kHeaderSize ||
      bytes.size() > transport::kMaxDatagram - transport::kSessionOverhead)
    return std::unexpected(Error::packet);
  const auto header = transport::format::read_header(bytes);
  if (header.protocol != transport::kProtocolId ||
      header.hash != wire::schema_hash)
    return std::unexpected(Error::packet);
  return {};
}
}
std::expected<Replay, Error> Replay::load(const std::filesystem::path &path) {
  auto file = read(path, wire::schema_hash);
  if (!file)
    return std::unexpected(file.error());
  if (file->mode != Mode::client_receive)
    return std::unexpected(Error::phase);
  wire::codec::Reader begin(file->records.front().payload);
  transport::Config config = transport::default_config(wire::schema_hash);
  config.tick_budget = begin.u64();
  config.backlog_limit = begin.u64();
  config.backlog_bytes = begin.u64();
  config.resend_after = begin.u64();
  client::RuntimeLimits limits{begin.u64(), begin.u64()};
  if (!config.validate() || config.tick_budget > 1024 * 1024 ||
      config.backlog_bytes > max_bytes || !limits.publications ||
      limits.publications > 4096 || !limits.publication_bytes ||
      limits.publication_bytes > 128 * 1024 * 1024)
    return std::unexpected(Error::config);
  const auto count = begin.u32();
  if (count > 64)
    return std::unexpected(Error::config);
  std::vector<motion::PredictionMap> maps;
  for (std::uint32_t i = 0; i < count; ++i) {
    const auto length = begin.u32();
    if (length == 0 || length > 64 || length > begin.remaining())
      return std::unexpected(Error::config);
    std::string id;
    for (std::uint32_t j = 0; j < length; ++j)
      id.push_back(begin.u8());
    const auto revision = begin.u32();
    const auto half = std::bit_cast<double>(begin.u64()),
               ground = std::bit_cast<double>(begin.u64());
    if (!revision || !wire::codec::valid_utf8(id) || !std::isfinite(half) ||
        half <= 0 || half > 4096 || !std::isfinite(ground))
      return std::unexpected(Error::config);
    const auto vertices_count = begin.u32();
    if (vertices_count > 10000 || vertices_count > begin.remaining() / 24)
      return std::unexpected(Error::config);
    std::vector<motion::Vec3> vertices;
    for (std::uint32_t j = 0; j < vertices_count; ++j)
      vertices.push_back({std::bit_cast<double>(begin.u64()),
                          std::bit_cast<double>(begin.u64()),
                          std::bit_cast<double>(begin.u64())});
    const auto triangles_count = begin.u32();
    if (triangles_count > 20000 || triangles_count > begin.remaining() / 12)
      return std::unexpected(Error::config);
    std::vector<std::array<std::uint32_t, 3>> triangles;
    for (std::uint32_t j = 0; j < triangles_count; ++j)
      triangles.push_back({begin.u32(), begin.u32(), begin.u32()});
    std::shared_ptr<const motion::Mesh> mesh;
    if (vertices_count || triangles_count) {
      auto value =
          motion::Mesh::create(std::move(vertices), std::move(triangles));
      if (!value)
        return std::unexpected(Error::config);
      mesh = *value;
    }
    if (std::any_of(maps.begin(), maps.end(),
                    [&](const auto &map) { return map.id == id; }))
      return std::unexpected(Error::config);
    maps.push_back({{half, ground, std::move(mesh)}, std::move(id), revision});
  }
  if (begin.finish())
    return std::unexpected(Error::config);
  std::uint64_t turn_time = file->origin;
  for (const auto &record : file->records) {
    if (record.kind == Kind::authenticated) {
      if (auto ok = validate_packet(record.payload); !ok)
        return std::unexpected(ok.error());
    } else if (record.kind == Kind::command) {
      if (record.payload.empty() ||
          record.payload.size() > transport::kMaxMessage)
        return std::unexpected(Error::command);
      auto value = wire::decode_intents(record.payload);
      if (!value || std::holds_alternative<wire::ApplicationCommit>(*value))
        return std::unexpected(Error::command);
    } else if (record.kind == Kind::input) {
      if (record.payload.size() != 17)
        return std::unexpected(Error::length);
      wire::codec::Reader r(record.payload);
      const auto dx = std::bit_cast<double>(r.u64()),
                 dz = std::bit_cast<double>(r.u64());
      const auto jump = r.boolean();
      if (r.finish() || !wire::Input::build({dx, dz, jump, 1}))
        return std::unexpected(Error::config);
    } else if (record.kind == Kind::turn) {
      if (!record.payload.empty())
        return std::unexpected(Error::length);
      if (record.time < turn_time)
        return std::unexpected(Error::time);
      turn_time = record.time;
    } else if (record.kind == Kind::drain) {
      if (record.payload.size() != 5)
        return std::unexpected(Error::length);
      wire::codec::Reader r(record.payload);
      const bool present = r.boolean();
      const auto tick = r.u32();
      if (r.finish() || (!present && tick != 0))
        return std::unexpected(Error::phase);
    }
  }
  return Replay(std::move(*file), config, limits, std::move(maps));
}
std::expected<ReplayResult, Error> Replay::run(
    const std::function<void(const client::Publication &)> &observer) const {
  auto seal = std::make_shared<OfflineSeal>();
  client::Session session(seal, seal, maps_, limits_, file_.origin, config_);
  ReplayResult result{0, client::LocalError::none, {}, nullptr, nullptr};
  session.observe([&](const auto &publication) {
    ++result.publications;
    if (observer)
      observer(publication);
  });
  for (const auto &record : file_.records) {
    if (session.domain_error() == client::DomainError::cursor &&
        file_.records.back().payload[0] !=
            static_cast<std::uint8_t>(client::LocalError::decode))
      return std::unexpected(Error::cursor);
    if (session.error() != client::LocalError::none &&
        record.kind != Kind::drain && record.kind != Kind::end)
      return std::unexpected(Error::phase);
    switch (record.kind) {
    case Kind::begin:
      break;
    case Kind::authenticated:
      (void)session.receive_packet(record.payload, record.time, true);
      break;
    case Kind::command:
      (void)session.admit(record.payload, record.time);
      break;
    case Kind::input: {
      wire::codec::Reader r(record.payload);
      const auto dx = std::bit_cast<double>(r.u64()),
                 dz = std::bit_cast<double>(r.u64());
      const auto jump = r.boolean();
      (void)session.sample({dx, dz, jump}, record.time);
      break;
    }
    case Kind::turn:
      (void)session.turn(record.time);
      break;
    case Kind::drain: {
      wire::codec::Reader r(record.payload);
      const bool present = r.boolean();
      const auto tick = r.u32();
      auto publication = session.take(record.time);
      if (bool(publication) != present ||
          (publication && publication->current->tick().value != tick))
        return std::unexpected(Error::mismatch);
      break;
    }
    case Kind::end:
      if (static_cast<std::uint8_t>(session.error()) != record.payload[0])
        return std::unexpected(session.domain_error() ==
                                       client::DomainError::cursor
                                   ? Error::cursor
                                   : Error::mismatch);
      break;
    case Kind::outbound:
      return std::unexpected(Error::phase);
    }
  }
  result.terminal = session.error();
  result.stats = session.stats();
  result.latest = session.latest();
  result.prediction = session.prediction();
  return result;
}
}
