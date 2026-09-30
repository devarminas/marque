// Proves the generated types refuse misuse at compile time. An NpcId cannot
// stand in for a PlayerId, and a built message's fields cannot be written.
// Each bad snippet differs from the good one in one line, so its failure can
// only come from that line. The compiler is $CXX, or c++ when CXX is unset.

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

Result compile(const std::filesystem::path& dir, const std::string& name, const std::string& kind,
               const std::string& extra) {
    const auto src = dir / (name + ".cpp");
    std::ofstream(src) << "#include \"marque/wire/gen/schema.hpp\"\n"
                          "int main() {\n"
                          "    marque::wire::" << kind << " id{1, 1};\n"
                          "    marque::wire::HpFields f;\n"
                          "    f.id = id;\n"
                          "    auto hp = marque::wire::Hp::build(f);\n"
                       << extra
                       << "    return hp ? static_cast<int>(hp->id().index) : 1;\n"
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
    const auto ok = compile(dir, "ok", "PlayerId", "");
    check(ok.status == 0, "Hp built from a PlayerId compiles");
    if (ok.status != 0) std::printf("%s", ok.output.c_str());

    const auto wrong = compile(dir, "wrong", "NpcId", "");
    check(wrong.status != 0, "Hp built from an NpcId does not compile");
    check(wrong.output.find("NpcId") != std::string::npos && wrong.output.find("PlayerId") != std::string::npos,
          "the compile error names NpcId and PlayerId");
    std::printf("%s", wrong.output.c_str());

    const auto mutate = compile(dir, "mutate", "PlayerId", "    hp->f_.hp = 2;\n");
    check(mutate.status != 0, "writing a built Hp's field does not compile");
    check(mutate.output.find("f_") != std::string::npos && mutate.output.find("private") != std::string::npos,
          "the compile error says the fields are private");
    std::printf("%s", mutate.output.c_str());
    std::filesystem::remove_all(dir);
    return marque::test::check_finish();
}
