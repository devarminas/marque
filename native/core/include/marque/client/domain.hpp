#pragma once

#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <variant>

#include "marque/transport/receiver.hpp"
#include "marque/wire/gen/schema.hpp"
#include "marque/world.hpp"

namespace marque::client {

std::expected<wire::Entity,wire::codec::Error> complete_entity(const wire::EntitySnapshot& row);

struct Catalog : world::Components<wire::Transform, wire::Vitals, wire::Gear, wire::CastBar, wire::Look> {
    template<class T> static constexpr bool required(world::Kind) { return std::is_same_v<T, wire::Transform>; }
    static wire::Transform interpolate(const wire::Transform& a, const wire::Transform& b, double alpha) {
        return *wire::Transform::build({a.x() + (b.x()-a.x())*alpha,
                                      a.y() + (b.y()-a.y())*alpha,
                                      a.z() + (b.z()-a.z())*alpha});
    }
};

using OwnerEvent = std::variant<wire::Inventory, wire::Equipment, wire::Class, wire::Skills,
    wire::QuestLog, wire::Dialog, wire::Party, wire::Invite, wire::AdminReply, wire::Cooldown,
    wire::Refused, wire::DialogClear, wire::PartyClear, wire::InviteClear>;
using Presentation = std::variant<wire::Swing, wire::CastPhase, wire::GatherStart>;

struct OwnerState {
    std::optional<wire::Inventory> inventory;
    std::optional<wire::Equipment> equipment;
    std::optional<wire::Class> role;
    std::optional<wire::Skills> skills;
    std::optional<wire::QuestLog> quests;
    std::optional<wire::Dialog> dialog;
    std::optional<wire::Party> party;
    std::optional<wire::Invite> invite;
    std::optional<wire::AdminReply> admin;
    std::map<std::string, wire::Cooldown> cooldowns;
    std::optional<wire::Refused> refusal;
    void apply(const OwnerEvent& event);
};

struct Events {
    std::shared_ptr<const OwnerState> owner;
    std::vector<OwnerEvent> changes;
    std::vector<Presentation> presentation;
    std::uint64_t stream;
    std::uint64_t epoch;
    std::uint64_t event_end;
    std::uint32_t next_intent;
    std::optional<wire::OwnerMotion> motion;
};

using Tick = world::PublishedTick<Catalog, Events>;
struct Publication {
    std::shared_ptr<const Tick> previous;
    std::shared_ptr<const Tick> current;
    std::vector<std::uint8_t> application_commit;
    std::size_t retained_bytes;
};

enum class DomainError { malformed, identity, sequence, cursor, state_count, capacity, world, recovery_required, unavailable, deadline };
enum class DomainPhase { live, reset_pending, unavailable };
struct ResetLimits {
    std::size_t parts = 1024;
    std::size_t entities = 4096;
    std::size_t encoded_bytes = 4*1024*1024;
    std::size_t decoded_bytes = 8*1024*1024;
    std::int64_t timeout_us = 30000000;
};
struct DomainLimits {
    std::size_t slices = 256;
    std::size_t boundaries = 256;
    std::size_t events = 4096;
    std::size_t staged_bytes = 4*1024*1024;
    std::size_t cooldowns = 256;
};

class Assembler {
    struct Slice { std::vector<wire::StateMsg> records; std::size_t bytes; world::Time received; };
    std::map<std::uint32_t, Slice> slices_;
    std::map<std::uint64_t, OwnerEvent> events_;
    std::deque<wire::TickClose> boundaries_;
    std::size_t bytes_ = 0;
    DomainLimits limits_;
    world::Applier<Catalog, Events> world_;
    struct ResetStage {
        std::optional<wire::ResetBegin> begin;
        std::vector<std::optional<wire::ResetPart>> parts;
        std::size_t encoded_bytes = 0;
        bool closed = false;
        world::Time received{};
    };
    ResetLimits reset_limits_;
    DomainPhase phase_ = DomainPhase::live;
    std::uint64_t lease_ = 0;
    wire::PlayerId player_{};
    world::Time lease_started_{};
    std::optional<ResetStage> reset_;
    std::optional<wire::ResetCertificate> committed_reset_;
    std::vector<std::uint8_t> reset_commit_;
    bool reset_commit_pending_ = false;
    std::optional<wire::ResetFailure> unavailable_;
    std::expected<void, DomainError> reset_unavailable(wire::ResetFailure reason, DomainError error);
    std::expected<void, DomainError> receive_reset(const std::vector<wire::EventsMsg>& messages, world::Time now);
    std::uint64_t stream_ = 0;
    std::uint64_t epoch_ = 0;
    std::uint64_t applied_ = 0;
    std::uint64_t received_ = 0;
    std::uint32_t next_intent_ = 1;
    std::uint32_t frontier_ = 1;
    std::uint32_t tick_ = 0;
    explicit Assembler(DomainLimits limits, world::Applier<Catalog, Events> world)
        : limits_(limits), world_(std::move(world)) {}
public:
    static Assembler create(DomainLimits limits = {});
    std::expected<void, DomainError> receive(const transport::Received& packet, world::Time now);
    using ValidatePublication=std::function<std::expected<void,DomainError>(const Events&,world::Tick)>;
    std::expected<void, DomainError> replace_lease(std::uint64_t stream, std::uint64_t epoch, std::uint64_t lease, wire::PlayerId player, world::Time now, ResetLimits limits = {});
    std::expected<void, DomainError> advance_reset(world::Time now);
    DomainPhase phase() const { return phase_; }
    std::optional<wire::ResetCertificate> pending_reset() const {
        return reset_ && reset_->begin ? std::optional{reset_->begin->certificate()} : std::nullopt;
    }
    std::optional<wire::ResetFailure> unavailable_reason() const { return unavailable_; }
    std::optional<std::vector<std::uint8_t>> take_reset_commit();
private:
    std::expected<std::optional<Publication>, DomainError> publish_reset(std::size_t available_bytes,const ValidatePublication& validate);
public:
    std::expected<std::optional<Publication>, DomainError> publish(std::size_t available_bytes,const ValidatePublication& validate={});
    std::shared_ptr<const Tick> latest() const { return world_.reader().latest(); }
    void admitted_frontier(std::uint32_t next) { frontier_ = next; }
    std::size_t staged_bytes() const { return bytes_; }
};

world::Entity entity(const wire::EntityId& id);

}
