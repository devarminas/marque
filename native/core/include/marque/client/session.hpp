#pragma once

#include "marque/client/domain.hpp"
#include "marque/motion/prediction.hpp"
#include "marque/recording/recording.hpp"
#include "marque/transport/endpoint.hpp"

namespace marque::recording {
class Replay;
}

namespace marque::client {

using Action = std::variant<
    wire::PickupFields, wire::DropFields, wire::EquipFields,
    wire::UnequipFields, wire::GatherFields, wire::UseSelfFields,
    wire::AttackPlayerFields, wire::RespawnFields, wire::CastSelfFields,
    wire::TalkFields, wire::DialogOptionFields, wire::GiveFields,
    wire::PartyInviteFields, wire::PartyAcceptFields, wire::PartyDeclineFields,
    wire::PartyLeaveFields, wire::PartyKickFields, wire::AdminFields,
    wire::UseStationFields, wire::AttackNpcFields, wire::CastPlayerFields,
    wire::CastNpcFields>;

std::expected<std::vector<std::uint8_t>, wire::codec::Error>
encode_action(Action action, std::uint32_t seq);

enum class Connection { disconnected, connecting, connected, failed };
enum class LocalError {
  none,
  token,
  socket,
  handshake,
  transport,
  decode,
  capacity,
  recovery,
  sequence
};

struct RuntimeLimits {
  std::size_t publications = 256;
  std::size_t publication_bytes = 128 * 1024 * 1024;
};

class Session {
  struct Canonical {
    std::uint32_t seq;
    std::vector<std::uint8_t> bytes;
  };
  std::shared_ptr<transport::Opener> opener_;
  std::shared_ptr<transport::Sealer> sealer_;
  std::optional<transport::Endpoint> endpoint_;
  Assembler assembler_ = Assembler::create();
  std::deque<Canonical> journal_;
  std::uint32_t next_intent_ = 1;
  std::optional<motion::Prediction> prediction_;
  const std::vector<motion::PredictionMap> maps_;
  const RuntimeLimits limits_;
  std::deque<Publication> publications_;
  std::size_t publication_bytes_ = 0;
  std::size_t journal_bytes_ = 0;
  std::uint32_t interval_ = 40000;
  std::uint64_t flush_;
  LocalError error_ = LocalError::none;
  std::optional<DomainError> domain_error_;
  const transport::Config config_;
  std::unique_ptr<recording::Writer> recording_;
  std::optional<recording::Error> recording_error_;
  std::uint64_t operation_time_ = 0;
  friend class recording::Replay;
  std::expected<void, transport::Error>
  receive_packet(std::span<const std::uint8_t> bytes, std::uint64_t now,
                 bool plaintext);
  void record(recording::Kind kind, std::uint64_t time,
              std::span<const std::uint8_t> payload = {});
  std::function<void(const Publication &)> observer_;
  void fail(LocalError error) {
    error_ = error;
    journal_.clear();
    journal_bytes_ = 0;
  }

public:
  Session(
      std::shared_ptr<transport::Opener> opener,
      std::shared_ptr<transport::Sealer> sealer,
      std::vector<motion::PredictionMap> maps, RuntimeLimits limits,
      std::uint64_t now,
      transport::Config config = transport::default_config(wire::schema_hash))
      : opener_(std::move(opener)), sealer_(std::move(sealer)),
        maps_(std::move(maps)), limits_(limits), flush_(now), config_(config) {}
  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;
  std::expected<void, transport::Error>
  receive(std::span<const std::uint8_t> bytes, std::uint64_t now);
  bool admit(std::span<const std::uint8_t> bytes, std::uint64_t now);
  bool sample(motion::Input input, std::uint64_t now);
  std::vector<std::vector<std::uint8_t>> turn(std::uint64_t now);
  std::optional<Publication> take(std::uint64_t now);
  bool record_to(const std::filesystem::path &path, std::uint64_t now);
  bool finish_recording(std::uint64_t now);
  std::optional<recording::Error> recording_error() const {
    return recording_error_;
  }
  void observe(std::function<void(const Publication &)> observer) {
    observer_ = std::move(observer);
  }
  transport::Stats stats() const {
    return endpoint_ ? endpoint_->stats() : transport::Stats{};
  }
  bool active() const { return endpoint_.has_value(); }
  LocalError error() const { return error_; }
  std::optional<DomainError> domain_error() const { return domain_error_; }
  std::uint32_t next_intent() const { return next_intent_; }
  bool flush_due(std::uint64_t now) const { return active() && now >= flush_; }
  std::size_t journal_bytes() const { return journal_bytes_; }
  std::size_t journal_size() const { return journal_.size(); }
  std::shared_ptr<const motion::PredictedPose> prediction() const {
    return prediction_ ? prediction_->pose() : nullptr;
  }
  std::shared_ptr<const Tick> latest() const { return assembler_.latest(); }
};

}
