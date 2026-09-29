// Proves an NpcId cannot stand in for a PlayerId: the same snippet compiles
// with a PlayerId and fails with an NpcId, and the failure names both types.
// The compiler is $CXX, or c++ when CXX is unset.

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

#include "check.hpp"

using marque::test::check;

namespace {

struct Result {
    int status;
    std::string output;
};

Result compile(const std::filesystem::path& dir, const std::string& kind) {
    const auto src = dir / (kind + ".cpp");
    std::ofstream(src) << "#include \"marque/wire/gen/schema.hpp\"\n"
                          "int main() {\n"
                          "    marque::wire::" << kind << " id{1, 1};\n"
                          "    marque::wire::Hp hp;\n"
                          "    hp.id = id;\n"
                          "    return static_cast<int>(hp.id.index);\n"
                          "}\n";
    const char* env = std::getenv("CXX");
    const std::string cxx = env != nullptr && *env != '\0' ? env : "c++";
    const auto include = std::filesystem::path(__FILE__).parent_path() / "../include";
    const std::string cmd = cxx + " -std=c++23 -Wall -Wextra -Werror -fsyntax-only -I'" + include.string() + "' '" +
                            src.string() + "' 2>&1";
    Result r{-1, {}};
    FILE* pipe = popen(cmd.c_str(), "r");
    if (pipe == nullptr) return r;
    char buf[512];
    while (std::fgets(buf, sizeof buf, pipe) != nullptr) r.output += buf;
    r.status = pclose(pipe);
    return r;
}

}

int main() {
    std::string tmpl = (std::filesystem::temp_directory_path() / "marque_wire_kind_XXXXXX").string();
    if (mkdtemp(tmpl.data()) == nullptr) {
        check(false, "create a private temp directory");
        return marque::test::check_finish();
    }
    const std::filesystem::path dir = tmpl;
    const auto ok = compile(dir, "PlayerId");
    check(ok.status == 0, "Hp built from a PlayerId compiles");
    if (ok.status != 0) std::printf("%s", ok.output.c_str());

    const auto wrong = compile(dir, "NpcId");
    check(wrong.status != 0, "Hp built from an NpcId does not compile");
    check(wrong.output.find("NpcId") != std::string::npos && wrong.output.find("PlayerId") != std::string::npos,
          "the compile error names NpcId and PlayerId");
    std::printf("%s", wrong.output.c_str());
    std::filesystem::remove_all(dir);
    return marque::test::check_finish();
}
