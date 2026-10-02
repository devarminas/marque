#include "check.hpp"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

using marque::test::check;

struct Result { int status; std::string output; };

Result compile(const std::filesystem::path& dir, const std::string& name, const std::string& expression) {
    const auto source = dir / (name + ".cpp");
    std::ofstream(source) << "#include \"world_fixture/types.hpp\"\n"
                            "using namespace world_fixture;\n"
                            "int main() { auto applier = *World::create(); auto reader = applier.reader();\n"
                         << expression << "\nreturn 0; }\n";
    const char* env = std::getenv("CXX");
    const std::string compiler = env && *env ? env : "c++";
    const auto tests = std::filesystem::path(__FILE__).parent_path();
    const std::string command = compiler + " -std=c++23 -Wall -Wextra -Werror -fsyntax-only -I'" +
        (tests / "../include").string() + "' -I'" + tests.string() + "' '" + source.string() + "' 2>&1";
    Result result{-1, {}};
    FILE* pipe = popen(command.c_str(), "r");
    if (!pipe) return result;
    char buffer[1024];
    while (std::fgets(buffer, sizeof buffer, pipe)) result.output += buffer;
    result.status = pclose(pipe);
    return result;
}

int main() {
    std::string pattern = (std::filesystem::temp_directory_path() / "marque_world_const_XXXXXX").string();
    if (!mkdtemp(pattern.data())) {
        check(false, "private compiler temp directory");
        return marque::test::check_finish();
    }
    const std::filesystem::path directory = pattern;
    const auto positive = compile(directory, "positive", "auto pinned = reader.latest(); auto table = pinned->world().table<Position>(); const Position* p = table.find(Player{7,3}); auto frame = reader.render_at({1000000}); return p ? static_cast<int>(p->x) : (frame ? 0 : 1);");
    check(positive.status == 0, "positive public reader control compiles");
    if (positive.status) std::printf("%s", positive.output.c_str());
    struct Negative { const char* name; const char* expression; const char* diagnostic; };
    const std::vector<Negative> negatives{
        {"find", "reader.latest()->world().table<Position>().find(Player{7,3})->x = 8;", "read-only"},
        {"column_values", "reader.latest()->world().table<Position>().values()[0]->x = 8;", "read-only"},
        {"members", "reader.latest()->world().entities()[0] = Player{8,3};", "const"},
        {"events", "reader.latest()->events()[0].marker = 8;", "read-only"},
        {"slot", "reader.slot_.reset();", "private"},
        {"storage", "reader.latest()->world().data_.reset();", "private"},
        {"construct", "Snapshot<Catalog> made{nullptr};", "private"},
        {"column_write", "reader.latest()->world().table<Position>().write(Player{7,3}, Position{8,1,2});", "write"},
        {"copy_writer", "auto second_writer = applier;", "deleted"},
        {"typed_handle", "Player player = Npc{7,3}; return static_cast<int>(player.index);", "conversion"}
    };
    for (const auto& negative : negatives) {
        const auto result = compile(directory, negative.name, negative.expression);
        check(result.status != 0, negative.name);
        bool reason = result.output.find(negative.diagnostic) != std::string::npos;
        if (std::string(negative.diagnostic) == "read-only") reason |= result.output.find("const") != std::string::npos;
        check(reason, "compiler diagnostic identifies intended const, private, deleted, or typed operation");
        std::printf("case=%s\n%s", negative.name, result.output.c_str());
    }
    std::filesystem::remove_all(directory);
    return marque::test::check_finish();
}
