#include "marque/recording/replay.hpp"

#include <bit>
#include <stdexcept>

namespace marque::recording {
namespace {
class Encoder {
  std::vector<std::uint8_t> out_;
  wire::codec::Writer w_{out_};

public:
  void u32(std::uint32_t value) { w_.u32(value); }
  void u64(std::uint64_t value) { w_.u64(value); }
  void flag(bool value) { w_.boolean(value); }
  template <class M> void message(const M &message) {
    std::vector<std::uint8_t> bytes;
    if (!wire::encode(message, bytes))
      throw std::logic_error("canonical message");
    w_.u32(bytes.size());
    for (auto value : bytes)
      w_.u8(value);
  }
  template <class M> void optional(const std::optional<M> &value) {
    flag(value.has_value());
    if (value)
      message(*value);
  }
  void tick(const std::shared_ptr<const client::Tick> &tick) {
    flag(bool(tick));
    if (!tick)
      return;
    u32(tick->tick().value);
    u64(std::bit_cast<std::uint64_t>(tick->sample_time().microseconds));
    struct Row {
      world::Entity entity;
      bool visible;
      client::Catalog::values values;
    };
    std::vector<Row> rows;
    tick->world().visit_records(
        [&](world::Entity entity, bool visible, const auto &...values) {
          rows.push_back({entity, visible, {values...}});
        });
    std::sort(rows.begin(), rows.end(), [](const auto &a, const auto &b) {
      return world::slot_key(a.entity) < world::slot_key(b.entity);
    });
    u32(rows.size());
    for (const auto &row : rows) {
      w_.u8(static_cast<std::uint8_t>(world::kind(row.entity)));
      u64(world::slot_key(row.entity));
      u32(world::generation(row.entity));
      flag(row.visible);
      auto id = std::visit(
          [](auto id) -> wire::EntityId {
            using H = decltype(id);
            if constexpr (std::is_same_v<H, world::Player>)
              return wire::PlayerId{id.index, id.generation};
            else if constexpr (std::is_same_v<H, world::Npc>)
              return wire::NpcId{id.index, id.generation};
            else if constexpr (std::is_same_v<H, world::Item>)
              return wire::ItemId{id.index, id.generation};
            else
              return wire::NodeId{id.index, id.generation};
          },
          row.entity);
      auto entity = wire::Entity::build({id,
          std::get<std::optional<wire::Transform>>(row.values),
          *wire::VitalsUpdate::build({std::get<std::optional<wire::Vitals>>(row.values)}),
          *wire::GearUpdate::build({std::get<std::optional<wire::Gear>>(row.values)}),
          *wire::CastUpdate::build({std::get<std::optional<wire::CastBar>>(row.values)}),
          *wire::LookUpdate::build({std::get<std::optional<wire::Look>>(row.values)})});
      if (!entity)
        throw std::logic_error("canonical entity");
      message(*entity);
      if (const auto &transform =
              std::get<std::optional<wire::Transform>>(row.values);
          transform) {
        u64(std::bit_cast<std::uint64_t>(transform->x()));
        u64(std::bit_cast<std::uint64_t>(transform->y()));
        u64(std::bit_cast<std::uint64_t>(transform->z()));
      }
    }
    const auto &events = tick->events();
    u64(events.stream);
    u64(events.epoch);
    u64(events.event_end);
    u32(events.next_intent);
    optional(events.motion);
    flag(bool(events.owner));
    if (events.owner) {
      const auto &owner = *events.owner;
      optional(owner.inventory);
      optional(owner.equipment);
      optional(owner.role);
      optional(owner.skills);
      optional(owner.quests);
      optional(owner.dialog);
      optional(owner.party);
      optional(owner.invite);
      optional(owner.admin);
      optional(owner.refusal);
      u32(owner.cooldowns.size());
      for (const auto &[key, value] : owner.cooldowns) {
        w_.string(key, 64);
        message(value);
      }
    }
    u32(events.changes.size());
    for (const auto &value : events.changes)
      std::visit([&](const auto &event) { message(event); }, value);
    u32(events.presentation.size());
    for (const auto &value : events.presentation)
      std::visit([&](const auto &event) { message(event); }, value);
  }
  std::vector<std::uint8_t> finish() {
    if (!w_.finish())
      throw std::logic_error("canonical encoder");
    return std::move(out_);
  }
};
}
std::vector<std::uint8_t> canonical(const client::Publication &publication) {
  Encoder encoder;
  encoder.u32(1);
  encoder.tick(publication.previous);
  encoder.tick(publication.current);
  return encoder.finish();
}
}
