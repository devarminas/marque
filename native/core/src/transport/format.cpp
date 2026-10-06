#include "format.hpp"

namespace marque::transport {

const char* to_string(Error e) {
    switch (e) {
    case Error::malformed:
        return "malformed";
    case Error::foreign:
        return "foreign";
    case Error::duplicate:
        return "duplicate";
    case Error::too_old:
        return "too_old";
    case Error::closed:
        return "closed";
    case Error::message:
        return "message";
    case Error::item:
        return "item";
    }
    return "error?";
}

const char* to_string(Role r) { return r == Role::server ? "server" : "client"; }

}

namespace marque::transport::format {

namespace {

void put_u16(std::vector<std::uint8_t>& out, std::uint16_t v) {
    out.push_back(static_cast<std::uint8_t>(v));
    out.push_back(static_cast<std::uint8_t>(v >> 8));
}

void put_u32(std::vector<std::uint8_t>& out, std::uint32_t v) {
    for (int shift = 0; shift < 32; shift += 8) {
        out.push_back(static_cast<std::uint8_t>(v >> shift));
    }
}

void put_u64(std::vector<std::uint8_t>& out, std::uint64_t v) {
    for (int shift = 0; shift < 64; shift += 8) {
        out.push_back(static_cast<std::uint8_t>(v >> shift));
    }
}

void put_length(std::vector<std::uint8_t>& out, std::size_t n) {
    if (n < 0x80) {
        out.push_back(static_cast<std::uint8_t>(n));
        return;
    }
    out.push_back(static_cast<std::uint8_t>(n | 0x80));
    out.push_back(static_cast<std::uint8_t>(n >> 7));
}

void put_sized(std::vector<std::uint8_t>& out, std::span<const std::uint8_t> bytes) {
    put_length(out, bytes.size());
    out.insert(out.end(), bytes.begin(), bytes.end());
}

std::uint64_t load_le(std::span<const std::uint8_t> b) {
    std::uint64_t v = 0;
    for (std::size_t i = b.size(); i > 0; --i) {
        v = v << 8 | b[i - 1];
    }
    return v;
}

class Parser {
public:
    explicit Parser(std::span<const std::uint8_t> b) : b_(b) {}

    bool ok() const { return ok_; }

    bool empty() const { return b_.empty(); }

    std::uint8_t peek() const { return b_.front(); }

    void fail() {
        ok_ = false;
        b_ = {};
    }

    std::span<const std::uint8_t> take(std::size_t n) {
        if (!ok_) {
            return {};
        }
        if (b_.size() < n) {
            fail();
            return {};
        }
        auto v = b_.first(n);
        b_ = b_.subspan(n);
        return v;
    }

    std::uint8_t u8() { return static_cast<std::uint8_t>(load_le(take(1))); }

    std::uint16_t u16() { return static_cast<std::uint16_t>(load_le(take(2))); }

    std::uint32_t u32() { return static_cast<std::uint32_t>(load_le(take(4))); }

    std::span<const std::uint8_t> sized() {
        std::uint8_t first = u8();
        std::size_t n = first;
        if (first & 0x80) {
            std::uint8_t second = u8();
            if (second == 0 || (second & 0x80)) {
                fail();
                return {};
            }
            n = static_cast<std::size_t>(first & 0x7f) | static_cast<std::size_t>(second) << 7;
        }
        if (ok_ && n == 0) {
            fail();
            return {};
        }
        return take(n);
    }

private:
    std::span<const std::uint8_t> b_;
    bool ok_ = true;
};

bool fragment_rules_hold(const Entry& e) {
    if (e.count == 0 || e.count > kMaxFragments) {
        return false;
    }
    if (e.index >= e.count) {
        return false;
    }
    if (e.data.size() > kFragmentSize) {
        return false;
    }
    return e.index == e.count - 1 || e.data.size() == kFragmentSize;
}

}

void put_header(std::vector<std::uint8_t>& out, const Header& h) {
    put_u32(out, h.protocol);
    put_u64(out, h.hash);
    put_u16(out, h.seq);
    put_u16(out, h.ack.latest);
    put_u32(out, h.ack.bits);
}

Header read_header(std::span<const std::uint8_t> d) {
    return Header{
        .protocol = static_cast<std::uint32_t>(load_le(d.subspan(0, 4))),
        .hash = load_le(d.subspan(4, 8)),
        .seq = static_cast<std::uint16_t>(load_le(d.subspan(12, 2))),
        .ack = AckWindow{
            .latest = static_cast<std::uint16_t>(load_le(d.subspan(14, 2))),
            .bits = static_cast<std::uint32_t>(load_le(d.subspan(16, 4))),
        },
    };
}

void put_body(std::vector<std::uint8_t>& out, Role from, std::uint32_t stamp,
              std::span<const std::vector<std::uint8_t>> items, std::span<const Entry> entries) {
    if (!items.empty()) {
        out.push_back(static_cast<std::uint8_t>(unreliable_channel(from)));
        put_u32(out, stamp);
        put_u16(out, static_cast<std::uint16_t>(items.size()));
        for (const auto& item : items) {
            put_sized(out, item);
        }
    }
    if (!entries.empty()) {
        out.push_back(static_cast<std::uint8_t>(reliable_channel(from)));
        put_u16(out, static_cast<std::uint16_t>(entries.size()));
        for (const auto& e : entries) {
            put_u16(out, e.id);
            out.push_back(e.index);
            out.push_back(e.count);
            put_sized(out, e.data);
        }
    }
}

std::optional<Body> parse_body(std::span<const std::uint8_t> bytes, Role from) {
    Parser p(bytes);
    Body out;
    if (!p.empty() && p.peek() == static_cast<std::uint8_t>(unreliable_channel(from))) {
        p.take(1);
        UnreliableSection u{.stamp = p.u32(), .items = {}};
        std::uint16_t n = p.u16();
        if (p.ok() && n == 0) {
            p.fail();
        }
        for (std::uint16_t i = 0; i < n && p.ok(); ++i) {
            u.items.push_back(p.sized());
        }
        out.unreliable = std::move(u);
    }
    if (p.ok() && !p.empty() && p.peek() == static_cast<std::uint8_t>(reliable_channel(from))) {
        p.take(1);
        std::uint16_t n = p.u16();
        if (p.ok() && n == 0) {
            p.fail();
        }
        for (std::uint16_t i = 0; i < n && p.ok(); ++i) {
            Entry e{.id = p.u16(), .index = p.u8(), .count = p.u8(), .data = {}};
            e.data = p.sized();
            if (!p.ok()) {
                break;
            }
            if (!fragment_rules_hold(e)) {
                p.fail();
                break;
            }
            out.entries.push_back(e);
        }
    }
    if (p.ok() && !p.empty()) {
        p.fail();
    }
    if (!p.ok()) {
        return std::nullopt;
    }
    return out;
}

}
