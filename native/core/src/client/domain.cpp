#include "marque/client/domain.hpp"
#include "marque/motion/prediction.hpp"

#include <limits>
#include <stdexcept>
#include <type_traits>

namespace marque::client {

world::Entity entity(const wire::EntityId& id) {
    return std::visit([](const auto& value) -> world::Entity {
        using T = std::decay_t<decltype(value)>;
        if constexpr (std::is_same_v<T, wire::PlayerId>) return world::Player{value.index,value.gen};
        else if constexpr (std::is_same_v<T, wire::NpcId>) return world::Npc{value.index,value.gen};
        else if constexpr (std::is_same_v<T, wire::ItemId>) return world::Item{value.index,value.gen};
        else return world::Node{value.index,value.gen};
    }, id);
}

void OwnerState::apply(const OwnerEvent& event) {
    std::visit([&](const auto& value) {
        using T = std::decay_t<decltype(value)>;
        if constexpr (std::is_same_v<T, wire::Inventory>) inventory=value;
        else if constexpr (std::is_same_v<T, wire::Equipment>) equipment=value;
        else if constexpr (std::is_same_v<T, wire::Class>) role=value;
        else if constexpr (std::is_same_v<T, wire::Skills>) skills=value;
        else if constexpr (std::is_same_v<T, wire::QuestLog>) quests=value;
        else if constexpr (std::is_same_v<T, wire::Dialog>) dialog=value;
        else if constexpr (std::is_same_v<T, wire::Party>) party=value;
        else if constexpr (std::is_same_v<T, wire::Invite>) invite=value;
        else if constexpr (std::is_same_v<T, wire::AdminReply>) admin=value;
        else if constexpr (std::is_same_v<T, wire::Cooldown>) cooldowns.insert_or_assign(value.ability(),value);
        else if constexpr (std::is_same_v<T, wire::Refused>) refusal=value;
        else if constexpr (std::is_same_v<T, wire::DialogClear>) {
            if (dialog && dialog->npc()==value.npc()) dialog.reset();
        } else if constexpr (std::is_same_v<T, wire::PartyClear>) party.reset();
        else if constexpr (std::is_same_v<T, wire::InviteClear>) invite.reset();
    },event);
}

Assembler Assembler::create(DomainLimits limits) {
    if (!limits.slices || !limits.boundaries || !limits.events || !limits.staged_bytes || !limits.cooldowns)
        throw std::invalid_argument("client domain limits must be positive");
    return Assembler(limits, std::move(*world::Applier<Catalog,Events>::create()));
}

std::expected<void, DomainError> Assembler::receive(const transport::Received& packet, world::Time now) {
    std::optional<Slice> slice;
    std::vector<wire::EventsMsg> reliable;
    std::size_t added=0;
    if (packet.unreliable && packet.unreliable->stamp>tick_) {
        Slice decoded{{},0,now};
        for (const auto& bytes:packet.unreliable->items) {
            auto record=wire::decode_state(bytes);
            if (!record) return std::unexpected(DomainError::malformed);
            decoded.records.push_back(std::move(*record));
            decoded.bytes+=bytes.size();
        }
        added+=decoded.bytes;
        slice=std::move(decoded);
    }
    for (const auto& bytes:packet.reliable) {
        auto record=wire::decode_events(bytes);
        if (!record) return std::unexpected(DomainError::malformed);
        reliable.push_back(std::move(*record));
    }
    if (added>limits_.staged_bytes || bytes_>limits_.staged_bytes-added)
        return std::unexpected(DomainError::capacity);
    if (slice && slices_.contains(packet.unreliable->stamp)) return std::unexpected(DomainError::sequence);
    if (slice && slices_.size()>=limits_.slices) return std::unexpected(DomainError::capacity);
    auto next_stream=stream_;
    auto next_epoch=epoch_;
    auto next_received=received_;
    std::vector<OwnerEvent> facts;
    std::vector<wire::TickClose> closes;
    std::size_t message_index=0;
    for (const auto& message:reliable) {
        auto valid=std::visit([&](const auto& value) -> std::expected<void,DomainError> {
            using T=std::decay_t<decltype(value)>;
            if constexpr (std::is_same_v<T,wire::ResumeBoundary>) return std::unexpected(DomainError::recovery_required);
            else {
                if (!value.stream() || (next_stream && value.stream()!=next_stream))
                    return std::unexpected(DomainError::identity);
                next_stream=value.stream();
                if constexpr (std::is_same_v<T,wire::TickClose>) {
                    if (!value.epoch() || (next_epoch && value.epoch()!=next_epoch)) return std::unexpected(DomainError::identity);
                    next_epoch=value.epoch();
                    if (value.tick()<=tick_) return {};
                    if (value.event_end()<applied_) return std::unexpected(DomainError::sequence);
                    if (value.event_end()>next_received) return std::unexpected(DomainError::sequence);
                    const auto last=closes.empty() ? (boundaries_.empty() ? 0 : boundaries_.back().tick()) : closes.back().tick();
                    if (value.tick()<=last) return std::unexpected(DomainError::sequence);
                    closes.push_back(value);
                    added+=packet.reliable[message_index].size();
                } else {
                    if (!value.event_seq() || value.event_seq()==std::numeric_limits<std::uint64_t>::max()) return std::unexpected(DomainError::sequence);
                    if (value.event_seq()<=applied_) return {};
                    if (value.event_seq()!=next_received+1) return std::unexpected(DomainError::sequence);
                    next_received=value.event_seq();
                    facts.emplace_back(value);
                    added+=packet.reliable[message_index].size();
                }
                return {};
            }
        },message);
        if (!valid) return valid;
        ++message_index;
    }
    if (added>limits_.staged_bytes || bytes_>limits_.staged_bytes-added) return std::unexpected(DomainError::capacity);
    std::size_t zero_slices=0;
    for (const auto& close:closes) if (!close.state_items() && !slices_.contains(close.tick()) && !(slice && packet.unreliable->stamp==close.tick())) ++zero_slices;
    if (slices_.size()+(slice ? 1 : 0)+zero_slices>limits_.slices) return std::unexpected(DomainError::capacity);
    if (events_.size()+facts.size()>limits_.events || boundaries_.size()+closes.size()>limits_.boundaries)
        return std::unexpected(DomainError::capacity);
    if (slice) slices_.emplace(packet.unreliable->stamp,std::move(*slice));
    for (auto& fact:facts) events_.emplace(std::visit([](const auto& v){return v.event_seq();},fact),std::move(fact));
    for (auto& close:closes) {
        if (!close.state_items() && !slices_.contains(close.tick())) slices_.emplace(close.tick(),Slice{{},0,now});
        boundaries_.push_back(std::move(close));
    }
    bytes_+=added;
    stream_=next_stream;
    epoch_=next_epoch;
    received_=next_received;
    return {};
}

std::expected<std::optional<Publication>, DomainError> Assembler::publish(std::size_t available_bytes,const ValidatePublication& validate) {
    auto chosen=boundaries_.end();
    for (auto it=boundaries_.begin();it!=boundaries_.end();++it) {
        const auto slice=slices_.find(it->tick());
        if (slice==slices_.end()) continue;
        if (slice->second.records.size()!=it->state_items()) return std::unexpected(DomainError::state_count);
        chosen=it;
        break;
    }
    if (chosen==boundaries_.end()) return std::optional<Publication>{};
    const auto close=*chosen;
    if (close.next_intent()<next_intent_ || close.next_intent()>frontier_) return std::unexpected(DomainError::cursor);
    auto previous=latest();
    auto owner=std::make_shared<OwnerState>(previous ? *previous->events().owner : OwnerState{});
    Events output{owner,{}, {},stream_,epoch_,close.event_end(),close.next_intent(),{}};
    for (auto seq=applied_+1;seq<=close.event_end();++seq) {
        const auto it=events_.find(seq);
        if (it==events_.end()) return std::optional<Publication>{};
        if (std::visit([](const auto& v){return v.tick();},it->second)>close.tick()) return std::unexpected(DomainError::sequence);
        owner->apply(it->second);
        output.changes.push_back(it->second);
    }
    if (owner->cooldowns.size()>limits_.cooldowns) return std::unexpected(DomainError::capacity);
    struct Row { world::Entity id; bool visible; bool remembered; Catalog::values values; };
    std::map<std::uint64_t,Row> rows;
    auto load=[&](world::Entity id) -> Row& {
        const auto key=world::slot_key(id);
        auto it=rows.find(key);
        if (it!=rows.end()) return it->second;
        Row row{id,false,false,{}};
        if (previous) {
            const auto& old=previous->world();
            if (const auto remembered=old.remembered(id)) {row.id=*remembered;row.visible=old.contains(row.id);row.remembered=true;}
            auto fetch=[&]<class T>() {if (const auto* value=old.table<T>().find(row.id)) std::get<std::optional<T>>(row.values)=*value;};
            fetch.template operator()<wire::Transform>(); fetch.template operator()<wire::Vitals>();
            fetch.template operator()<wire::Gear>(); fetch.template operator()<wire::CastBar>(); fetch.template operator()<wire::Look>();
        }
        return rows.emplace(key,std::move(row)).first->second;
    };
    for (const auto& [stamp,slice]:slices_) {
        if (stamp>close.tick()) break;
        for (const auto& record:slice.records) {
            auto valid=std::visit([&](const auto& value) -> bool {
                using T=std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<T,wire::Entity> || std::is_same_v<T,wire::Gone>) {
                    const auto id=entity(value.id());
                    auto& row=load(id);
                    if (world::generation(id)<world::generation(row.id)) return true;
                    if (id!=row.id) row=Row{id,false,false,{}};
                    if constexpr (std::is_same_v<T,wire::Gone>) row=Row{id,false,true,{}};
                    else {
                        if (!row.visible && row.remembered && !value.transform()) return true;
                        auto replace=[&]<class C>(const std::optional<C>& component){if(component) std::get<std::optional<C>>(row.values)=*component;};
                        replace(value.transform()); replace(value.vitals()); replace(value.gear()); replace(value.cast()); replace(value.look());
                        if (!row.visible && !std::get<std::optional<wire::Transform>>(row.values)) return false;
                        row.visible=true;
                    }
                } else if constexpr (std::is_same_v<T,wire::OwnerMotion>) {
                    if (value.tick()!=stamp || value.stream()!=stream_ || value.epoch()!=epoch_ ||
                        !motion::PublishedBaseline::complete(value,stamp)) return false;
                    if (stamp==close.tick()) output.motion=value;
                } else if constexpr (std::is_same_v<T,wire::Pose> || std::is_same_v<T,wire::Hp>) return false;
                else output.presentation.emplace_back(value);
                return true;
            },record);
            if (!valid) return std::unexpected(DomainError::world);
        }
    }
    std::vector<world::Change<Catalog>> changes;
    for (auto& [key,row]:rows) {
        (void)key;
        if (row.visible) changes.emplace_back(world::Enter<Catalog>{row.id,std::move(row.values)});
        else changes.emplace_back(world::Leave{row.id});
    }
    const auto retained=1024*1024+((previous ? previous->world().known_slots() : 0)+rows.size())*4096+2*bytes_;
    if (retained>available_bytes) return std::unexpected(DomainError::capacity);
    auto commit=wire::ApplicationCommit::build({stream_,epoch_,close.tick(),close.event_end()});
    std::vector<std::uint8_t> encoded;
    if (!commit || !wire::encode(*commit,encoded)) return std::unexpected(DomainError::malformed);
    if(validate){auto result=validate(output,world::Tick{close.tick()});if(!result)return std::unexpected(result.error());}
    auto applied=world_.apply({world::Tick{close.tick()},slices_.at(close.tick()).received,std::move(changes),std::move(output)});
    if (!applied) return std::unexpected(DomainError::world);
    applied_=close.event_end();
    next_intent_=close.next_intent();
    tick_=close.tick();
    slices_.erase(slices_.begin(),slices_.upper_bound(tick_));
    events_.erase(events_.begin(),events_.upper_bound(applied_));
    boundaries_.erase(boundaries_.begin(),std::next(chosen));
    bytes_=0;
    for (const auto& [stamp,slice]:slices_) {(void)stamp;bytes_+=slice.bytes;}
    for (const auto& [seq,event]:events_) {
        (void)seq;std::vector<std::uint8_t> bytes;
        std::visit([&](const auto& value){(void)wire::encode(value,bytes);},event);
        bytes_+=bytes.size();
    }
    bytes_+=boundaries_.size()*36;
    return std::optional<Publication>{Publication{std::move(previous),latest(),std::move(encoded),retained}};
}

}
