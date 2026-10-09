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

std::expected<void, LocalError>
Session::replace_lease(const LeaseIdentity &identity, std::shared_ptr<transport::Opener> opener,
                       std::shared_ptr<transport::Sealer> sealer, std::uint64_t now, ResetLimits limits) {
  if (recording_ || !prediction_ || !latest() || now < operation_time_ ||
      now > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()))
    return std::unexpected(LocalError::recovery);
  if (!identity.stream || !identity.epoch || !identity.lease || !prediction_->validate_replacement(identity.stream, identity.epoch, identity.player) ||
      (lease_ && (identity.epoch <= lease_->epoch || identity.lease == lease_->lease)))
    return std::unexpected(LocalError::sequence);
  if (opener == opener_ || sealer == sealer_) return std::unexpected(LocalError::transport);
  auto made = transport::Endpoint::create(transport::Role::client, config_, opener, sealer, now);
  if (!made) return std::unexpected(LocalError::transport);
  if (auto valid = assembler_.replace_lease(identity.stream, identity.epoch, identity.lease,
          identity.player, {static_cast<std::int64_t>(now)}, limits); !valid)
    return std::unexpected(LocalError::recovery);
  endpoint_ = std::move(*made);
  opener_ = std::move(opener); sealer_ = std::move(sealer);
  lease_.emplace(identity); resend_next_ = journal_.empty() ? next_intent_ : journal_.front().seq;
  pending_control_.reset(); error_ = LocalError::none; domain_error_.reset(); operation_time_ = now;
  return {};
}

bool Session::send_control() {
  if (!pending_control_) return true;
  if (endpoint_->backlog()) return false;
  if (!endpoint_->send(*pending_control_) || endpoint_->state() != transport::State::open) {
    fail(LocalError::transport);
    return false;
  }
  pending_control_.reset();
  return true;
}

void Session::resend() {
  if (!lease_ || assembler_.phase() != DomainPhase::live || pending_control_ || endpoint_->backlog()) return;
  const auto command = std::find_if(journal_.begin(), journal_.end(), [&](const auto &value) { return value.seq >= resend_next_; });
  if (command == journal_.end()) { resend_next_ = next_intent_; return; }
  if (!endpoint_->send(command->bytes) || endpoint_->state() != transport::State::open) {
    fail(LocalError::transport);
    return;
  }
  resend_next_ = command->seq + 1;
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
  if (auto result = assembler_.receive(*packet, {static_cast<std::int64_t>(now)}); !result) {
    domain_error_ = result.error();
    fail(result.error() == DomainError::recovery_required || result.error() == DomainError::unavailable || result.error() == DomainError::deadline
             ? LocalError::recovery : result.error() == DomainError::capacity ? LocalError::capacity : LocalError::decode);
  }
  return {};
}

bool Session::admit(std::span<const std::uint8_t> bytes, std::uint64_t now) {
  record(recording::Kind::command, now, bytes);
  operation_time_ = std::max(operation_time_, now);
  if (error_ != LocalError::none || !endpoint_ || assembler_.phase() != DomainPhase::live || pending_control_ ||
      (lease_ && resend_next_ < next_intent_))
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
  if (!endpoint_->send(bytes) || endpoint_->state() != transport::State::open) {
    fail(LocalError::transport);
    return false;
  }
  journal_.push_back({next_intent_, {bytes.begin(), bytes.end()}});
  journal_bytes_ += bytes.size();
  ++next_intent_;
  if (lease_) resend_next_ = next_intent_;
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
  operation_time_ = std::max(operation_time_, now);
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
  operation_time_ = std::max(operation_time_, now);
  std::vector<std::vector<std::uint8_t>> outgoing;
  if (error_ != LocalError::none || !endpoint_) return outgoing;
  if (now > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
    fail(LocalError::sequence); return outgoing;
  }
  if (auto valid = assembler_.advance_reset({static_cast<std::int64_t>(now)}); !valid) {
    domain_error_ = valid.error(); fail(LocalError::recovery); return outgoing;
  }
  const bool due = now >= flush_;
  if (due && prediction_) {
    const auto advanced = assembler_.phase() == DomainPhase::reset_pending ? prediction_->advance_retained(now) : prediction_->advance(now);
    if (!advanced) { fail(LocalError::recovery); return outgoing; }
  }
  if (!pending_control_) pending_control_ = assembler_.take_reset_commit();
  send_control();
  if (error_ != LocalError::none) return outgoing;
  for (std::size_t count = 0; count < 64 && !pending_control_; ++count) {
    std::optional<motion::Prediction> prepared;
    const auto certificate = assembler_.pending_reset();
    const auto available = publications_.size() >= limits_.publications ? 0 : limits_.publication_bytes - publication_bytes_;
    auto value = assembler_.publish(available,
        [&](const Events &events, world::Tick tick) -> std::expected<void, DomainError> {
          if (const auto &value = events.motion; value) {
            auto baseline = motion::PublishedBaseline::complete(*value, tick.value);
            if (!baseline) return std::unexpected(DomainError::malformed);
            if (prediction_) {
              auto made = certificate && lease_ ? prediction_->prepare_reset(*baseline, *certificate, lease_->epoch, lease_->lease)
                                                : prediction_->prepare(*baseline);
              if (!made) return std::unexpected(DomainError::recovery_required);
              prepared = std::move(*made);
            } else {
              auto map = std::find_if(maps_.begin(), maps_.end(), [&](const auto &map) {
                return map.id == value->map_id() && map.revision == value->map_revision();
              });
              if (map != maps_.end()) {
                auto made = motion::Prediction::create(*baseline, *map, now);
                if (!made) return std::unexpected(DomainError::recovery_required);
                prepared = std::move(*made);
              }
            }
          }
          return {};
        });
    if (!value) {
      domain_error_ = value.error();
      fail(value.error() == DomainError::capacity ? LocalError::capacity
           : value.error() == DomainError::recovery_required || value.error() == DomainError::unavailable ? LocalError::recovery : LocalError::decode);
      return outgoing;
    }
    if (!*value) break;
    auto publication = std::move(**value);
    if (prepared) {
      prediction_ = std::move(prepared);
      interval_ = publication.current->events().motion->tick_interval_us();
    }
    const auto cursor = publication.current->events().next_intent;
    while (!journal_.empty() && journal_.front().seq < cursor) {
      journal_bytes_ -= journal_.front().bytes.size(); journal_.pop_front();
    }
    pending_control_ = publication.application_commit;
    publication_bytes_ += publication.retained_bytes;
    publications_.push_back(std::move(publication));
    if (observer_) observer_(publications_.back());
    send_control();
    if (error_ != LocalError::none) return outgoing;
  }
  resend();
  if (error_ != LocalError::none) return outgoing;
  if (due) {
    transport::Unreliable unreliable{};
    if (prediction_ && assembler_.phase() == DomainPhase::live) {
      for (const auto &input : prediction_->inputs()) {
        std::vector<std::uint8_t> bytes;
        if (!wire::encode(input, bytes)) { fail(LocalError::transport); return outgoing; }
        unreliable.stamp = std::max(unreliable.stamp, input.seq());
        unreliable.items.push_back(std::move(bytes));
      }
    }
    auto packets = endpoint_->flush(now, unreliable);
    if (!packets || packets->state != transport::State::open) { fail(LocalError::transport); return outgoing; }
    outgoing = std::move(packets->datagrams);
    flush_ = now + interval_;
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
