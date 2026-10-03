#pragma once

#include <array>
#include <cstdint>
#include <expected>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace marque::motion {

inline constexpr double walk_speed = 3, jump_speed = 5, gravity = 20;
inline constexpr double steer_epsilon = 1e-6, ground_epsilon = 1e-4,
                        min_distance = 1e-3, max_step_height = 0.75;
inline constexpr std::uint32_t grace_ticks = 8;

struct Vec3 {
    double x, y, z;
};
enum class MeshError { nonfinite, index };
class Mesh {
    std::vector<Vec3> vertices_;
    std::vector<std::array<std::uint32_t, 3>> triangles_;
    Mesh(std::vector<Vec3> vertices,
         std::vector<std::array<std::uint32_t, 3>> triangles);

  public:
    static std::expected<std::shared_ptr<const Mesh>, MeshError>
    create(std::vector<Vec3> vertices,
           std::vector<std::array<std::uint32_t, 3>> triangles);
    std::optional<double> height_at(double x, double z, double near_y) const;
    bool contains(double x, double z) const;
    std::pair<double, double> move(double from_x, double from_z, double to_x,
                                   double to_z) const;
};
struct State {
    double x = 0, y = 0, z = 0, vy = 0, dx = 0, dz = 0;
    bool operator==(const State &) const = default;
};
struct Map {
    double half_extent = 128, ground_y = 0;
    std::shared_ptr<const Mesh> mesh;
    double ground(double x, double z, double near_y) const;
};
enum class Mode : std::uint8_t { free, rooted, interrupt_on_move };
struct Policy {
    Mode mode = Mode::free;
    std::uint32_t end_tick = 0;
    bool operator==(const Policy &) const = default;
};
struct Input {
    double dx = 0, dz = 0;
    bool jump = false;
};
struct Applied {
    State state;
    Policy policy;
    bool jump_accepted;
};

bool grounded(const State &s, const Map &map);
std::pair<double, double> normalize(double dx, double dz);
std::pair<State, bool> jump(State s, const Map &map);
Applied apply(State s, const Map &map, Policy policy, Input input,
              std::uint32_t tick);
std::pair<State, bool> horizontal(State s, const Map &map, double distance);
std::pair<State, bool> vertical(State s, const Map &map, double dt);
State step(State s, const Map &map, double dt);

}
