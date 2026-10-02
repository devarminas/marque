#include "world_fixture/types.hpp"
#include "world_fixture/allocation.hpp"
#include "check.hpp"
#include <chrono>
#include <cstdio>
#include <deque>
#include <fstream>
#include <string>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace world_fixture;
using marque::test::check;

namespace {

constexpr std::size_t population = 5000;

Entity identity(std::size_t row, std::uint32_t slot, std::uint32_t gen) {
    switch (row % 4) {
    case 0: return Player{slot, gen};
    case 1: return Npc{slot, gen};
    case 2: return Item{slot, gen};
    default: return Node{slot, gen};
    }
}

long rss_kib() {
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_maxrss;
}

std::string cpu_name() {
    std::ifstream file("/proc/cpuinfo");
    std::string line;
    while (std::getline(file, line)) if (line.starts_with("model name")) return line.substr(line.find(':') + 2);
    return "unavailable";
}

struct Measurement { double microseconds; std::uint64_t allocations; std::uint64_t allocated_bytes; };

Measurement apply(World& world, Batch input) {
    world_allocation::begin();
    const auto start = std::chrono::steady_clock::now();
    const auto result = world.apply(std::move(input));
    const auto end = std::chrono::steady_clock::now();
    world_allocation::end();
    if (!result) {
        std::fprintf(stderr, "benchmark apply rejected tick error=%d\n", static_cast<int>(result.error()));
        std::exit(1);
    }
    return {std::chrono::duration<double, std::micro>(end - start).count(), world_allocation::calls, world_allocation::bytes};
}

void workload(const std::string& name, unsigned warmup, unsigned measured, bool pinned_history) {
    auto world = *World::create(Config{200000});
    auto reader = world.reader();
    std::vector<Entity> live;
    live.reserve(population);
    std::vector<Change<Catalog>> entries;
    entries.reserve(population);
    for (std::size_t i = 0; i < population; ++i) {
        live.push_back(identity(i, static_cast<std::uint32_t>(1000000000 + i * 101), 1));
        entries.push_back(entry(live.back(), 0));
    }
    const auto first = apply(world, batch(1, std::move(entries), 41));
    std::printf("workload=%s first_entry_us=%.3f first_allocations=%llu first_allocated_bytes=%llu\n", name.c_str(), first.microseconds,
                static_cast<unsigned long long>(first.allocations), static_cast<unsigned long long>(first.allocated_bytes));
    auto retained_first = reader.latest();
    std::deque<std::shared_ptr<const PublishedTick<Catalog, Events>>> history;
    std::vector<Measurement> samples;
    samples.reserve(measured);
    std::uint32_t fresh_slot = 2000000000;
    for (unsigned step = 1; step <= warmup + measured; ++step) {
        std::vector<Change<Catalog>> changes;
        changes.reserve(name == "full_components" ? 25000 : 5000);
        if (name == "transform_all" || name == "pinned_history") {
            for (const auto& id : live) changes.emplace_back(Replace<Position>{id, {static_cast<double>(step), 1, 2}});
        } else if (name == "sparse_10_percent") {
            for (std::size_t i = 0; i < 500; ++i) changes.emplace_back(Replace<Position>{live[i], {static_cast<double>(step), 1, 2}});
        } else if (name == "full_components") {
            for (const auto& id : live) {
                changes.emplace_back(Replace<Position>{id, {static_cast<double>(step), 1, 2}});
                changes.emplace_back(Replace<Health>{id, {70, 100, 30, 50}});
                changes.emplace_back(Replace<Equipment>{id, {{9, 8, 7, 6, 5, 4, 3, 2}, "fixture replacement equipment 32"}});
                changes.emplace_back(Replace<Casting>{id, {std::nullopt}});
                changes.emplace_back(Replace<Appearance>{id, {"fixture replacement appearance32", 12}});
            }
        } else {
            const std::size_t count = name == "fixed_slot_churn_5_percent" ? 250 : 50;
            const std::size_t start = ((step - 1) * count) % population;
            for (std::size_t i = start; i < start + count; ++i) {
                const auto old = live[i];
                changes.emplace_back(Leave{old});
                const auto old_slot = static_cast<std::uint32_t>(slot_key(old));
                const auto slot = name == "fixed_slot_churn_5_percent" ? old_slot : fresh_slot++;
                live[i] = identity(i, slot, generation(old) + 1);
                changes.emplace_back(entry(live[i], 100, 50));
            }
            for (std::size_t i = 0; i < 500; ++i) changes.emplace_back(Replace<Position>{live[i], {100, 1, 2}});
        }
        auto input = batch(step + 1, std::move(changes), 42);
        input.events.push_back({step, 71});
        const auto measurement = apply(world, std::move(input));
        if (step == warmup && !pinned_history) {
            check(retained_first->events() == Events{{1, 41}} && *retained_first->world().table<Position>().find(identity(0, 1000000000, 1)) == Position{0, 1, 2},
                  "retained first snapshot survives warmup and is released before measured two-tick workload");
            retained_first.reset();
        }
        if (step > warmup) samples.push_back(measurement);
        if (pinned_history) {
            history.push_back(reader.latest());
            if (history.size() > 8) history.pop_front();
        }
        if (name == "retired_slot_churn_1_percent" && (step == warmup || step == warmup + measured / 2 || step == warmup + measured)) {
            const auto publication = reader.latest();
            std::printf("churn_progress tick=%u live=%zu known_slots=%zu position_rows=%zu peak_rss_kib=%ld\n", step + 1,
                        publication->world().entities().size(), publication->world().known_slots(),
                        publication->world().table<Position>().stored_rows(), rss_kib());
        }
    }
    std::vector<double> times;
    std::uint64_t allocations = 0;
    std::uint64_t allocated_bytes = 0;
    for (const auto& sample : samples) {
        times.push_back(sample.microseconds);
        allocations += sample.allocations;
        allocated_bytes += sample.allocated_bytes;
    }
    std::sort(times.begin(), times.end());
    const auto publication = reader.latest();
    std::printf("workload=%s live=%zu known_slots=%zu measured_ticks=%u warmup_ticks=%u median_us=%.3f p95_us=%.3f maximum_us=%.3f mean_allocations=%.1f mean_allocated_bytes=%.1f peak_process_rss_kib=%ld pinned_recent_history=%zu retained_control=%d position_rows=%zu health_rows=%zu equipment_rows=%zu casting_rows=%zu appearance_rows=%zu\n",
                name.c_str(), publication->world().entities().size(), publication->world().known_slots(), measured, warmup,
                times[times.size() / 2], times[(times.size() * 95 + 99) / 100 - 1], times.back(),
                static_cast<double>(allocations) / measured, static_cast<double>(allocated_bytes) / measured, rss_kib(), history.size(), static_cast<bool>(retained_first),
                publication->world().table<Position>().stored_rows(), publication->world().table<Health>().stored_rows(),
                publication->world().table<Equipment>().stored_rows(), publication->world().table<Casting>().stored_rows(),
                publication->world().table<Appearance>().stored_rows());
    check(publication->world().entities().size() == 5000, "benchmark preserves exactly 5000 live entities");
    if (retained_first) check(retained_first->events() == Events{{1, 41}} && *retained_first->world().table<Position>().find(identity(0, 1000000000, 1)) == Position{0, 1, 2},
          "retained first snapshot has original literal state and event after workload");
    if (name == "fixed_slot_churn_5_percent" || name == "retired_slot_churn_1_percent") {
        check(*publication->world().table<Position>().find(live[0]) == Position{100, 1, 2}, "churn sample has complete literal new position");
        check(*publication->world().table<Health>().find(live[0]) == Health{50, 100, 20, 50}, "churn sample has literal new health");
        check(!publication->world().contains(identity(0, 1000000000, 1)), "churn retires original sampled handle");
    } else {
        const double expected = measured == 1000 ? 1100 : 12;
        check(*publication->world().table<Position>().find(live[0]) == Position{expected, 1, 2}, "sampled last position matches literal recorded sequence");
    }
    if (name == "sparse_10_percent") check(*publication->world().table<Position>().find(live[4999]) == Position{0, 1, 2}, "sparse workload preserves omitted sample");
    if (name == "full_components") {
        check(*publication->world().table<Health>().find(live[0]) == Health{70, 100, 30, 50}, "full fixture health replacement");
        check(*publication->world().table<Equipment>().find(live[0]) == Equipment{{9, 8, 7, 6, 5, 4, 3, 2}, "fixture replacement equipment 32"}, "full fixture equipment replacement");
        check(*publication->world().table<Casting>().find(live[0]) == Casting{std::nullopt}, "full fixture clears optional casting");
        check(*publication->world().table<Appearance>().find(live[0]) == Appearance{"fixture replacement appearance32", 12}, "full fixture appearance replacement");
    }
    check(publication->events() == Events{{warmup + measured + 1, 42}, {warmup + measured, 71}}, "benchmark event bundle preserves literal tags and order");
    if (pinned_history) {
        check(history.size() == 8, "bounded history pins exactly eight recent publications");
        check(*history.front()->world().table<Position>().find(live[0]) == Position{measured == 1000 ? 1093.0 : 5.0, 1, 2}, "oldest bounded history value remains readable");
    }
}

}

int main(int argc, char** argv) {
    const bool extended = argc == 2 && std::string(argv[1]) == "--extended";
#ifdef NDEBUG
    const char* mode = "Release";
#else
    const char* mode = "Debug-or-unoptimized";
#endif
    const auto fixture = entry(Player{1, 1}, 0);
    const auto& equipment = *std::get<std::optional<Equipment>>(fixture.values);
    const auto& appearance = *std::get<std::optional<Appearance>>(fixture.values);
    std::printf("compiler=%s mode=%s cpu=%s extended=%d\n", __VERSION__, mode, cpu_name().c_str(), extended);
    std::printf("fixture_only=1 production_equivalence=0 entities=5000 kinds=4 position_size=%zu health_size=%zu equipment_size=%zu casting_size=%zu appearance_size=%zu equipment_label_bytes=%zu appearance_name_bytes=%zu optional_position_size=%zu optional_health_size=%zu optional_equipment_size=%zu optional_casting_size=%zu optional_appearance_size=%zu event_size=%zu batch_events=2\n",
                sizeof(Position), sizeof(Health), sizeof(Equipment), sizeof(Casting), sizeof(Appearance), equipment.label.size(), appearance.name.size(),
                sizeof(std::optional<Position>), sizeof(std::optional<Health>), sizeof(std::optional<Equipment>), sizeof(std::optional<Casting>), sizeof(std::optional<Appearance>), sizeof(Event));
    const unsigned warmup = extended ? 100 : 2;
    const unsigned measured = extended ? 1000 : 10;
    std::printf("workloads_run_in_isolated_child_processes=1 allocation_bytes_are_total_requests_not_retained_or_copied_bytes=1\n");
    std::fflush(nullptr);
    for (const auto* name : {"transform_all", "sparse_10_percent", "full_components", "fixed_slot_churn_5_percent", "retired_slot_churn_1_percent", "pinned_history"}) {
        const auto child = fork();
        if (child == 0) {
            workload(name, warmup, measured, std::string(name) == "pinned_history");
            const int result = marque::test::check_finish();
            std::fflush(nullptr);
            _exit(result);
        }
        int status = 0;
        const auto waited = child > 0 ? waitpid(child, &status, 0) : -1;
        check(waited == child && child > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, name);
        std::fflush(nullptr);
    }
    return marque::test::check_finish();
}
