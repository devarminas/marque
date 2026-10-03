#pragma once

#include <deque>
#include <map>
#include <memory>
#include <optional>
#include <variant>

#include "marque/transport/receiver.hpp"
#include "marque/wire/gen/schema.hpp"
#include "marque/world.hpp"

namespace marque::client {

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
};

using Tick = world::PublishedTick<Catalog, Events>;
struct Publication {
    std::shared_ptr<const Tick> previous;
    std::shared_ptr<const Tick> current;
    std::vector<std::uint8_t> application_commit;
    std::size_t retained_bytes;
};

enum class DomainError { malformed, identity, sequence, cursor, state_count, capacity, world, recovery_required };
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
    std::expected<std::optional<Publication>, DomainError> publish(std::size_t available_bytes);
    std::shared_ptr<const Tick> latest() const { return world_.reader().latest(); }
    void admitted_frontier(std::uint32_t next) { frontier_ = next; }
    std::size_t staged_bytes() const { return bytes_; }
};

world::Entity entity(const wire::EntityId& id);

}
