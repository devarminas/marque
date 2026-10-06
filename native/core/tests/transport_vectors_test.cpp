#include <algorithm>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include "check.hpp"
#include "marque/transport/endpoint.hpp"

namespace marque::transport {

struct StartAt {
    static void apply(Endpoint& e, std::uint16_t seq, std::uint16_t send_id, std::uint16_t recv_id) {
        e.tx_.next_seq_ = seq;
        e.tx_.front_ = send_id;
        e.rx_.next_ = recv_id;
    }
};

}

namespace {

using marque::transport::Endpoint;
using marque::transport::Unreliable;
namespace tr = marque::transport;

class TestSeal final : public tr::Seal {
public:
    std::size_t overhead() const override { return 4; }

    void seal(std::span<const std::uint8_t> header, std::span<const std::uint8_t> body,
              std::vector<std::uint8_t>& out) override {
        for (auto b : body) {
            out.push_back(b ^ 0xa5);
        }
        std::uint32_t tag = sum(header) + sum(body);
        for (int shift = 0; shift < 32; shift += 8) {
            out.push_back(static_cast<std::uint8_t>(tag >> shift));
        }
    }

    bool open(std::span<const std::uint8_t> header, std::span<const std::uint8_t> sealed,
              std::vector<std::uint8_t>& out) override {
        if (sealed.size() < 4) {
            return false;
        }
        std::size_t start = out.size();
        for (auto b : sealed.first(sealed.size() - 4)) {
            out.push_back(b ^ 0xa5);
        }
        auto tail = sealed.last(4);
        std::uint32_t tag = tail[0] | tail[1] << 8 | tail[2] << 16 | static_cast<std::uint32_t>(tail[3]) << 24;
        if (tag != sum(header) + sum(std::span(out).subspan(start))) {
            out.resize(start);
            return false;
        }
        return true;
    }

private:
    static std::uint32_t sum(std::span<const std::uint8_t> b) {
        std::uint32_t n = 0;
        for (auto x : b) {
            n += x;
        }
        return n;
    }
};

std::vector<std::string_view> fields(std::string_view line) {
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

std::uint64_t number(std::string_view s, int base = 10) {
    std::uint64_t v = 0;
    auto [ptr, ec] = std::from_chars(s.data(), s.data() + s.size(), v, base);
    if (ec != std::errc{} || ptr != s.data() + s.size()) {
        throw std::runtime_error("bad number " + std::string(s));
    }
    return v;
}

std::vector<std::uint8_t> unhex(std::string_view s) {
    if (s.size() % 2 != 0) {
        throw std::runtime_error("odd hex " + std::string(s));
    }
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i < s.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(number(s.substr(i, 2), 16)));
    }
    return out;
}

std::string hex(std::span<const std::uint8_t> b) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string out;
    for (auto x : b) {
        out += digits[x >> 4];
        out += digits[x & 0xf];
    }
    return out;
}

std::vector<std::string> run_op(std::optional<Endpoint>& ep, std::string_view line) {
    auto f = fields(line);
    std::vector<std::string> out;
    if (f[0] == "endpoint") {
        if (f.size() != 12) {
            throw std::runtime_error("endpoint takes 11 fields");
        }
        auto role = f[1] == "client" ? tr::Role::client : tr::Role::server;
        auto cfg = tr::default_config(number(f[2], 16));
        cfg.tick_budget = number(f[3]);
        cfg.backlog_limit = number(f[4]);
        cfg.backlog_bytes = number(f[5]);
        cfg.resend_after = number(f[6]);
        if (f[7] == "test") {
            cfg.seal = std::make_shared<TestSeal>();
        } else if (f[7] != "plain") {
            throw std::runtime_error("unknown seal " + std::string(f[7]));
        }
        auto e = Endpoint::create(role, cfg, number(f[11]));
        if (!e) {
            throw std::runtime_error(std::string("config refused: ") + tr::to_string(e.error()));
        }
        tr::StartAt::apply(*e, static_cast<std::uint16_t>(number(f[8])), static_cast<std::uint16_t>(number(f[9])),
                           static_cast<std::uint16_t>(number(f[10])));
        ep.emplace(std::move(*e));
    } else if (f[0] == "send") {
        auto msg = unhex(f[1]);
        if (auto r = ep->send(msg); !r) {
            out.push_back(std::string("error ") + tr::to_string(r.error()));
        }
    } else if (f[0] == "flush") {
        Unreliable u;
        if (f.size() > 2) {
            u.stamp = static_cast<std::uint32_t>(number(f[2]));
            for (std::size_t i = 3; i < f.size(); ++i) {
                u.items.push_back(unhex(f[i]));
            }
        }
        auto r = ep->flush(number(f[1]), u);
        if (!r) {
            out.push_back(std::string("error ") + tr::to_string(r.error()));
            return out;
        }
        for (const auto& d : r->datagrams) {
            out.push_back("datagram " + hex(d));
        }
        if (!u.items.empty()) {
            out.push_back("unreliable_sent " + std::to_string(r->unreliable_sent));
        }
        if (r->state != tr::State::open) {
            out.push_back(std::string("state ") + tr::to_string(r->state));
        }
    } else if (f[0] == "recv") {
        auto d = unhex(f[2]);
        auto r = ep->receive(d, number(f[1]));
        if (!r) {
            out.push_back(std::string("error ") + tr::to_string(r.error()));
            return out;
        }
        if (r->stale) {
            out.push_back("stale");
        }
        if (r->unreliable) {
            std::string l = "unreliable " + std::to_string(r->unreliable->stamp);
            for (const auto& item : r->unreliable->items) {
                l += " " + hex(item);
            }
            out.push_back(l);
        }
        for (const auto& m : r->reliable) {
            out.push_back("reliable " + hex(m));
        }
    } else {
        throw std::runtime_error("unknown op " + std::string(f[0]));
    }
    return out;
}

struct Replay {
    int ops = 0;
    int expected = 0;
    std::string failure;
};

Replay replay(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    Replay result;
    if (!in) {
        result.failure = "cannot open";
        return result;
    }
    std::optional<Endpoint> ep;
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
            got = run_op(ep, line);
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

std::filesystem::path vector_dir() {
    return std::filesystem::path(__FILE__).parent_path() / ".." / ".." / ".." / "shared" / "wire" / "vectors" /
           "transport";
}

}

int main() {
    using marque::test::check;
    std::vector<std::filesystem::path> files;
    for (const auto& entry : std::filesystem::directory_iterator(vector_dir())) {
        if (entry.path().extension() == ".vec") {
            files.push_back(entry.path());
        }
    }
    std::ranges::sort(files);
    check(files.size() == 19, "shared/wire/vectors/transport holds the 19 vector files transport.md lists");
    for (const auto& p : files) {
        auto r = replay(p);
        std::string what = p.filename().string() + ": " + std::to_string(r.ops) + " ops, " +
                           std::to_string(r.expected) + " expected lines match";
        if (!r.failure.empty()) {
            std::printf("%s\n", r.failure.c_str());
        }
        check(r.failure.empty() && r.ops > 0, what.c_str());
    }
    return marque::test::check_finish();
}
