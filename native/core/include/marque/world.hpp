#pragma once

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <expected>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <variant>
#include <vector>

namespace marque::world {

enum class Kind : std::uint8_t { player, npc, item, node };

template<Kind K>
struct Handle {
    std::uint32_t index;
    std::uint32_t generation;
    static constexpr Kind kind = K;
    bool operator==(const Handle&) const = default;
};

using Player = Handle<Kind::player>;
using Npc = Handle<Kind::npc>;
using Item = Handle<Kind::item>;
using Node = Handle<Kind::node>;
using Entity = std::variant<Player, Npc, Item, Node>;

inline Kind kind(const Entity& entity) {
    return std::visit([](auto id) { return id.kind; }, entity);
}

inline std::uint32_t generation(const Entity& entity) {
    return std::visit([](auto id) { return id.generation; }, entity);
}

inline std::uint64_t slot_key(const Entity& entity) {
    return std::visit([](auto id) {
        return (static_cast<std::uint64_t>(id.kind) << 32) | id.index;
    }, entity);
}

struct Tick {
    std::uint32_t value;
    bool operator==(const Tick&) const = default;
};

struct Time {
    std::int64_t microseconds;
    bool operator==(const Time&) const = default;
};

struct Config {
    std::size_t max_known_slots = 100000;
    std::chrono::microseconds tick_interval{40000};
    std::chrono::microseconds jitter_delay{40000};
};

enum class ConfigError { slot_limit, tick_interval, jitter_delay };
enum class ApplyError { stale_tick, conflicting_change, unknown_entity, incomplete_entry, slot_limit, time_overflow };

template<class... C>
struct Components {
    using components = Components<C...>;
    using values = std::tuple<std::optional<C>...>;
    template<class T> static constexpr bool required(Kind) { return true; }
};

template<class Catalog>
struct Enter {
    Entity entity;
    typename Catalog::values values;
};

template<class C>
struct Replace {
    using component = C;
    Entity entity;
    C value;
};

struct Leave { Entity entity; };

namespace detail {

template<class Catalog, class List> struct Changes;
template<class Catalog, class... C>
struct Changes<Catalog, Components<C...>> {
    using type = std::variant<Enter<Catalog>, Leave, Replace<C>...>;
};

}

template<class Catalog>
using Change = typename detail::Changes<Catalog, typename Catalog::components>::type;

template<class Catalog, class Events>
struct CompleteTick {
    Tick tick;
    Time received_at;
    std::vector<Change<Catalog>> changes;
    Events events;
};

template<class Catalog, class Events> class Applier;
template<class Catalog, class Events> class Reader;
template<class Catalog> class RenderFrame;

template<class Catalog, class List = typename Catalog::components>
class Snapshot;

template<class Catalog, class... C>
class Snapshot<Catalog, Components<C...>> {
    struct Record { Entity entity; bool visible; };
    struct Directory {
        std::unordered_map<std::uint64_t, std::size_t> rows;
        std::vector<Record> records;
        std::vector<Entity> members;
    };
    template<class T> using Column = std::vector<std::optional<T>>;
    struct Data {
        std::shared_ptr<const Directory> directory = std::make_shared<const Directory>();
        std::tuple<std::shared_ptr<const Column<C>>...> columns{std::make_shared<const Column<C>>()...};
    };
    std::shared_ptr<const Data> data_;
    explicit Snapshot(std::shared_ptr<const Data> data) : data_(std::move(data)) {}
    template<class, class> friend class Applier;

public:
    template<class T>
    class Table {
        std::shared_ptr<const Directory> directory_;
        std::shared_ptr<const Column<T>> column_;
        Table(std::shared_ptr<const Directory> directory, std::shared_ptr<const Column<T>> column)
            : directory_(std::move(directory)), column_(std::move(column)) {}
        friend class Snapshot;
    public:
        const T* find(Entity entity) const {
            const auto it = directory_->rows.find(slot_key(entity));
            if (it == directory_->rows.end()) return nullptr;
            const auto row = it->second;
            const auto& record = directory_->records[row];
            if (!record.visible || record.entity != entity || row >= column_->size()) return nullptr;
            const auto& value = (*column_)[row];
            return value ? &*value : nullptr;
        }
        std::size_t stored_rows() const { return column_->size(); }
        std::size_t size() const {
            return std::count_if(column_->begin(), column_->end(), [](const auto& value) { return value.has_value(); });
        }
        std::span<const std::optional<T>> values() const { return *column_; }
    };

    bool contains(Entity entity) const {
        const auto it = data_->directory->rows.find(slot_key(entity));
        if (it == data_->directory->rows.end()) return false;
        const auto& record = data_->directory->records[it->second];
        return record.visible && record.entity == entity;
    }
    std::optional<Entity> remembered(Entity entity) const {
        const auto it = data_->directory->rows.find(slot_key(entity));
        if (it == data_->directory->rows.end()) return std::nullopt;
        return data_->directory->records[it->second].entity;
    }
    std::span<const Entity> entities() const { return data_->directory->members; }
    std::size_t known_slots() const { return data_->directory->records.size(); }
    template<class F> void visit_records(F&& visit) const {
        for(std::size_t row=0;row<data_->directory->records.size();++row) {
            const auto& record=data_->directory->records[row];
            visit(record.entity,record.visible,([&]() -> std::optional<C> {
                const auto& column=*std::get<std::shared_ptr<const Column<C>>>(data_->columns);
                return row<column.size() ? column[row] : std::nullopt;
            }())...);
        }
    }
    template<class T> Table<T> table() const {
        return Table<T>(data_->directory, std::get<std::shared_ptr<const Column<T>>>(data_->columns));
    }
};

template<class Catalog, class Events>
class PublishedTick {
    Tick tick_;
    Time sample_time_;
    Snapshot<Catalog> world_;
    Events events_;
    PublishedTick(Tick tick, Time time, Snapshot<Catalog> world, Events events)
        : tick_(tick), sample_time_(time), world_(std::move(world)), events_(std::move(events)) {}
    friend class Applier<Catalog, Events>;
public:
    Tick tick() const { return tick_; }
    Time sample_time() const { return sample_time_; }
    const Snapshot<Catalog>& world() const { return world_; }
    const Events& events() const { return events_; }
};

template<class Catalog>
class RenderFrame {
    Snapshot<Catalog> previous_;
    Snapshot<Catalog> current_;
    double alpha_;
    RenderFrame(Snapshot<Catalog> previous, Snapshot<Catalog> current, double alpha)
        : previous_(std::move(previous)), current_(std::move(current)), alpha_(alpha) {}
    template<class, class> friend class Reader;
public:
    double alpha() const { return alpha_; }
    const Snapshot<Catalog>& discrete_world() const { return alpha_ < 1 ? previous_ : current_; }
    std::span<const Entity> entities() const { return discrete_world().entities(); }
    template<class T> std::optional<T> sample(Entity entity) const {
        const auto* selected = discrete_world().template table<T>().find(entity);
        if (!selected) return std::nullopt;
        if constexpr (requires(const T& a, const T& b) { Catalog::interpolate(a, b, 0.5); }) {
            const auto* a = previous_.template table<T>().find(entity);
            const auto* b = current_.template table<T>().find(entity);
            if (a && b) return Catalog::interpolate(*a, *b, alpha_);
        }
        return *selected;
    }
};

template<class Catalog, class Events>
class Reader {
    using Publication = PublishedTick<Catalog, Events>;
    struct Pair {
        std::shared_ptr<const Publication> previous;
        std::shared_ptr<const Publication> current;
    };
    struct Slot { Pair pair; };
    std::shared_ptr<const Slot> slot_;
    std::chrono::microseconds delay_;
    Reader(std::shared_ptr<const Slot> slot, std::chrono::microseconds delay)
        : slot_(std::move(slot)), delay_(delay) {}
    friend class Applier<Catalog, Events>;
public:
    std::shared_ptr<const Publication> latest() const { return slot_->pair.current; }
    std::optional<RenderFrame<Catalog>> render_at(Time now) const {
        const auto& pair = slot_->pair;
        if (!pair.current) return std::nullopt;
        if (!pair.previous) return RenderFrame<Catalog>(pair.current->world(), pair.current->world(), 1);
        const auto a = pair.previous->sample_time().microseconds;
        const auto b = pair.current->sample_time().microseconds;
        const auto target = static_cast<long double>(now.microseconds) - delay_.count();
        const double alpha = static_cast<double>(std::clamp((target - a) / (static_cast<long double>(b) - a), 0.0L, 1.0L));
        return RenderFrame<Catalog>(pair.previous->world(), pair.current->world(), alpha);
    }
};

template<class Catalog, class Events>
class Applier {
    using World = Snapshot<Catalog>;
    using Data = typename World::Data;
    using Directory = typename World::Directory;
    template<class T> using Column = typename World::template Column<T>;
    using Read = Reader<Catalog, Events>;
    using Publication = PublishedTick<Catalog, Events>;
    std::shared_ptr<typename Read::Slot> slot_;
    Config config_;
    Applier(Config config) : slot_(std::make_shared<typename Read::Slot>()), config_(config) {}

    struct Group {
        Entity entity;
        bool enter = false;
        bool leave = false;
        bool conflict = false;
        bool incomplete = false;
        typename Catalog::values values;
    };

    template<class T> static void merge_value(Group& group, const T& value) {
        auto& target = std::get<std::optional<T>>(group.values);
        if (target && *target != value) group.conflict = true;
        else target = value;
    }

    template<class... C>
    std::expected<World, ApplyError> reduce(const std::shared_ptr<const Data>& old,
                                          const std::vector<Change<Catalog>>& changes, Components<C...>) const {
        std::vector<Group> groups;
        std::unordered_map<std::uint64_t, std::size_t> positions;
        groups.reserve(changes.size());
        positions.reserve(changes.size());
        for (const auto& change : changes) {
            std::visit([&](const auto& value) {
                const auto key = slot_key(value.entity);
                auto [it, added] = positions.try_emplace(key, groups.size());
                if (added) groups.push_back(Group{value.entity, false, false, false, false, {}});
                auto& group = groups[it->second];
                if (generation(value.entity) < generation(group.entity)) return;
                if (generation(value.entity) > generation(group.entity)) group = Group{value.entity, false, false, false, false, {}};
                using V = std::decay_t<decltype(value)>;
                if constexpr (std::is_same_v<V, Leave>) group.leave = true;
                else if constexpr (std::is_same_v<V, Enter<Catalog>>) {
                    group.enter = true;
                    ([&] {
                        const auto& component = std::get<std::optional<C>>(value.values);
                        if (component) merge_value(group, *component);
                        else if (Catalog::template required<C>(kind(value.entity))) group.incomplete = true;
                    }(), ...);
                } else merge_value(group, value.value);
            }, change);
        }

        auto next = std::make_shared<Data>(*old);
        std::shared_ptr<Directory> directory;
        std::tuple<std::shared_ptr<Column<C>>...> writable;
        auto write = [&]<class T>(std::size_t row, std::optional<T> value) {
            auto& column = std::get<std::shared_ptr<Column<T>>>(writable);
            if (!column) {
                column = std::make_shared<Column<T>>(*std::get<std::shared_ptr<const Column<T>>>(old->columns));
                std::get<std::shared_ptr<const Column<T>>>(next->columns) = column;
            }
            if (column->size() <= row) column->resize(row + 1);
            (*column)[row] = std::move(value);
        };
        for (const auto& group : groups) {
            const auto key = slot_key(group.entity);
            const auto& active_directory = directory ? *directory : *old->directory;
            const auto found = active_directory.rows.find(key);
            const bool known = found != active_directory.rows.end();
            const std::size_t row = known ? found->second : active_directory.records.size();
            const auto* record = known ? &active_directory.records[row] : nullptr;
            if (record && generation(group.entity) < generation(record->entity)) continue;
            const bool values_present = (std::get<std::optional<C>>(group.values).has_value() || ...);
            if (group.conflict || (group.leave && (group.enter || values_present))) return std::unexpected(ApplyError::conflicting_change);
            if (group.incomplete || (group.enter && ((Catalog::template required<C>(kind(group.entity)) && !std::get<std::optional<C>>(group.values)) || ...)))
                return std::unexpected(ApplyError::incomplete_entry);
            const bool same = record && record->entity == group.entity;
            if (!group.enter && !group.leave && (!same || !record->visible))
                return std::unexpected(known && !same ? ApplyError::incomplete_entry : ApplyError::unknown_entity);
            if (!known && active_directory.records.size() >= config_.max_known_slots) return std::unexpected(ApplyError::slot_limit);
            const bool visible = !group.leave;
            const bool transition = !same || record->visible != visible;
            if (transition) {
                if (!directory) {
                    directory = std::make_shared<Directory>(*old->directory);
                    next->directory = directory;
                }
                if (!known) {
                    directory->rows.emplace(key, row);
                    directory->records.push_back({group.entity, visible});
                } else directory->records[row] = {group.entity, visible};
            }
            if (!same || group.leave || group.enter) (write(row, std::optional<C>{}), ...);
            if (!group.leave) ([&] {
                const auto& value = std::get<std::optional<C>>(group.values);
                if (value) write(row, value);
            }(), ...);
        }
        if (directory) {
            directory->members.clear();
            for (const auto& record : directory->records) if (record.visible) directory->members.push_back(record.entity);
        }
        return World(std::move(next));
    }

public:
    Applier(const Applier&) = delete;
    Applier& operator=(const Applier&) = delete;
    Applier(Applier&&) noexcept = default;
    Applier& operator=(Applier&&) noexcept = default;
    static std::expected<Applier, ConfigError> create(Config config = {}) {
        if (!config.max_known_slots) return std::unexpected(ConfigError::slot_limit);
        if (config.tick_interval.count() < 33334 || config.tick_interval.count() > 50000) return std::unexpected(ConfigError::tick_interval);
        if (config.jitter_delay.count() < 0) return std::unexpected(ConfigError::jitter_delay);
        return Applier(config);
    }
    Read reader() const { return Read(slot_, config_.jitter_delay); }
    std::expected<Tick, ApplyError> apply(CompleteTick<Catalog, Events> batch) {
        const auto old_publication = slot_->pair.current;
        if (old_publication && batch.tick.value <= old_publication->tick().value) return std::unexpected(ApplyError::stale_tick);
        Time time = batch.received_at;
        if (old_publication) {
            const auto delta = static_cast<std::int64_t>(batch.tick.value - old_publication->tick().value) * config_.tick_interval.count();
            if (old_publication->sample_time().microseconds > std::numeric_limits<std::int64_t>::max() - delta)
                return std::unexpected(ApplyError::time_overflow);
            time.microseconds = old_publication->sample_time().microseconds + delta;
        }
        const auto data = old_publication ? old_publication->world().data_ : std::make_shared<const Data>();
        auto world = reduce(data, batch.changes, typename Catalog::components{});
        if (!world) return std::unexpected(world.error());
        auto publication = std::shared_ptr<const Publication>(new Publication(batch.tick, time, std::move(*world), std::move(batch.events)));
        typename Read::Pair pair{old_publication, std::move(publication)};
        slot_->pair = std::move(pair);
        return batch.tick;
    }
};

}
