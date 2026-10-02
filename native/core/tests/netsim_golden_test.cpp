#include "marque/netsim/golden.hpp"
#include "marque/netsim/profile.hpp"
#include "marque/netsim/seed.hpp"

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "check.hpp"

constexpr std::uint64_t kGoldenSeed = 424242;
constexpr int kGoldenVectorCount = 1000;

namespace {

std::filesystem::path golden_dir_four_levels_above_this_source_file() {
    return std::filesystem::path(__FILE__).parent_path() / ".." / ".." / ".." / "shared" / "wire" /
           "vectors" / "netsim";
}

bool check_profile(const char* name, const marque::netsim::Profile& profile, std::uint64_t seed) {
    auto lines = marque::netsim::golden_lines(profile, seed, kGoldenVectorCount);
    std::string got;
    for (auto& l : lines) {
        got += l;
        got += '\n';
    }

    std::filesystem::path path = golden_dir_four_levels_above_this_source_file() / (std::string(name) + ".golden");
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        std::fprintf(stderr, "seed=%llu profile=%s: could not open golden file %s\n",
                     static_cast<unsigned long long>(seed), name, path.string().c_str());
        return false;
    }
    std::ostringstream want_stream;
    want_stream << in.rdbuf();
    std::string want = want_stream.str();

    bool matches = got == want;
    if (!matches) {
        std::fprintf(stderr,
                      "seed=%llu profile=%s: fate sequence does not match %s\n"
                      "got (first line): %s\nwant (first line): %s\n",
                      static_cast<unsigned long long>(seed), name, path.string().c_str(),
                      lines.empty() ? "" : lines[0].c_str(), want.substr(0, want.find('\n')).c_str());
    }
    return matches;
}

}

int main() {
    using marque::test::check;
    using namespace marque::netsim;

    std::uint64_t seed = seed_from_env(kGoldenSeed);

    check(check_profile("clean", kClean, seed), "clean golden vector matches Go's");
    check(check_profile("lossy_5pct", kLossy5Pct, seed), "lossy_5pct golden vector matches Go's");
    check(check_profile("bad_wifi", kBadWifi, seed), "bad_wifi golden vector matches Go's");

    return marque::test::check_finish();
}
