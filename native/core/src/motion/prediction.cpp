#include "marque/motion/prediction.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace marque::motion {
namespace {
bool valid(const wire::OwnerMotion &m) {
    const float values[]{m.x(),  m.y(),  m.z(),           m.vy(),
                         m.dx(), m.dz(), m.half_extent(), m.ground_y()};
    for (auto v : values)
        if (!std::isfinite(v))
            return false;
    return m.stream() != 0 && m.epoch() != 0 && m.player().index != 0 &&
           m.player().gen != 0 && !m.map_id().empty() && m.half_extent() > 0 &&
           m.half_extent() <= 4096 && std::abs(m.x()) <= m.half_extent() &&
           std::abs(m.z()) <= m.half_extent() && std::abs(m.y()) <= 4096 &&
           std::abs(m.vy()) <= 4096 && std::abs(m.ground_y()) <= 4096 &&
           std::hypot(static_cast<double>(m.dx()),
                      static_cast<double>(m.dz())) <= 1.0000002 &&
           (m.cast_end() == 0 || m.cast_end() >= m.tick()) &&
           (m.mode() == wire::MotionMode::free || m.cast_end() > m.tick());
}
State restore(const wire::OwnerMotion &m, const Map &map) {
    State state{m.x(), m.y(), m.z(), m.vy(), m.dx(), m.dz()};
    if (m.grounded()) {
        state.y = map.ground(state.x, state.z, state.y);
        state.vy = 0;
    }
    return state;
}
Policy policy(const wire::OwnerMotion &m) {
    return {static_cast<Mode>(static_cast<unsigned>(m.mode()) - 1),
            m.cast_end()};
}
}

std::expected<PublishedBaseline, PredictionError>
PublishedBaseline::complete(wire::OwnerMotion m, std::uint32_t tick) {
    if (m.tick() != tick || !valid(m))
        return std::unexpected(PredictionError::baseline);
    return PublishedBaseline(std::move(m));
}
Prediction::Prediction(const wire::OwnerMotion &m, Map map, std::uint64_t now)
    : player_(m.player()), stream_(m.stream()), epoch_(m.epoch()),
      map_id_(m.map_id()), revision_(m.map_revision()),
      interval_(m.tick_interval_us()), highest_(m.input_seq()),
      horizon_(m.tick()), baseline_tick_(m.tick()),
      baseline_cursor_(m.input_seq()), anchor_time_(now), last_time_(now),
      map_(std::move(map)), state_(restore(m, map_)), baseline_state_(state_),
      policy_(policy(m)), baseline_policy_(policy_) {
    publish();
}
std::expected<Prediction, PredictionError>
Prediction::create(const PublishedBaseline &initial, PredictionMap provided,
                   std::uint64_t now) {
    const auto &m = initial.motion();
    const auto &map = provided.collision;
    if (provided.id != m.map_id() || provided.revision != m.map_revision())
        return std::unexpected(PredictionError::map);
    if (!std::isfinite(map.half_extent) || !std::isfinite(map.ground_y) ||
        static_cast<float>(map.half_extent) != m.half_extent() ||
        static_cast<float>(map.ground_y) != m.ground_y())
        return std::unexpected(PredictionError::map);
    return Prediction(m, std::move(provided.collision), now);
}
void Prediction::publish() {
    pose_ = std::make_shared<const PredictedPose>(
        PredictedPose{state_, horizon_, mode_});
}
void Prediction::end() {
    mode_ = PredictionMode::ended;
    publish();
}
void Prediction::recover() {
    mode_ = PredictionMode::awaiting_baseline;
    state_ = baseline_state_;
    policy_ = baseline_policy_;
    count_ = 0;
    if (wish_)
        wish_->jump = false;
    pending_stop_ = 0;
    recovery_ = 0;
}
std::expected<void, PredictionError> Prediction::sample(Input input) {
    if (mode_ == PredictionMode::ended)
        return std::unexpected(PredictionError::ended);
    if (!std::isfinite(input.dx) || !std::isfinite(input.dz) ||
        std::abs(input.dx) > 1 || std::abs(input.dz) > 1)
        return std::unexpected(PredictionError::input);
    wish_ = Input{std::round(input.dx * 100) / 100,
                  std::round(input.dz * 100) / 100,
                  mode_ == PredictionMode::predicting &&
                      ((wish_ && wish_->jump) || input.jump)};
    pending_stop_ = 0;
    return {};
}
std::expected<std::size_t, PredictionError>
Prediction::advance(std::uint64_t now) {
    if (mode_ == PredictionMode::ended)
        return std::unexpected(PredictionError::ended);
    if (now < last_time_)
        return std::unexpected(PredictionError::clock);
    const auto ticks = (now - anchor_time_) / interval_;
    const auto elapsed = ticks - local_ticks_;
    if (elapsed >=
        static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max()) -
            horizon_) {
        end();
        return std::unexpected(PredictionError::ended);
    }
    if (elapsed > 256)
        recover();
    const auto steps = std::min<std::uint64_t>(elapsed, 256);
    for (std::uint64_t i = 0; i < steps; ++i) {
        if (horizon_ >= std::numeric_limits<std::uint32_t>::max() - 1) {
            end();
            return std::unexpected(PredictionError::ended);
        }
        if (mode_ == PredictionMode::predicting &&
            (count_ == records_.size() || horizon_ - baseline_tick_ >= 256))
            recover();
        ++horizon_;
        const bool fresh =
            wish_ && ((wish_->dx != 0 || wish_->dz != 0) || pending_stop_ == 0);
        if (fresh &&
            highest_ >= std::numeric_limits<std::uint32_t>::max() - 1) {
            end();
            return std::unexpected(PredictionError::ended);
        }
        if (mode_ == PredictionMode::awaiting_baseline) {
            if (fresh && count_ == 8) {
                std::move(records_.begin() + 1, records_.begin() + count_,
                          records_.begin());
                --count_;
            }
        }
        if (mode_ == PredictionMode::predicting) {
            for (std::size_t j = 0; j < count_; ++j)
                if (records_[j].tick == horizon_) {
                    auto a = apply(state_, map_, policy_, records_[j].input,
                                   horizon_ - 1);
                    state_ = a.state;
                    policy_ = a.policy;
                }
        }
        if (fresh) {
            ++highest_;
            const Record record{highest_, horizon_, *wish_};
            if (mode_ == PredictionMode::predicting) {
                auto a =
                    apply(state_, map_, policy_, record.input, horizon_ - 1);
                state_ = a.state;
                policy_ = a.policy;
            } else if (recovery_ == 0)
                recovery_ = highest_;
            records_[count_++] = record;
            if (wish_->dx == 0 && wish_->dz == 0)
                pending_stop_ = highest_;
            wish_->jump = false;
        }
        if (mode_ == PredictionMode::predicting)
            state_ = step(state_, map_, static_cast<double>(interval_) / 1e6);
    }
    local_ticks_ = ticks;
    last_time_ = now;
    publish();
    return steps;
}
std::expected<std::size_t, PredictionError>
Prediction::reconcile(const PublishedBaseline &published) {
    const auto &m = published.motion();
    if (mode_ == PredictionMode::ended)
        return std::unexpected(PredictionError::ended);
    if (m.player() != player_ || m.stream() != stream_ || m.epoch() != epoch_)
        return std::unexpected(PredictionError::identity);
    if (m.map_id() != map_id_ || m.map_revision() != revision_ ||
        m.half_extent() != static_cast<float>(map_.half_extent) ||
        m.ground_y() != static_cast<float>(map_.ground_y) ||
        m.tick_interval_us() != interval_)
        return std::unexpected(PredictionError::map);
    if (m.tick() <= baseline_tick_ || m.input_seq() < baseline_cursor_ ||
        m.input_seq() > highest_)
        return std::unexpected(PredictionError::baseline);
    baseline_tick_ = m.tick();
    baseline_cursor_ = m.input_seq();
    baseline_state_ = restore(m, map_);
    baseline_policy_ = policy(m);
    state_ = baseline_state_;
    policy_ = baseline_policy_;
    if (pending_stop_ != 0 && m.input_seq() >= pending_stop_) {
        wish_.reset();
        pending_stop_ = 0;
    }
    if (mode_ == PredictionMode::awaiting_baseline) {
        if ((!wish_ && recovery_ == 0) ||
            (recovery_ != 0 && m.input_seq() >= recovery_)) {
            mode_ = PredictionMode::predicting;
            count_ = 0;
            recovery_ = 0;
        }
        horizon_ = std::max(horizon_, m.tick());
        publish();
        return 0;
    }
    std::size_t keep = 0;
    for (std::size_t i = 0; i < count_; ++i)
        if (records_[i].seq > m.input_seq()) {
            records_[keep] = records_[i];
            records_[keep].tick = std::max(records_[keep].tick, m.tick() + 1);
            ++keep;
        }
    count_ = keep;
    if (horizon_ > m.tick() && horizon_ - m.tick() > 256) {
        recover();
        publish();
        return 0;
    }
    const auto end_tick = std::max(horizon_, m.tick());
    std::size_t next = 0, replayed = 0;
    for (std::uint32_t tick = m.tick(); tick < end_tick; ++tick) {
        while (next < count_ && records_[next].tick <= tick + 1) {
            auto a = apply(state_, map_, policy_, records_[next].input, tick);
            state_ = a.state;
            policy_ = a.policy;
            ++next;
        }
        state_ = step(state_, map_, static_cast<double>(interval_) / 1e6);
        ++replayed;
    }
    horizon_ = end_tick;
    publish();
    return replayed;
}
std::vector<wire::Input> Prediction::inputs() const {
    std::vector<wire::Input> result;
    result.reserve(8);
    for (std::size_t i = count_; i > 0 && result.size() < 8; --i) {
        const auto &r = records_[i - 1];
        auto input =
            wire::Input::build({r.input.dx, r.input.dz, r.input.jump, r.seq});
        if (input)
            result.push_back(*input);
    }
    return result;
}

}
