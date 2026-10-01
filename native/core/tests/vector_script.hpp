#pragma once

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace marque::test {

inline std::vector<std::string_view> fields(std::string_view line) {
    std::vector<std::string_view> out;
    while (!line.empty()) {
        auto sp = line.find(' ');
        out.push_back(line.substr(0, sp));
        if (sp == std::string_view::npos) {
            break;
        }
        line.remove_prefix(sp + 1);
    }
    return out;
}

inline std::uint64_t number(std::string_view s, int base = 10) {
    std::uint64_t v = 0;
    auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), v, base);
    if (ec != std::errc{} || ptr != s.data() + s.size()) {
        throw std::runtime_error("bad number " + std::string(s));
    }
    return v;
}

inline std::vector<std::uint8_t> unhex(std::string_view s) {
    if (s.size() % 2 != 0) {
        throw std::runtime_error("odd hex " + std::string(s));
    }
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i < s.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(number(s.substr(i, 2), 16)));
    }
    return out;
}

inline std::string hex(std::span<const std::uint8_t> b) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string out;
    for (auto x : b) {
        out += digits[x >> 4];
        out += digits[x & 0xf];
    }
    return out;
}

struct Replay {
    int ops = 0;
    int expected = 0;
    std::string failure;
};

using OpRunner = std::function<std::vector<std::string>(std::string_view)>;

inline Replay replay(const std::filesystem::path& path, const OpRunner& run) {
    std::ifstream in(path, std::ios::binary);
    Replay result;
    if (!in) {
        result.failure = "cannot open";
        return result;
    }
    std::vector<std::string> got;
    std::vector<std::string> want;
    int line_no = 0;
    auto compare = [&](int at) {
        if (got == want) {
            return true;
        }
        std::ostringstream msg;
        msg << "before line " << at << "\ngot:\n";
        for (const auto& g : got) {
            msg << g << "\n";
        }
        msg << "want:\n";
        for (const auto& w : want) {
            msg << w << "\n";
        }
        result.failure = msg.str();
        return false;
    };
    std::string line;
    try {
        while (std::getline(in, line)) {
            ++line_no;
            if (line.empty() || line.starts_with("#")) {
                continue;
            }
            if (line.starts_with("> ")) {
                want.push_back(line.substr(2));
                ++result.expected;
                continue;
            }
            if (!compare(line_no)) {
                return result;
            }
            got = run(line);
            want.clear();
            ++result.ops;
        }
    } catch (const std::exception& e) {
        result.failure = "line " + std::to_string(line_no) + ": " + e.what();
        return result;
    }
    compare(line_no + 1);
    return result;
}

inline std::filesystem::path vector_dir(std::string_view name) {
    return std::filesystem::path(__FILE__).parent_path() / ".." / ".." / ".." / "shared" / "wire" / "vectors" / name;
}

inline std::vector<std::filesystem::path> vector_files(std::string_view name) {
    std::vector<std::filesystem::path> files;
    for (const auto& entry : std::filesystem::directory_iterator(vector_dir(name))) {
        if (entry.path().extension() == ".vec") {
            files.push_back(entry.path());
        }
    }
    std::ranges::sort(files);
    return files;
}

}
