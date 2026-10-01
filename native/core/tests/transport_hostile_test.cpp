#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "check.hpp"
#include "marque/transport/endpoint.hpp"

namespace {

namespace tr = marque::transport;
using marque::test::check;

constexpr std::string_view kClientSeq0 = "4d525131" "efcdab8967452301" "0000" "ffff" "00000000";

std::vector<std::uint8_t> unhex(std::string_view s) {
    auto nibble = [](char c) { return static_cast<std::uint8_t>(c <= '9' ? c - '0' : c - 'a' + 10); };
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i + 1 < s.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(nibble(s[i]) << 4 | nibble(s[i + 1])));
    }
    return out;
}

std::vector<std::uint8_t> datagram(std::string_view header, std::string_view body) {
    return unhex(std::string(header) + std::string(body));
}

std::string header(std::uint16_t seq) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string h = "4d525131efcdab8967452301";
    h += digits[(seq >> 4) & 0xf];
    h += digits[seq & 0xf];
    h += digits[(seq >> 12) & 0xf];
    h += digits[(seq >> 8) & 0xf];
    return h + "ffff00000000";
}

tr::Endpoint server() {
    auto e = tr::Endpoint::create(tr::Role::server, tr::default_config(0x0123456789abcdef),
                                  std::make_shared<tr::Plain>(), 0);
    if (!e) {
        std::abort();
    }
    return std::move(*e);
}

std::string outcome(tr::Endpoint& ep, const std::vector<std::uint8_t>& d) {
    auto r = ep.receive(d, 1000);
    if (!r) {
        return std::string("error ") + tr::to_string(r.error());
    }
    std::string out = "accepted";
    for (const auto& m : r->reliable) {
        out += " reliable ";
        for (auto b : m) {
            static constexpr char digits[] = "0123456789abcdef";
            out += digits[b >> 4];
            out += digits[b & 0xf];
        }
    }
    return out;
}

void refused_datagrams_change_nothing() {
    auto ep = server();
    struct Case {
        const char* what;
        std::vector<std::uint8_t> d;
        const char* want;
    };
    std::vector<std::uint8_t> oversized = datagram(kClientSeq0, "");
    oversized.resize(1201, 0);
    Case cases[] = {
        {"19-byte datagram", unhex("4d525131efcdab89674523010000ffff000000"), "error malformed"},
        {"empty datagram", {}, "error malformed"},
        {"1201-byte datagram", oversized, "error malformed"},
        {"protocol id MRQ2", datagram("4d525132efcdab89674523010000ffff00000000", ""), "error foreign"},
        {"schema hash off by one", datagram("4d525131eecdab89674523010000ffff00000000", ""), "error foreign"},
        {"fragment data length 5 with 1 byte present", datagram(kClientSeq0, "04010000000001" "05aa"),
         "error malformed"},
        {"fragment count 65", datagram(kClientSeq0, "040100000000" "41" "01aa"), "error malformed"},
        {"fragment count 0", datagram(kClientSeq0, "040100000000" "00" "01aa"), "error malformed"},
        {"fragment index 1 of count 1", datagram(kClientSeq0, "0401000000" "01" "01" "01aa"), "error malformed"},
        {"non-final fragment of 1 byte", datagram(kClientSeq0, "0401000000" "00" "02" "01aa"), "error malformed"},
        {"reliable entry count 65535 with no entries", datagram(kClientSeq0, "04ffff"), "error malformed"},
        {"unreliable item count 65535 with no items", datagram(kClientSeq0, "0301000000ffff"), "error malformed"},
        {"unreliable item count 0", datagram(kClientSeq0, "03010000000000"), "error malformed"},
        {"two-byte length 0x80 0x00", datagram(kClientSeq0, "030100000001008000"), "error malformed"},
        {"server's own events channel", datagram(kClientSeq0, "020100000000" "01" "01aa"), "error malformed"},
        {"trailing byte", datagram(kClientSeq0, "04010000000001" "01aa" "00"), "error malformed"},
    };
    for (const auto& c : cases) {
        std::string got = outcome(ep, c.d);
        check(got == c.want, (std::string(c.what) + ": " + c.want + ", got " + got).c_str());
    }
    check(ep.stats() == tr::Stats{.accepted = 0, .duplicate = 0, .too_old = 0, .malformed = 14, .foreign = 2, .stale = 0},
          "refusals count 14 malformed and 2 foreign, nothing accepted");
    std::string got = outcome(ep, datagram(kClientSeq0, "04010000000001" "01aa"));
    check(got == "accepted reliable aa", ("sequence 0 and message 0 still unused after refusals, got " + got).c_str());
    check(ep.backlog() == 0 && ep.state() == tr::State::open, "refusals leave the sender open with no backlog");
}

void fragments_far_outside_the_window_are_ignored() {
    auto ep = server();
    std::string got = outcome(ep, datagram(header(0), "04010000000001" "01aa"));
    check(got == "accepted reliable aa", ("message 0 delivers, got " + got).c_str());
    got = outcome(ep, datagram(header(1), "0403000101000101bb" "0000000101dd" "409c000101ee"));
    check(got == "accepted", ("ids 257, 0 and 40000 are ignored, got " + got).c_str());
    got = outcome(ep, datagram(header(2), "040100010000" "0101cc"));
    check(got == "accepted reliable cc", ("id 1 delivers its own data, not id 257's, got " + got).c_str());
    got = outcome(ep, datagram(header(3), "0401000201" "3f" "40" "01ff"));
    check(got == "accepted", ("id 258 with count 64 is still outside the window, got " + got).c_str());
    got = outcome(ep, datagram(header(4), "040100020000" "0101dd"));
    check(got == "accepted reliable dd", ("id 2 delivers, so 258 never took its slot, got " + got).c_str());
}

void ack_window_at_exactly_32_ahead() {
    auto ep = server();
    auto ack = [&](std::uint16_t seq) {
        auto r = ep.receive(datagram(header(seq), ""), 0);
        return r ? r->own_ack : tr::AckWindow{.latest = 0, .bits = 0xdeadbeef};
    };
    check(ack(0) == tr::AckWindow{.latest = 0, .bits = 0}, "first datagram: latest 0, bits 0");
    check(ack(32) == tr::AckWindow{.latest = 32, .bits = 0x80000000}, "32 ahead: bit 31 holds sequence 0");
    check(ack(31) == tr::AckWindow{.latest = 32, .bits = 0x80000001}, "31 arrives late: bit 0 set");
    check(ack(65) == tr::AckWindow{.latest = 65, .bits = 0}, "33 ahead: bits clear");
    check(ack(32).latest == 0 && ep.stats().too_old == 1, "32 is now 33 behind: too_old");
}

void config_validation() {
    auto refuse = [](tr::Config c, std::shared_ptr<tr::Seal> seal = std::make_shared<tr::Plain>()) {
        auto e = tr::Endpoint::create(tr::Role::client, c, std::move(seal), 0);
        return e ? std::string("accepted") : std::string(tr::to_string(e.error()));
    };
    auto base = tr::default_config(1);
    auto c = base;
    check(refuse(c) == "accepted", "default config is valid");
    c.tick_budget = 1199;
    check(refuse(c) == "tick_budget_below_max_datagram", "tick budget 1199 refused");
    c = base;
    c.backlog_limit = 0;
    check(refuse(c) == "backlog_limit_out_of_range", "backlog limit 0 refused");
    c.backlog_limit = 65281;
    check(refuse(c) == "backlog_limit_out_of_range", "backlog limit 65281 refused");
    c.backlog_limit = 65280;
    check(refuse(c) == "accepted", "backlog limit 65280 accepted");
    c = base;
    c.backlog_bytes = 0;
    check(refuse(c) == "backlog_bytes_zero", "backlog bytes 0 refused");
    c = base;
    c.resend_after = 0;
    check(refuse(c) == "resend_after_zero", "resend after 0 refused");
    check(refuse(base, nullptr) == "seal_missing", "null seal refused");
}

}

int main() {
    refused_datagrams_change_nothing();
    fragments_far_outside_the_window_are_ignored();
    ack_window_at_exactly_32_ahead();
    config_validation();
    return marque::test::check_finish();
}
