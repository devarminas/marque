#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "check.hpp"
#include "marque/netsim/profile.hpp"
#include "marque/netsim/seed.hpp"
#include "marque/netsim/simulator.hpp"
#include "marque/transport/endpoint.hpp"

namespace {

namespace tr = marque::transport;
namespace ns = marque::netsim;

constexpr std::uint64_t kTestHash = 0x0123456789abcdef;
constexpr std::uint64_t kTick = 40'000;
constexpr std::uint64_t kSeed = 352;

class GoPcg {
public:
    GoPcg(std::uint64_t seed1, std::uint64_t seed2) : hi_(seed1), lo_(seed2) {}

    std::uint64_t uint64() {
        constexpr std::uint64_t mul_hi = 2549297995355413924ULL;
        constexpr std::uint64_t mul_lo = 4865540595714422341ULL;
        constexpr std::uint64_t inc_hi = 6364136223846793005ULL;
        constexpr std::uint64_t inc_lo = 1442695040888963407ULL;
        unsigned __int128 wide = static_cast<unsigned __int128>(lo_) * mul_lo;
        std::uint64_t hi = static_cast<std::uint64_t>(wide >> 64) + hi_ * mul_lo + lo_ * mul_hi;
        std::uint64_t lo = static_cast<std::uint64_t>(wide);
        std::uint64_t sum_lo = lo + inc_lo;
        hi += inc_hi + (sum_lo < lo ? 1 : 0);
        lo_ = sum_lo;
        hi_ = hi;

        constexpr std::uint64_t cheap_mul = 0xda942042e4dd58b5ULL;
        hi ^= hi >> 32;
        hi *= cheap_mul;
        hi ^= hi >> 48;
        hi *= (sum_lo | 1);
        return hi;
    }

    std::uint32_t uint32() { return static_cast<std::uint32_t>(uint64() >> 32); }

    std::uint64_t int_n(std::uint64_t n) {
        if ((n & (n - 1)) == 0) {
            return uint64() & (n - 1);
        }
        auto mul = [n](std::uint64_t x) { return static_cast<unsigned __int128>(x) * n; };
        unsigned __int128 p = mul(uint64());
        if (static_cast<std::uint64_t>(p) < n) {
            std::uint64_t thresh = (0 - n) % n;
            while (static_cast<std::uint64_t>(p) < thresh) {
                p = mul(uint64());
            }
        }
        return static_cast<std::uint64_t>(p >> 64);
    }

private:
    std::uint64_t hi_;
    std::uint64_t lo_;
};

struct Side {
    tr::Endpoint ep;
    ns::Direction dir;
    std::vector<std::vector<std::uint8_t>> reliable;
    std::vector<std::uint32_t> stamps;
    int datagrams = 0;
    bool reading = true;
};

tr::Endpoint must_endpoint(tr::Role role) {
    auto e = tr::Endpoint::create(role, tr::default_config(kTestHash), std::make_shared<tr::Plain>(), 0);
    if (!e) {
        std::fprintf(stderr, "config refused: %s\n", tr::to_string(e.error()));
        std::abort();
    }
    return std::move(*e);
}

tr::Flushed must_flush(tr::Endpoint& ep, std::uint64_t now, const tr::Unreliable& u) {
    auto f = ep.flush(now, u);
    if (!f) {
        std::fprintf(stderr, "flush refused: %s\n", tr::to_string(f.error()));
        std::abort();
    }
    return std::move(*f);
}

struct Session {
    std::string profile;
    std::uint64_t seed;
    ns::Simulator sim;
    Side srv;
    Side cli;
    std::uint64_t now = 0;

    Session(const std::string& name, std::uint64_t s)
        : profile(name),
          seed(s),
          sim(ns::profile_by_name(name), s),
          srv{must_endpoint(tr::Role::server), ns::Direction::kAToB, {}, {}, 0, true},
          cli{must_endpoint(tr::Role::client), ns::Direction::kBToA, {}, {}, 0, true} {}

    Side& peer_of(Side& x) { return &x == &srv ? cli : srv; }

    std::string tag(const std::string& what) const {
        return "seed=" + std::to_string(seed) + " profile=" + profile + ": " + what;
    }

    void step(const tr::Unreliable& srv_u, const tr::Unreliable& cli_u) {
        now += kTick;
        for (Side* x : {&srv, &cli}) {
            for (auto& d : sim.poll(peer_of(*x).dir, now)) {
                if (!x->reading) {
                    continue;
                }
                auto r = x->ep.receive(d.packet, now);
                if (!r) {
                    continue;
                }
                for (auto& m : r->reliable) {
                    x->reliable.push_back(std::move(m));
                }
                if (r->unreliable) {
                    x->stamps.push_back(r->unreliable->stamp);
                }
            }
        }
        for (auto [x, u] : {std::pair{&srv, &srv_u}, std::pair{&cli, &cli_u}}) {
            for (auto& d : must_flush(x->ep, now, *u).datagrams) {
                ++x->datagrams;
                sim.send(x->dir, std::move(d), now);
            }
        }
    }
};

std::vector<std::uint8_t> message(GoPcg& r, std::uint32_t i) {
    std::uint64_t n = 4 + r.int_n(200);
    if (r.int_n(10) == 0) {
        n = tr::kFragmentSize + 1 + r.int_n(4 * tr::kFragmentSize);
    }
    std::vector<std::uint8_t> b(n);
    for (int k = 0; k < 4; ++k) {
        b[k] = static_cast<std::uint8_t>(i >> (8 * k));
    }
    for (std::size_t j = 4; j < n; ++j) {
        b[j] = static_cast<std::uint8_t>(r.uint32());
    }
    return b;
}

void reliable_exactly_once_in_order(const std::string& profile, const std::string& want) {
    Session s(profile, ns::seed_from_env(kSeed));
    GoPcg r(352, 1);
    constexpr std::size_t per_side = 3000;
    std::vector<std::vector<std::uint8_t>> want_events;
    std::vector<std::vector<std::uint8_t>> want_intents;
    int fragmented = 0;
    for (std::uint32_t i = 0; i < per_side; ++i) {
        auto e = message(r, i);
        auto in = message(r, i);
        fragmented += (e.size() > tr::kFragmentSize) + (in.size() > tr::kFragmentSize);
        want_events.push_back(std::move(e));
        want_intents.push_back(std::move(in));
    }
    std::size_t ticks = 0;
    bool sends_ok = true;
    while (s.cli.reliable.size() < per_side || s.srv.reliable.size() < per_side) {
        if (ticks >= 5000) {
            break;
        }
        for (std::size_t k = 0; k < 2 && ticks * 2 + k < per_side; ++k) {
            sends_ok = s.srv.ep.send(want_events[ticks * 2 + k]).has_value() && sends_ok;
            sends_ok = s.cli.ep.send(want_intents[ticks * 2 + k]).has_value() && sends_ok;
        }
        s.step({}, {});
        ++ticks;
    }
    marque::test::check(sends_ok, s.tag("every reliable send accepted").c_str());
    marque::test::check(s.cli.reliable == want_events, s.tag("client gets 3000 events exactly once in order").c_str());
    marque::test::check(s.srv.reliable == want_intents, s.tag("server gets 3000 intents exactly once in order").c_str());
    std::string got = "ticks=" + std::to_string(ticks) + " fragmented=" + std::to_string(fragmented) +
                      " srv_datagrams=" + std::to_string(s.srv.datagrams) +
                      " cli_datagrams=" + std::to_string(s.cli.datagrams);
    if (got != want) {
        std::printf("got  %s\nwant %s\n", got.c_str(), want.c_str());
    }
    marque::test::check(got == want, s.tag(want).c_str());
}

tr::Unreliable state_items(std::uint32_t n) {
    auto b = static_cast<std::uint8_t>(n);
    return tr::Unreliable{.stamp = n, .items = {{b, 1}, {b, 2, 3}}};
}

void stale_unreliable_dropped(const std::string& profile, const std::string& want) {
    Session s(profile, ns::seed_from_env(kSeed));
    for (std::uint32_t n = 1; n <= 2000; ++n) {
        auto u = state_items(n);
        s.step(u, u);
    }
    bool increasing = true;
    for (Side* x : {&s.cli, &s.srv}) {
        for (std::size_t i = 1; i < x->stamps.size(); ++i) {
            increasing = increasing && x->stamps[i] > x->stamps[i - 1];
        }
    }
    marque::test::check(increasing, s.tag("delivered stamps strictly increase").c_str());
    std::string got = "cli got=" + std::to_string(s.cli.stamps.size()) +
                      " stale=" + std::to_string(s.cli.ep.stats().stale) +
                      " srv got=" + std::to_string(s.srv.stamps.size()) +
                      " stale=" + std::to_string(s.srv.ep.stats().stale);
    if (got != want) {
        std::printf("got  %s\nwant %s\n", got.c_str(), want.c_str());
    }
    marque::test::check(got == want, s.tag(want).c_str());
}

void stopped_reader_triggers_slow_client(const std::string& profile, const std::string& want) {
    Session s(profile, ns::seed_from_env(kSeed));
    std::uint32_t sent = 0;
    std::string got = "no slow_client";
    for (int n = 1; n <= 2000; ++n) {
        if (n == 100) {
            s.cli.reading = false;
        }
        for (int k = 0; k < 12; ++k) {
            std::vector<std::uint8_t> msg{static_cast<std::uint8_t>(sent), static_cast<std::uint8_t>(sent >> 8),
                                          static_cast<std::uint8_t>(sent >> 16), static_cast<std::uint8_t>(sent >> 24)};
            if (s.srv.ep.send(msg)) {
                ++sent;
            }
        }
        s.step({}, {});
        if (s.srv.ep.state() == tr::State::slow_client) {
            got = "tick=" + std::to_string(n) + " backlog=" + std::to_string(s.srv.ep.backlog()) +
                  " sent=" + std::to_string(sent);
            break;
        }
    }
    if (got != want) {
        std::printf("got  %s\nwant %s\n", got.c_str(), want.c_str());
    }
    marque::test::check(got == want, s.tag(want).c_str());
}

void silence_keepalives_then_timeout(const std::string& profile, std::uint64_t timeout_at) {
    Session s(profile, ns::seed_from_env(kSeed));
    for (int n = 0; n < 25; ++n) {
        s.step({}, {});
    }
    std::string keepalives = std::to_string(s.srv.datagrams) + " " + std::to_string(s.cli.datagrams);
    marque::test::check(keepalives == "8 8", s.tag("8 keepalives per side in 1 s, got " + keepalives).c_str());

    std::optional<std::uint64_t> timed_out;
    while (s.now < 10'000'000 && !timed_out) {
        s.now += kTick;
        for (auto& d : s.sim.poll(s.cli.dir, s.now)) {
            (void)s.srv.ep.receive(d.packet, s.now);
        }
        if (must_flush(s.srv.ep, s.now, {}).state == tr::State::timed_out) {
            timed_out = s.now;
        }
    }
    std::string got = timed_out ? std::to_string(*timed_out) : "never";
    marque::test::check(got == std::to_string(timeout_at), s.tag("server times out at " + std::to_string(timeout_at) +
                                                                    ", got " + got)
                                                               .c_str());
}

}

int main() {
    reliable_exactly_once_in_order("lossy_5pct", "ticks=1501 fragmented=591 srv_datagrams=2307 cli_datagrams=2237");
    reliable_exactly_once_in_order("bad_wifi", "ticks=1507 fragmented=591 srv_datagrams=3498 cli_datagrams=3394");
    stale_unreliable_dropped("lossy_5pct", "cli got=1904 stale=0 srv got=1912 stale=0");
    stale_unreliable_dropped("bad_wifi", "cli got=1607 stale=93 srv got=1611 stale=119");
    stopped_reader_triggers_slow_client("lossy_5pct", "tick=184 backlog=0 sent=2201");
    stopped_reader_triggers_slow_client("bad_wifi", "tick=179 backlog=0 sent=2141");
    silence_keepalives_then_timeout("lossy_5pct", 6'000'000);
    silence_keepalives_then_timeout("bad_wifi", 6'080'000);
    return marque::test::check_finish();
}
