#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "marque/netsim/profile.hpp"

namespace marque::netsim {

// golden_lines runs count packets through a fresh Simulator on the AToB
// direction, seeded and profiled as given, and returns one formatted line
// per packet in send-index order:
//
//   "<index> DROP"
//   "<index> DELIVER <at>"
//   "<index> DUPLICATE <at1> <at2>"
//
// Mirrors server/internal/netsim/golden.go's GoldenLines. The Go test
// compares that function's output to the committed golden file; the C++
// test compares this function's output to the same file, which is the
// cross-language proof that both implementations agree.
std::vector<std::string> golden_lines(const Profile& profile, std::uint64_t seed, int count);

}  // namespace marque::netsim
