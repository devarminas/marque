#include "check.hpp"

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>

using marque::test::check;
int main() {
    std::string path = (std::filesystem::temp_directory_path() /
                        "marque_prediction_const_XXXXXX")
                           .string();
    if (!mkdtemp(path.data())) {
        check(false, "private compiler directory");
        return marque::test::check_finish();
    }
    const std::filesystem::path directory = path;
    const auto include =
        std::filesystem::path(__FILE__).parent_path() / "../include";
    const char *configured = std::getenv("CXX");
    const std::string compiler = configured && *configured ? configured : "c++";
    struct Case {
        const char *name;
        const char *body;
        const char *diagnostic;
    };
    const Case cases[]{
        {"positive",
         "auto pinned=p.pose(); const auto x=pinned->state.x; return x;",
         nullptr},
        {"state_write", "p.pose()->state.x=9; return 0;", "const"},
        {"policy_mode_write",
         "p.pose()->mode=marque::motion::PredictionMode::ended; return 0;",
         "const"},
        {"writer_copy", "auto second=p; return second.pose()->state.x;",
         "private"},
        {"writer_prepare", "auto second=p.prepare(b); return 0;", "private"},
        {"writer_reset_prepare", "auto second=p.prepare_reset(b, *marque::wire::ResetCertificate::build({}), 2, 3); return 0;", "private"},
        {"history_write", "p.records_[0].input.jump=true; return 0;",
         "private"}};
    for (const auto &test : cases) {
        const auto source = directory / (std::string(test.name) + ".cpp");
        std::ofstream(source)
            << "#include \"marque/motion/prediction.hpp\"\ndouble "
               "probe(marque::motion::Prediction& p, const marque::motion::PublishedBaseline& b) {(void)b;"
            << test.body << "}\n";
        const std::string command =
            compiler + " -std=c++23 -Wall -Wextra -Werror -fsyntax-only -I'" +
            include.string() + "' '" + source.string() + "' 2>&1";
        FILE *pipe = popen(command.c_str(), "r");
        if (!pipe) {
            check(false, "compiler launch");
            continue;
        }
        std::string output;
        char buffer[1024];
        while (std::fgets(buffer, sizeof buffer, pipe))
            output += buffer;
        const auto status = pclose(pipe);
        if (test.diagnostic) {
            check(status != 0, test.name);
            check(output.find(test.diagnostic) != std::string::npos ||
                      output.find("read-only") != std::string::npos,
                  "failure identifies forbidden prediction mutation or writer "
                  "copy");
        } else
            check(status == 0, "positive pinned pose reader control compiles");
        if (status == 0 && test.diagnostic)
            std::printf("unexpected compiled mutation %s\n", test.name);
        if (status != 0 && !test.diagnostic)
            std::printf("%s", output.c_str());
    }
    std::filesystem::remove_all(directory);
    return marque::test::check_finish();
}
