#include "check.hpp"
#include "marque/motion/motion.hpp"

#include <cmath>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>

namespace mo = marque::motion;
using marque::test::check;

int main() {
    const auto root = std::filesystem::path(__FILE__)
                          .parent_path()
                          .parent_path()
                          .parent_path()
                          .parent_path();
    std::ifstream file(root / "shared/motion/meshes.txt");
    std::map<std::string, std::shared_ptr<const mo::Mesh>> meshes;
    std::string line, name;
    std::vector<mo::Vec3> vertices;
    std::vector<std::array<std::uint32_t, 3>> triangles;
    auto finish = [&] {
        if (!name.empty()) {
            auto mesh = mo::Mesh::create(vertices, triangles);
            check(mesh.has_value(), "immutable mesh accepted");
            if (mesh)
                meshes[name] = *mesh;
        }
    };
    while (std::getline(file, line)) {
        std::istringstream in(line);
        std::string tag;
        in >> tag;
        if (tag == "mesh") {
            finish();
            in >> name;
            vertices.clear();
            triangles.clear();
        } else if (tag == "v") {
            mo::Vec3 v;
            in >> v.x >> v.y >> v.z;
            vertices.push_back(v);
        } else if (tag == "t") {
            std::array<std::uint32_t, 3> t;
            in >> t[0] >> t[1] >> t[2];
            triangles.push_back(t);
        }
    }
    finish();
    check(meshes.size() == 5, "five authored mesh fixtures read");
    std::ifstream vectors(root / "shared/motion/vectors.txt");
    int count = 0;
    while (std::getline(vectors, line)) {
        std::istringstream in(line);
        std::string vector_name, map_name;
        int ticks, mode, repeat;
        std::uint32_t end;
        mo::State state, want;
        mo::Input input;
        in >> vector_name >> map_name >> ticks >> state.x >> state.y >>
            state.z >> state.vy >> state.dx >> state.dz >> input.dx >>
            input.dz >> input.jump >> mode >> end >> repeat >> want.x >>
            want.y >> want.z >> want.vy >> want.dx >> want.dz;
        check(!in.fail(), "shared literal parsed");
        mo::Map map{128, 0, nullptr};
        if (map_name != "flat")
            map.mesh = meshes.at(map_name);
        mo::Policy policy{static_cast<mo::Mode>(mode), end};
        for (int i = 0; i < ticks; ++i) {
            if (i == 0 || repeat) {
                auto result = mo::apply(state, map, policy, input, i);
                state = result.state;
                policy = result.policy;
                input.jump = false;
            }
            state = mo::step(state, map, 0.04);
        }
        const double got[]{state.x,  state.y,  state.z,
                           state.vy, state.dx, state.dz},
            expected[]{want.x, want.y, want.z, want.vy, want.dx, want.dz};
        bool match = true;
        for (int i = 0; i < 6; ++i)
            if (std::abs(got[i] - expected[i]) > (ticks > 100 ? 1e-7 : 1e-9))
                match = false;
        check(match, vector_name.c_str());
        ++count;
    }
    check(count == 20,
          "twenty literal full motion vectors including long navmesh walk");
    const auto clipped = meshes.at("hole")->move(0.5, 0.5, 2.5, 0.5);
    check(std::abs(clipped.first - 1) < 1e-9 && clipped.second == 0.5,
          "subdivision stops at hole before far island");
    const auto tie = meshes.at("stack")->height_at(0, 0, 1);
    check(tie && *tie == 0, "overlapping height tie retains first triangle");
    check(!mo::Mesh::create({{0, 0, 0}}, {{0, 1, 2}}),
          "immutable mesh rejects invalid index");
    return marque::test::check_finish();
}
