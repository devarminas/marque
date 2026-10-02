#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "marque/netsim/profile.hpp"

namespace marque::netsim {

std::vector<std::string> golden_lines(const Profile& profile, std::uint64_t seed, int count);

}
