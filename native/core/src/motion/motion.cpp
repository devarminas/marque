#include "marque/motion/motion.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace marque::motion {

Mesh::Mesh(std::vector<Vec3> vertices,
           std::vector<std::array<std::uint32_t, 3>> triangles)
    : vertices_(std::move(vertices)), triangles_(std::move(triangles)) {}
std::expected<std::shared_ptr<const Mesh>, MeshError>
Mesh::create(std::vector<Vec3> vertices,
             std::vector<std::array<std::uint32_t, 3>> triangles) {
    for (const auto &v : vertices)
        if (!std::isfinite(v.x) || !std::isfinite(v.y) || !std::isfinite(v.z))
            return std::unexpected(MeshError::nonfinite);
    for (const auto &t : triangles)
        for (auto index : t)
            if (index >= vertices.size())
                return std::unexpected(MeshError::index);
    return std::shared_ptr<const Mesh>(
        new Mesh(std::move(vertices), std::move(triangles)));
}
std::optional<double> Mesh::height_at(double x, double z, double near_y) const {
    std::optional<double> best;
    double best_distance = std::numeric_limits<double>::infinity();
    for (const auto &t : triangles_) {
        const auto a = vertices_[t[0]], b = vertices_[t[1]],
                   c = vertices_[t[2]];
        const double v0x = b.x - a.x, v0z = b.z - a.z, v1x = c.x - a.x,
                     v1z = c.z - a.z, v2x = x - a.x, v2z = z - a.z;
        const double den = v0x * v1z - v1x * v0z;
        if (std::abs(den) < 1e-12)
            continue;
        const double v = (v2x * v1z - v1x * v2z) / den,
                     w = (v0x * v2z - v2x * v0z) / den, u = 1 - v - w;
        if (u < -1e-9 || v < -1e-9 || w < -1e-9)
            continue;
        const double y = u * a.y + v * b.y + w * c.y,
                     distance = std::abs(y - near_y);
        if (!best || distance < best_distance) {
            best = y;
            best_distance = distance;
        }
    }
    return best;
}
bool Mesh::contains(double x, double z) const {
    return height_at(x, z, 0).has_value();
}
std::pair<double, double> Mesh::move(double from_x, double from_z, double to_x,
                                     double to_z) const {
    if (!contains(from_x, from_z))
        return contains(to_x, to_z) ? std::pair{to_x, to_z}
                                    : std::pair{from_x, from_z};
    const double dx = to_x - from_x, dz = to_z - from_z,
                 distance = std::hypot(dx, dz);
    if (distance < 1e-12)
        return {from_x, from_z};
    const int subdivisions =
        static_cast<int>(std::clamp(distance * 8, 24.0, 512.0));
    double last_on = 0;
    for (int i = 1; i <= subdivisions; ++i) {
        const double t = static_cast<double>(i) / subdivisions;
        if (contains(from_x + dx * t, from_z + dz * t)) {
            last_on = t;
            continue;
        }
        double lo = last_on, hi = t;
        for (int j = 0; j < 24; ++j) {
            const double mid = (lo + hi) * 0.5;
            if (contains(from_x + dx * mid, from_z + dz * mid))
                lo = mid;
            else
                hi = mid;
        }
        return {from_x + dx * lo, from_z + dz * lo};
    }
    return {to_x, to_z};
}
double Map::ground(double x, double z, double near_y) const {
    if (mesh)
        if (auto y = mesh->height_at(x, z, near_y))
            return *y;
    return ground_y;
}
bool grounded(const State &s, const Map &map) {
    return s.y <= map.ground(s.x, s.z, s.y) + ground_epsilon && s.vy <= 0;
}
std::pair<double, double> normalize(double dx, double dz) {
    const double length = std::hypot(dx, dz);
    if (length < steer_epsilon)
        return {0, 0};
    return {dx / length, dz / length};
}
std::pair<State, bool> jump(State s, const Map &map) {
    if (!grounded(s, map))
        return {s, false};
    s.vy = jump_speed;
    return {s, true};
}
Applied apply(State s, const Map &map, Policy policy, Input input,
              std::uint32_t tick) {
    bool accepted = true;
    if (input.jump) {
        auto result = jump(s, map);
        s = result.first;
        accepted = result.second;
    }
    const auto [dx, dz] = normalize(input.dx, input.dz);
    if ((dx == 0 && dz == 0) ||
        (policy.mode == Mode::rooted && tick < policy.end_tick)) {
        s.dx = s.dz = 0;
        return {s, policy, accepted};
    }
    if (policy.mode == Mode::interrupt_on_move &&
        static_cast<std::uint64_t>(policy.end_tick) >
            static_cast<std::uint64_t>(tick) + grace_ticks)
        policy = {};
    s.dx = dx;
    s.dz = dz;
    return {s, policy, accepted};
}
std::pair<State, bool> horizontal(State s, const Map &map, double distance) {
    double x = std::clamp(s.x + s.dx * distance, -map.half_extent,
                          map.half_extent),
           z = std::clamp(s.z + s.dz * distance, -map.half_extent,
                          map.half_extent);
    if (map.mesh) {
        auto moved = map.mesh->move(s.x, s.z, x, z);
        x = moved.first;
        z = moved.second;
    }
    if (std::hypot(x - s.x, z - s.z) < min_distance)
        return {s, false};
    if (grounded(s, map)) {
        const double y = map.ground(x, z, s.y);
        if (map.mesh && std::abs(y - s.y) > max_step_height)
            return {s, false};
        s.y = y;
    }
    s.x = x;
    s.z = z;
    return {s, true};
}
std::pair<State, bool> vertical(State s, const Map &map, double dt) {
    const double gy = map.ground(s.x, s.z, s.y);
    if (grounded(s, map)) {
        s.y = gy;
        s.vy = 0;
        return {s, false};
    }
    s.vy -= gravity * dt;
    s.y += s.vy * dt;
    if (s.y <= gy) {
        s.y = gy;
        s.vy = 0;
    }
    return {s, true};
}
State step(State s, const Map &map, double dt) {
    if (s.dx != 0 || s.dz != 0)
        s = horizontal(s, map, walk_speed * dt).first;
    return vertical(s, map, dt).first;
}

}
