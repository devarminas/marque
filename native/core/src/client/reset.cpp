#include "marque/client/domain.hpp"
#include "marque/motion/prediction.hpp"

#include <cmath>
#include <set>
#include <stdexcept>

namespace marque::client {
namespace {
std::size_t row_strings(const wire::EntitySnapshot& row) {
    std::size_t bytes=0;
    if (row.look()) bytes+=row.look()->kind().capacity()+1;
    if (row.cast() && row.cast()->casting()) bytes+=row.cast()->casting()->ability().capacity()+1;
    if (row.gear()) {
        const auto& gear=*row.gear();
        for (const auto* value:{&gear.helmet(),&gear.chest(),&gear.trousers(),&gear.feet(),&gear.left_hand(),&gear.right_hand()})
            if (*value) bytes+=(**value).capacity()+1;
    }
    return bytes;
}
std::expected<wire::Transform,DomainError> canonical_pose_bound(const wire::MotionBaseline& motion,bool upper) {
    const auto bound=[upper](float value) {
        const auto adjacent=std::nextafter(value,upper ? std::numeric_limits<float>::infinity() : -std::numeric_limits<float>::infinity());
        auto endpoint=(static_cast<double>(value)+static_cast<double>(adjacent))/2;
        if (static_cast<float>(endpoint)!=value) endpoint=std::nextafter(endpoint,static_cast<double>(value));
        return endpoint;
    };
    const auto transform=wire::Transform::build({bound(motion.x()),bound(motion.y()),bound(motion.z())});
    if (!transform) return std::unexpected(DomainError::world);
    const auto entity=wire::Entity::build({motion.player(),*transform,{},{},{},{}});
    std::vector<std::uint8_t> bytes;
    if (!entity || !wire::encode(*entity,bytes)) return std::unexpected(DomainError::world);
    const auto decoded=wire::decode_state(bytes);
    if (!decoded) return std::unexpected(DomainError::world);
    return *std::get<wire::Entity>(*decoded).transform();
}
wire::OwnerMotion owner_motion(const wire::MotionBaseline& value) {
    return *wire::OwnerMotion::build({value.stream(),value.epoch(),value.player(),value.tick(),value.input_seq(),
        value.x(),value.y(),value.z(),value.vy(),value.dx(),value.dz(),value.grounded(),value.mode(),value.cast_end(),
        value.map_id(),value.map_revision(),value.half_extent(),value.ground_y(),value.tick_interval_us()});
}
}

std::expected<void,DomainError> Assembler::replace_lease(std::uint64_t stream,std::uint64_t epoch,std::uint64_t lease,
        wire::PlayerId player,world::Time now,ResetLimits limits) {
    if (!stream || !epoch || !lease || !player.index || !player.gen || now.microseconds<0 ||
        (stream_ && stream!=stream_) || epoch<epoch_ || (lease_ && (lease==lease_ || epoch<=epoch_)))
        return std::unexpected(DomainError::identity);
    if (!limits.parts || limits.parts>1024 || !limits.entities || limits.entities>100000 ||
        !limits.encoded_bytes || !limits.decoded_bytes || limits.timeout_us<=0)
        throw std::invalid_argument("reset limits invalid");
    if (const auto prior=latest();prior && prior->events().motion && prior->events().motion->player()!=player)
        return std::unexpected(DomainError::identity);
    stream_=stream;epoch_=epoch;lease_=lease;player_=player;lease_started_=now;reset_limits_=limits;
    slices_.clear();boundaries_.clear();events_.clear();bytes_=0;received_=applied_;
    reset_=ResetStage{};reset_->received=now;phase_=DomainPhase::reset_pending;unavailable_.reset();
    committed_reset_.reset();reset_commit_.clear();reset_commit_pending_=false;
    return {};
}

std::expected<void,DomainError> Assembler::reset_unavailable(wire::ResetFailure reason,DomainError error) {
    phase_=DomainPhase::unavailable;unavailable_=reason;reset_.reset();
    slices_.clear();boundaries_.clear();events_.clear();bytes_=0;received_=applied_;
    return std::unexpected(error);
}

std::expected<void,DomainError> Assembler::advance_reset(world::Time now) {
    if (phase_!=DomainPhase::reset_pending) return {};
    if (now.microseconds<lease_started_.microseconds) return std::unexpected(DomainError::identity);
    if (now.microseconds-lease_started_.microseconds>reset_limits_.timeout_us)
        return reset_unavailable(wire::ResetFailure::deadline,DomainError::deadline);
    return {};
}

std::optional<std::vector<std::uint8_t>> Assembler::take_reset_commit() {
    if (!reset_commit_pending_) return {};
    reset_commit_pending_=false;
    return reset_commit_;
}

std::expected<void,DomainError> Assembler::receive_reset(const std::vector<wire::EventsMsg>& messages,world::Time now) {
    if (auto valid=advance_reset(now);!valid) return valid;
    if (now.microseconds<reset_->received.microseconds) return std::unexpected(DomainError::identity);
    auto next=*reset_;
    auto facts=events_;
    auto cursor=received_;
    auto fact_bytes=bytes_;
    for (const auto& message:messages) {
        auto valid=std::visit([&](const auto& value)->std::expected<void,DomainError> {
            using T=std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<T,wire::ResetUnavailable>) {
                if (value.stream()!=stream_ || value.epoch()!=epoch_ || value.lease()!=lease_) return std::unexpected(DomainError::identity);
                return reset_unavailable(value.reason(),DomainError::unavailable);
            } else if constexpr (std::is_same_v<T,wire::ResetBegin> || std::is_same_v<T,wire::ResetPart> || std::is_same_v<T,wire::ResetClose>) {
                const auto& cert=value.certificate();
                if (cert.stream()!=stream_ || cert.epoch()!=epoch_ || cert.lease()!=lease_ || cert.tick()<tick_)
                    return std::unexpected(DomainError::identity);
                if (cert.event_end()<applied_ || cert.next_intent()<next_intent_ || cert.next_intent()>frontier_)
                    return std::unexpected(DomainError::cursor);
                if constexpr (std::is_same_v<T,wire::ResetBegin>) {
                    if (value.motion().player()!=player_ || !motion::PublishedBaseline::complete(owner_motion(value.motion()),cert.tick()))
                        return std::unexpected(DomainError::world);
                    if (next.begin && *next.begin!=value) return std::unexpected(DomainError::sequence);
                    if (next.begin) return {};
                    if (cert.parts()>reset_limits_.parts || cert.entities()>reset_limits_.entities ||
                        (cert.entities()==0)!=(cert.parts()==0) || cert.entities()>std::size_t(cert.parts())*64)
                        return reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
                    next.begin=value;next.parts.resize(cert.parts());
                } else {
                    if (!next.begin || next.begin->certificate()!=cert) return std::unexpected(DomainError::identity);
                    if constexpr (std::is_same_v<T,wire::ResetPart>) {
                        if (value.entities().empty()) return std::unexpected(DomainError::state_count);
                        auto& part=next.parts[value.index()];
                        if (part && *part!=value) return std::unexpected(DomainError::sequence);
                        if (part) return {};
                        part=value;
                    } else {
                        if (next.closed) return {};
                        next.closed=true;
                    }
                }
                std::vector<std::uint8_t> bytes;
                if (!wire::encode(value,bytes)) return std::unexpected(DomainError::malformed);
                if (bytes.size()>reset_limits_.encoded_bytes || next.encoded_bytes>reset_limits_.encoded_bytes-bytes.size())
                    return reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
                next.encoded_bytes+=bytes.size();
                return {};
            } else if constexpr (std::is_constructible_v<OwnerEvent,T>) {
                if (value.stream()!=stream_ || !value.event_seq() || value.event_seq()==std::numeric_limits<std::uint64_t>::max())
                    return std::unexpected(DomainError::identity);
                if (value.event_seq()<=applied_) return {};
                const OwnerEvent fact{value};
                if (const auto it=facts.find(value.event_seq());it!=facts.end())
                    return it->second==fact ? std::expected<void,DomainError>{} : std::unexpected(DomainError::sequence);
                if (value.event_seq()!=cursor+1) return std::unexpected(DomainError::sequence);
                std::vector<std::uint8_t> bytes;
                if (!wire::encode(value,bytes)) return std::unexpected(DomainError::malformed);
                if (bytes.size()>limits_.staged_bytes || fact_bytes>limits_.staged_bytes-bytes.size() || facts.size()>=limits_.events)
                    return reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
                fact_bytes+=bytes.size();cursor=value.event_seq();facts.emplace(cursor,fact);
                return {};
            } else return std::unexpected(DomainError::recovery_required);
        },message);
        if (!valid) return valid;
    }
    std::size_t decoded=sizeof(ResetStage)+next.parts.capacity()*sizeof(std::optional<wire::ResetPart>);
    if (next.begin) decoded+=sizeof(wire::ResetBegin)+next.begin->motion().map_id().capacity()+1;
    std::size_t entities=0;
    std::set<std::uint64_t> slots;
    for (const auto& part:next.parts) if (part) {
        entities+=part->entities().size();
        decoded+=part->entities().capacity()*sizeof(wire::EntitySnapshot);
        for (const auto& row:part->entities()) {
            decoded+=row_strings(row);
            const auto id=entity(row.id());
            if (!std::visit([](auto value){return value.index!=0 && value.generation!=0;},id)) return std::unexpected(DomainError::identity);
            if (!slots.insert(world::slot_key(entity(row.id()))).second) return std::unexpected(DomainError::sequence);
        }
    }
    if (decoded>reset_limits_.decoded_bytes || entities>reset_limits_.entities || (next.begin && entities>next.begin->certificate().entities()))
        return reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
    next.received=now;reset_=std::move(next);events_=std::move(facts);received_=cursor;bytes_=fact_bytes;
    return {};
}

std::expected<std::optional<Publication>,DomainError> Assembler::publish_reset(std::size_t available,const ValidatePublication& validate) {
    if (!reset_->begin || !reset_->closed) return std::optional<Publication>{};
    const auto& begin=*reset_->begin;
    const auto& cert=begin.certificate();
    for (const auto& part:reset_->parts) if (!part) return std::optional<Publication>{};
    if (received_<cert.event_end()) return std::optional<Publication>{};
    const auto lower=canonical_pose_bound(begin.motion(),false);
    const auto upper=canonical_pose_bound(begin.motion(),true);
    if (!lower || !upper) return std::unexpected(DomainError::world);
    auto previous=latest();
    auto owner=std::make_shared<OwnerState>(previous ? *previous->events().owner : OwnerState{});
    Events output{owner,{},{},stream_,epoch_,cert.event_end(),cert.next_intent(),owner_motion(begin.motion())};
    for (auto seq=applied_+1;seq<=cert.event_end();++seq) {
        const auto it=events_.find(seq);
        if (it==events_.end()) return std::optional<Publication>{};
        if (std::visit([](const auto& value){return value.tick();},it->second)>cert.tick()) return std::unexpected(DomainError::sequence);
        owner->apply(it->second);output.changes.push_back(it->second);
    }
    if (owner->cooldowns.size()>limits_.cooldowns) {
        (void)reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
        return std::unexpected(DomainError::capacity);
    }
    std::vector<world::Change<Catalog>> changes;
    std::set<std::uint64_t> slots;
    bool found_player=false;
    std::size_t count=0;
    for (const auto& part:reset_->parts) for (const auto& row:part->entities()) {
        ++count;
        const auto id=entity(row.id());slots.insert(world::slot_key(id));
        if (previous) if (const auto prior=previous->world().remembered(id);prior && world::generation(id)<world::generation(*prior))
            return std::unexpected(DomainError::world);
        if (id==world::Entity{world::Player{player_.index,player_.gen}}) {
            const auto& pose=row.transform();
            if (pose.x()<lower->x() || pose.x()>upper->x() || pose.y()<lower->y() || pose.y()>upper->y() ||
                pose.z()<lower->z() || pose.z()>upper->z()) return std::unexpected(DomainError::world);
            found_player=true;
        }
        changes.emplace_back(world::Enter<Catalog>{id,{row.transform(),row.vitals(),row.gear(),row.cast(),row.look()}});
    }
    if (count!=cert.entities() || !found_player) return std::unexpected(DomainError::state_count);
    if (previous) for (const auto& id:previous->world().entities())
        if (!slots.contains(world::slot_key(id))) changes.emplace_back(world::Leave{id});
    const auto retained=1024*1024+((previous ? previous->world().known_slots() : 0)+count)*4096+2*(bytes_+reset_->encoded_bytes);
    if (retained>available) {
        (void)reset_unavailable(wire::ResetFailure::capacity,DomainError::capacity);
        return std::unexpected(DomainError::capacity);
    }
    const auto commit=wire::ResetCommit::build({cert});
    std::vector<std::uint8_t> encoded;
    if (!commit || !wire::encode(*commit,encoded)) return std::unexpected(DomainError::malformed);
    if (validate) if (auto result=validate(output,world::Tick{cert.tick()});!result) return std::unexpected(result.error());
    auto result=world_.apply_certified_reset({world::Tick{cert.tick()},reset_->received,std::move(changes),std::move(output)});
    if (!result) return std::unexpected(DomainError::world);
    applied_=cert.event_end();next_intent_=cert.next_intent();tick_=cert.tick();
    committed_reset_=cert;reset_commit_=encoded;reset_commit_pending_=false;
    reset_.reset();phase_=DomainPhase::live;events_.erase(events_.begin(),events_.upper_bound(applied_));
    bytes_=0;
    for (const auto& [seq,event]:events_) {
        (void)seq;std::vector<std::uint8_t> bytes;
        std::visit([&](const auto& value){(void)wire::encode(value,bytes);},event);bytes_+=bytes.size();
    }
    if (previous && previous->tick().value == cert.tick()) previous.reset();
    return std::optional<Publication>{Publication{std::move(previous),latest(),std::move(encoded),retained}};
}
}
