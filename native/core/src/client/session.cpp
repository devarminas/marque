#include "marque/client/session.hpp"

#include <algorithm>
#include <bit>
#include <limits>

#include "../transport/format.hpp"

namespace marque::client {

std::expected<std::vector<std::uint8_t>, wire::codec::Error>
encode_action(Action action, std::uint32_t seq) {
  auto build_and_encode = []<class M>(auto fields)
      -> std::expected<std::vector<std::uint8_t>, wire::codec::Error> {
    auto value = M::build(std::move(fields));
    if (!value)
      return std::unexpected(value.error());
    std::vector<std::uint8_t> bytes;
    if (auto result = wire::encode(*value, bytes); !result)
      return std::unexpected(result.error());
    return bytes;
  };
  return std::visit(
      [&](auto fields)
          -> std::expected<std::vector<std::uint8_t>, wire::codec::Error> {
        using F = std::decay_t<decltype(fields)>;
        fields.seq = seq;
        if constexpr (std::is_same_v<F, wire::PickupFields>)
          return build_and_encode.template operator()<wire::Pickup>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::DropFields>)
          return build_and_encode.template operator()<wire::Drop>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::EquipFields>)
          return build_and_encode.template operator()<wire::Equip>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::UnequipFields>)
          return build_and_encode.template operator()<wire::Unequip>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::GatherFields>)
          return build_and_encode.template operator()<wire::Gather>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::UseSelfFields>)
          return build_and_encode.template operator()<wire::UseSelf>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::AttackPlayerFields>)
          return build_and_encode.template operator()<wire::AttackPlayer>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::RespawnFields>)
          return build_and_encode.template operator()<wire::Respawn>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::CastSelfFields>)
          return build_and_encode.template operator()<wire::CastSelf>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::TalkFields>)
          return build_and_encode.template operator()<wire::Talk>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::DialogOptionFields>)
          return build_and_encode.template operator()<wire::DialogOption>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::GiveFields>)
          return build_and_encode.template operator()<wire::Give>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::PartyInviteFields>)
          return build_and_encode.template operator()<wire::PartyInvite>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::PartyAcceptFields>)
          return build_and_encode.template operator()<wire::PartyAccept>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::PartyDeclineFields>)
          return build_and_encode.template operator()<wire::PartyDecline>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::PartyLeaveFields>)
          return build_and_encode.template operator()<wire::PartyLeave>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::PartyKickFields>)
          return build_and_encode.template operator()<wire::PartyKick>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::AdminFields>)
          return build_and_encode.template operator()<wire::Admin>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::UseStationFields>)
          return build_and_encode.template operator()<wire::UseStation>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::AttackNpcFields>)
          return build_and_encode.template operator()<wire::AttackNpc>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::CastPlayerFields>)
          return build_and_encode.template operator()<wire::CastPlayer>(
              std::move(fields));
        else if constexpr (std::is_same_v<F, wire::CastNpcFields>)
          return build_and_encode.template operator()<wire::CastNpc>(
              std::move(fields));
      },
      std::move(action));
}

std::expected<void, transport::Error>
Session::receive(std::span<const std::uint8_t> bytes, std::uint64_t now) {
  return receive_packet(bytes, now, false);
}

std::expected<void, transport::Error>
Session::receive_packet(std::span<const std::uint8_t> bytes, std::uint64_t now,
                        bool plaintext) {
  if (error_ != LocalError::none)
    return std::unexpected(transport::Error::closed);
  operation_time_ = now;
  std::expected<transport::Received, transport::Error> packet =
      std::unexpected(transport::Error::malformed);
  if (!endpoint_) {
    auto made = transport::Endpoint::create(
        transport::Role::client, config_, opener_, sealer_, now,
        [this](auto header, auto body) {
          std::vector<std::uint8_t> bytes(header.begin(), header.end());
          bytes.insert(bytes.end(), body.begin(), body.end());
          record(recording::Kind::authenticated, operation_time_, bytes);
        });
    if (!made) {
      fail(LocalError::transport);
      return std::unexpected(transport::Error::closed);
    }
    packet = plaintext
                 ? made->consume(bytes.first(transport::kHeaderSize),
                                 bytes.subspan(transport::kHeaderSize), now)
                 : made->receive(bytes, now);
    if (!packet)
      return std::unexpected(packet.error());
    endpoint_ = std::move(*made);
  } else
    packet =
        plaintext
            ? endpoint_->consume(bytes.first(transport::kHeaderSize),
                                 bytes.subspan(transport::kHeaderSize), now)
            : endpoint_->receive(bytes, now);
  if (!packet)
    return std::unexpected(packet.error());
  if (auto result =
          assembler_.receive(*packet, {static_cast<std::int64_t>(now)});
      !result)
    fail(result.error() == DomainError::recovery_required ? LocalError::recovery
                                                          : LocalError::decode);
  return {};
}

bool Session::admit(std::span<const std::uint8_t> bytes, std::uint64_t now) {
  record(recording::Kind::command, now, bytes);
  if (error_ != LocalError::none || !endpoint_)
    return false;
  if (next_intent_ == std::numeric_limits<std::uint32_t>::max()) {
    fail(LocalError::sequence);
    return false;
  }
  auto message = wire::decode_intents(bytes);
  if (!message) {
    fail(LocalError::decode);
    return false;
  }
  const bool valid = std::visit(
      [&](const auto &value) {
        using M = std::decay_t<decltype(value)>;
        if constexpr (std::is_same_v<M, wire::ApplicationCommit> || std::is_same_v<M, wire::ResetCommit>)
          return false;
        else
          return value.seq() == next_intent_;
      },
      *message);
  if (!valid) {
    fail(LocalError::sequence);
    return false;
  }
  if (journal_.size() >= 4096 ||
      bytes.size() > 4 * 1024 * 1024 - journal_bytes_) {
    fail(LocalError::capacity);
    return false;
  }
  if (!endpoint_->send(bytes)) {
    fail(LocalError::transport);
    return false;
  }
  journal_.push_back({next_intent_, {bytes.begin(), bytes.end()}});
  journal_bytes_ += bytes.size();
  ++next_intent_;
  assembler_.admitted_frontier(next_intent_);
  return true;
}

bool Session::sample(motion::Input input, std::uint64_t now) {
  std::vector<std::uint8_t> bytes;
  wire::codec::Writer w(bytes);
  w.u64(std::bit_cast<std::uint64_t>(input.dx));
  w.u64(std::bit_cast<std::uint64_t>(input.dz));
  w.boolean(input.jump);
  (void)w.finish();
  record(recording::Kind::input, now, bytes);
  if (error_ != LocalError::none || !prediction_)
    return false;
  if (!prediction_->sample(input)) {
    fail(LocalError::sequence);
    return false;
  }
  return true;
}

std::vector<std::vector<std::uint8_t>> Session::turn(std::uint64_t now) {
  record(recording::Kind::turn, now);
  std::vector<std::vector<std::uint8_t>> outgoing;
  if (error_ != LocalError::none || !endpoint_)
    return outgoing;
  if (now >= flush_) {
    transport::Unreliable unreliable{};
    if (prediction_) {
      if (!prediction_->advance(now)) {
        fail(LocalError::sequence);
        return outgoing;
      }
      for (const auto &input : prediction_->inputs()) {
        std::vector<std::uint8_t> bytes;
        if (!wire::encode(input, bytes)) {
          fail(LocalError::transport);
          return outgoing;
        }
        unreliable.stamp = std::max(unreliable.stamp, input.seq());
        unreliable.items.push_back(std::move(bytes));
      }
    }
    auto packets = endpoint_->flush(now, unreliable);
    if (!packets || packets->state != transport::State::open) {
      fail(LocalError::transport);
      return outgoing;
    }
    outgoing = std::move(packets->datagrams);
    flush_ = now + interval_;
  }
  for (std::size_t count = 0; count < 64; ++count) {
    if (publications_.size() >= limits_.publications) {
      fail(LocalError::capacity);
      return outgoing;
    }
    std::optional<motion::Prediction> initial;
    std::optional<motion::PublishedBaseline> baseline;
    auto value = assembler_.publish(
        limits_.publication_bytes - publication_bytes_,
        [&](const Events &events,
            world::Tick tick) -> std::expected<void, DomainError> {
          if (const auto &value = events.motion; value) {
            auto made = motion::PublishedBaseline::complete(*value, tick.value);
            if (!made)
              return std::unexpected(DomainError::malformed);
            baseline = *made;
            if (prediction_) {
              if (!prediction_->validate(*baseline))
                return std::unexpected(DomainError::recovery_required);
            } else {
              auto map = std::find_if(
                  maps_.begin(), maps_.end(), [&](const auto &map) {
                    return map.id == value->map_id() &&
                           map.revision == value->map_revision();
                  });
              if (map != maps_.end()) {
                auto predicted =
                    motion::Prediction::create(*baseline, *map, now);
                if (!predicted)
                  return std::unexpected(DomainError::recovery_required);
                initial = std::move(*predicted);
              }
            }
          }
          return {};
        });
    if (!value) {
      domain_error_=value.error();
      fail(value.error() == DomainError::capacity ? LocalError::capacity
           : value.error() == DomainError::recovery_required
               ? LocalError::recovery
               : LocalError::decode);
      return outgoing;
    }
    if (!*value)
      break;
    auto publication = std::move(**value);
    if (!endpoint_->send(publication.application_commit)) {
      fail(LocalError::transport);
      return outgoing;
    }
    if (baseline && prediction_ && !prediction_->reconcile(*baseline)) {
      fail(LocalError::recovery);
      return outgoing;
    }
    if (initial) {
      prediction_ = std::move(initial);
      interval_ = baseline->motion().tick_interval_us();
    }
    const auto cursor = publication.current->events().next_intent;
    while (!journal_.empty() && journal_.front().seq < cursor) {
      journal_bytes_ -= journal_.front().bytes.size();
      journal_.pop_front();
    }
    publication_bytes_ += publication.retained_bytes;
    publications_.push_back(std::move(publication));
    if (observer_)
      observer_(publications_.back());
  }
  return outgoing;
}

std::optional<Publication> Session::take(std::uint64_t now) {
  std::vector<std::uint8_t> bytes;
  wire::codec::Writer w(bytes);
  w.boolean(!publications_.empty());
  w.u32(publications_.empty() ? 0
                              : publications_.front().current->tick().value);
  (void)w.finish();
  record(recording::Kind::drain, now, bytes);
  if (publications_.empty())
    return std::nullopt;
  auto value = std::move(publications_.front());
  publications_.pop_front();
  publication_bytes_ -= value.retained_bytes;
  return value;
}

void Session::record(recording::Kind kind, std::uint64_t time,
                     std::span<const std::uint8_t> payload) {
  if (recording_ && !recording_->append(kind, time, payload))
    recording_error_ = recording_->error();
}

bool Session::record_to(const std::filesystem::path &path, std::uint64_t now) {
  if (recording_ || active() || error_ != LocalError::none)
    return false;
  auto writer = recording::Writer::create(path, recording::Mode::client_receive,
                                          wire::schema_hash, now);
  if (!writer) {
    recording_error_ = writer.error();
    return false;
  }
  recording_ = std::move(*writer);
  std::vector<std::uint8_t> bytes;
  wire::codec::Writer w(bytes);
  w.u64(config_.tick_budget);
  w.u64(config_.backlog_limit);
  w.u64(config_.backlog_bytes);
  w.u64(config_.resend_after);
  w.u64(limits_.publications);
  w.u64(limits_.publication_bytes);
  w.u32(maps_.size());
  for (const auto &map : maps_) {
    w.u32(map.id.size());
    for (auto c : map.id)
      w.u8(c);
    w.u32(map.revision);
    w.u64(std::bit_cast<std::uint64_t>(map.collision.half_extent));
    w.u64(std::bit_cast<std::uint64_t>(map.collision.ground_y));
    w.u32(map.collision.mesh ? map.collision.mesh->vertices().size() : 0);
    if (map.collision.mesh)
      for (auto vertex : map.collision.mesh->vertices()) {
        w.u64(std::bit_cast<std::uint64_t>(vertex.x));
        w.u64(std::bit_cast<std::uint64_t>(vertex.y));
        w.u64(std::bit_cast<std::uint64_t>(vertex.z));
      }
    w.u32(map.collision.mesh ? map.collision.mesh->triangles().size() : 0);
    if (map.collision.mesh)
      for (auto triangle : map.collision.mesh->triangles())
        for (auto index : triangle)
          w.u32(index);
  }
  if (!w.finish()) {
    recording_error_ = recording::Error::config;
    return false;
  }
  record(recording::Kind::begin, now, bytes);
  return !recording_error_;
}

bool Session::finish_recording(std::uint64_t now) {
  if (!recording_)
    return false;
  if (!recording_->finish(now, static_cast<std::uint8_t>(error_))) {
    recording_error_ = recording_->error();
    return false;
  }
  return true;
}

}
