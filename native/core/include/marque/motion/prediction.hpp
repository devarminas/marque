#pragma once

#include "marque/motion/motion.hpp"
#include "marque/wire/gen/schema.hpp"

#include <array>
#include <string>

namespace marque::client {
class Session;
}

namespace marque::motion {

enum class PredictionError { baseline, identity, map, clock, input, ended };
enum class PredictionMode { predicting, awaiting_baseline, ended };
struct PredictedPose {
    State state;
    std::uint32_t tick;
    PredictionMode mode;
};
struct PredictionMap {
    Map collision;
    std::string id;
    std::uint32_t revision;
};
class PublishedBaseline {
    wire::OwnerMotion motion_;
    explicit PublishedBaseline(wire::OwnerMotion motion)
        : motion_(std::move(motion)) {}

  public:
    static std::expected<PublishedBaseline, PredictionError>
    complete(wire::OwnerMotion motion, std::uint32_t published_tick);
    const wire::OwnerMotion &motion() const { return motion_; }
};

class Prediction {
    struct Record {
        std::uint32_t seq, tick;
        Input input;
    };
    wire::PlayerId player_;
    std::uint64_t stream_, epoch_;
    std::string map_id_;
    std::uint32_t revision_, interval_, highest_, horizon_, baseline_tick_,
        baseline_cursor_;
    std::uint64_t anchor_time_, local_ticks_ = 0, last_time_;
    Map map_;
    State state_, baseline_state_;
    Policy policy_, baseline_policy_;
    std::optional<Input> wish_;
    std::uint32_t pending_stop_ = 0;
    std::array<Record, 256> records_{};
    std::size_t count_ = 0;
    std::uint32_t recovery_ = 0;
    PredictionMode mode_ = PredictionMode::predicting;
    std::shared_ptr<const PredictedPose> pose_;
    Prediction(const wire::OwnerMotion &m, Map map, std::uint64_t now);
    Prediction(const Prediction &) = default;
    std::expected<std::size_t, PredictionError> advance_checked(std::uint64_t now, bool retained);
    std::expected<void, PredictionError> validate_context(const PublishedBaseline &baseline) const;
    std::size_t reconcile_validated(const PublishedBaseline &baseline);
    friend class client::Session;
    std::expected<Prediction, PredictionError> prepare(const PublishedBaseline &baseline) const;
    std::expected<Prediction, PredictionError> prepare_reset(const PublishedBaseline &baseline,
        const wire::ResetCertificate &certificate, std::uint64_t epoch, std::uint64_t lease) const;
    void publish();
    void recover();
    void end();

  public:
    Prediction &operator=(const Prediction &) = delete;
    Prediction(Prediction &&) = default;
    Prediction &operator=(Prediction &&) = default;
    static std::expected<Prediction, PredictionError>
    create(const PublishedBaseline &initial, PredictionMap map,
           std::uint64_t now);
    std::expected<void, PredictionError> sample(Input input);
    std::expected<std::size_t, PredictionError> advance(std::uint64_t now);
    std::expected<std::size_t, PredictionError> advance_retained(std::uint64_t now);
    std::expected<void, PredictionError> validate(const PublishedBaseline &baseline) const;
    std::expected<void, PredictionError> validate_replacement(std::uint64_t stream, std::uint64_t epoch, wire::PlayerId player) const;
    std::expected<std::size_t, PredictionError>
    reconcile(const PublishedBaseline &baseline);
    std::vector<wire::Input> inputs() const;
    std::shared_ptr<const PredictedPose> pose() const { return pose_; }
    std::size_t retained() const { return count_; }
    std::uint32_t recovery_sequence() const { return recovery_; }
};

}
