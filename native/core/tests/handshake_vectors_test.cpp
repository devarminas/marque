#include <cstdint>
#include <cstdio>
#include <deque>
#include <map>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "check.hpp"
#include "marque/transport/handshake.hpp"
#include "marque/transport/session_seal.hpp"
#include "vector_script.hpp"

namespace marque::transport {

struct GateRandom {
    static void fix(Gate& g, const Key& challenge_key, std::deque<std::uint8_t>& queue) {
        g.challenge_key_ = challenge_key;
        g.random_ = [&queue](std::span<std::uint8_t> out) {
            if (queue.size() < out.size()) {
                throw std::runtime_error("random queue ran dry");
            }
            for (auto& b : out) {
                b = queue.front();
                queue.pop_front();
            }
        };
    }
};

}

namespace {

namespace tr = marque::transport;
using marque::test::hex;
using marque::test::number;
using marque::test::unhex;

template <std::size_t N>
std::array<std::uint8_t, N> fixed(std::string_view h) {
    auto b = unhex(h);
    if (b.size() != N) {
        throw std::runtime_error("want " + std::to_string(N) + " bytes: " + std::string(h));
    }
    std::array<std::uint8_t, N> out{};
    std::ranges::copy(b, out.begin());
    return out;
}

tr::Address address(std::string_view h) {
    auto b = fixed<tr::kAddressSize>(h);
    tr::Address a;
    std::copy_n(b.begin(), 16, a.ip.begin());
    a.port = static_cast<std::uint16_t>(b[16] | b[17] << 8);
    return a;
}

std::string address_hex(const tr::Address& a) {
    std::vector<std::uint8_t> b(a.ip.begin(), a.ip.end());
    b.push_back(static_cast<std::uint8_t>(a.port));
    b.push_back(static_cast<std::uint8_t>(a.port >> 8));
    return hex(b);
}

tr::ConnectToken token(std::string_view h) {
    auto t = tr::ConnectToken::parse(unhex(h));
    if (!t) {
        throw std::runtime_error("bad token " + std::string(h));
    }
    return *t;
}

struct Run {
    std::optional<tr::Gate> gate;
    std::deque<std::uint8_t> random;
    std::map<std::string, tr::SessionSeal, std::less<>> seals;

    std::vector<std::string> op(std::string_view line) {
        auto f = marque::test::fields(line);
        std::vector<std::string> out;
        if (f[0] == "token") {
            tr::Grant g{.account = number(f[3]),
                        .session = number(f[4]),
                        .shard = address(f[5]),
                        .expires = number(f[6]),
                        .keys = {fixed<tr::kKeySize>(f[7]), fixed<tr::kKeySize>(f[8])}};
            out.push_back("token " +
                          hex(tr::issue_token(fixed<tr::kKeySize>(f[1]), fixed<tr::kTokenNonceSize>(f[2]), g).bytes()));
        } else if (f[0] == "gate") {
            gate.emplace(tr::GateConfig{
                .schema_hash = number(f[1], 16), .shard = address(f[2]), .issuer = fixed<tr::kKeySize>(f[3])});
            tr::GateRandom::fix(*gate, fixed<tr::kKeySize>(f[4]), random);
        } else if (f[0] == "random") {
            auto b = unhex(f[1]);
            random.insert(random.end(), b.begin(), b.end());
        } else if (f[0] == "request") {
            out.push_back("request " + hex(token(f[2]).request(number(f[1], 16))));
        } else if (f[0] == "respond") {
            auto r = token(f[1]).respond(unhex(f[2]));
            out.push_back(r ? "response " + hex(*r) : std::string("error ") + tr::to_string(r.error()));
        } else if (f[0] == "handle") {
            auto o = gate->handle(address(f[2]), unhex(f[3]), number(f[1]));
            if (!o) {
                out.push_back(std::string("error ") + tr::to_string(o.error()));
            } else if (auto* c = std::get_if<tr::Challenge>(&*o)) {
                out.push_back("challenge " + hex(c->bytes));
            } else {
                const auto& a = std::get<tr::Admission>(*o);
                out.push_back("admitted " + address_hex(a.peer) + " " + std::to_string(a.account) + " " +
                              std::to_string(a.session) + " " + std::to_string(a.expires) + " " +
                              hex(a.keys.client_to_server) + " " + hex(a.keys.server_to_client));
            }
            out.push_back("admissions " + std::to_string(gate->admissions()));
        } else if (f[0] == "session") {
            auto role = f[1] == "client" ? tr::Role::client : tr::Role::server;
            seals.insert_or_assign(std::string(f[1]),
                                   tr::session_seal(role, {fixed<tr::kKeySize>(f[2]), fixed<tr::kKeySize>(f[3])}));
        } else if (f[0] == "seal_body") {
            std::vector<std::uint8_t> sealed;
            seals.find(f[1])->second.sealer->seal(unhex(f[2]), unhex(f[3]), sealed);
            out.push_back("sealed " + hex(sealed));
        } else if (f[0] == "open_body") {
            std::vector<std::uint8_t> body;
            bool ok = seals.find(f[1])->second.opener->open(unhex(f[2]), unhex(f[3]), body);
            out.push_back(ok ? "opened " + hex(body) : std::string("error malformed"));
        } else {
            throw std::runtime_error("unknown op " + std::string(f[0]));
        }
        return out;
    }
};

}

int main() {
    using marque::test::check;
    auto files = marque::test::vector_files("handshake");
    check(files.size() == 5, "shared/wire/vectors/handshake holds the 5 vector files transport.md lists");
    for (const auto& p : files) {
        Run run;
        auto r = marque::test::replay(p, [&](std::string_view line) { return run.op(line); });
        std::string what = p.filename().string() + ": " + std::to_string(r.ops) + " ops, " +
                           std::to_string(r.expected) + " expected lines match";
        if (!r.failure.empty()) {
            std::printf("%s\n", r.failure.c_str());
        }
        check(r.failure.empty() && r.ops > 0, what.c_str());
    }
    return marque::test::check_finish();
}
