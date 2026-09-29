#include "marque/wire/codec.hpp"

#include <bit>
#include <cmath>

namespace marque::wire::codec {

const char* to_string(Error e) {
    switch (e) {
    case Error::truncated: return "truncated";
    case Error::trailing: return "trailing bytes";
    case Error::unknown_message: return "unknown message id";
    case Error::over_bound: return "string or list over its bound";
    case Error::non_finite: return "non-finite number";
    case Error::out_of_range: return "quantized value out of range";
    case Error::bad_bool: return "bool byte not 0 or 1";
    case Error::bad_enum: return "unknown enum value";
    case Error::bad_varint: return "overlong or oversized varint";
    case Error::bad_utf8: return "string is not valid UTF-8";
    }
    return "unknown error";
}

// Accepts exactly what Go's utf8.Valid accepts: no overlong forms, no
// surrogates, nothing above U+10FFFF.
bool valid_utf8(std::string_view s) {
    std::size_t i = 0;
    while (i < s.size()) {
        const auto c = static_cast<unsigned char>(s[i]);
        std::size_t len = 0;
        unsigned char lo = 0x80;
        unsigned char hi = 0xbf;
        if (c < 0x80) {
            ++i;
            continue;
        } else if (c >= 0xc2 && c <= 0xdf) {
            len = 2;
        } else if (c >= 0xe0 && c <= 0xef) {
            len = 3;
            if (c == 0xe0) lo = 0xa0;
            if (c == 0xed) hi = 0x9f;
        } else if (c >= 0xf0 && c <= 0xf4) {
            len = 4;
            if (c == 0xf0) lo = 0x90;
            if (c == 0xf4) hi = 0x8f;
        } else {
            return false;
        }
        if (i + len > s.size()) return false;
        const auto c1 = static_cast<unsigned char>(s[i + 1]);
        if (c1 < lo || c1 > hi) return false;
        for (std::size_t k = 2; k < len; ++k) {
            const auto ck = static_cast<unsigned char>(s[i + k]);
            if (ck < 0x80 || ck > 0xbf) return false;
        }
        i += len;
    }
    return true;
}

void Writer::fail(Error e) {
    if (!err_) err_ = e;
}

void Writer::u8(std::uint8_t v) {
    if (!err_) out_.push_back(v);
}

void Writer::u16(std::uint16_t v) { fixed(v, 2); }
void Writer::u32(std::uint32_t v) { fixed(v, 4); }
void Writer::u64(std::uint64_t v) { fixed(v, 8); }

void Writer::fixed(std::uint64_t v, int width) {
    if (err_) return;
    for (int i = 0; i < width; ++i) {
        out_.push_back(static_cast<std::uint8_t>(v >> (8 * i)));
    }
}

void Writer::f32(float v) {
    if (!std::isfinite(v)) {
        fail(Error::non_finite);
        return;
    }
    u32(std::bit_cast<std::uint32_t>(v));
}

void Writer::varint(std::uint32_t v) {
    if (err_) return;
    while (v >= 0x80) {
        out_.push_back(static_cast<std::uint8_t>(v | 0x80));
        v >>= 7;
    }
    out_.push_back(static_cast<std::uint8_t>(v));
}

void Writer::count(std::size_t n, std::size_t bound) {
    if (n > bound) {
        fail(Error::over_bound);
        return;
    }
    varint(static_cast<std::uint32_t>(n));
}

void Writer::string(std::string_view s, std::size_t bound) {
    if (!valid_utf8(s)) {
        fail(Error::bad_utf8);
        return;
    }
    count(s.size(), bound);
    if (!err_) out_.insert(out_.end(), s.begin(), s.end());
}

void Writer::quant(double v, const Quant& q) {
    if (!std::isfinite(v)) {
        fail(Error::non_finite);
        return;
    }
    if (v < q.min || v > q.max) {
        fail(Error::out_of_range);
        return;
    }
    fixed(static_cast<std::uint64_t>(std::round(v * q.per_unit) - q.min * q.per_unit), q.width);
}

std::expected<void, Error> Writer::finish() {
    if (err_) {
        out_.resize(start_);
        return std::unexpected(*err_);
    }
    return {};
}

void Reader::fail(Error e) {
    if (!err_) err_ = e;
}

std::span<const std::uint8_t> Reader::take(std::size_t n) {
    if (err_) return {};
    if (buf_.size() < n) {
        fail(Error::truncated);
        return {};
    }
    auto out = buf_.first(n);
    buf_ = buf_.subspan(n);
    return out;
}

std::uint64_t Reader::fixed(int width) {
    auto b = take(static_cast<std::size_t>(width));
    std::uint64_t v = 0;
    for (std::size_t i = 0; i < b.size(); ++i) {
        v |= static_cast<std::uint64_t>(b[i]) << (8 * i);
    }
    return v;
}

std::uint8_t Reader::u8() { return static_cast<std::uint8_t>(fixed(1)); }
std::uint16_t Reader::u16() { return static_cast<std::uint16_t>(fixed(2)); }
std::uint32_t Reader::u32() { return static_cast<std::uint32_t>(fixed(4)); }
std::uint64_t Reader::u64() { return fixed(8); }

bool Reader::boolean() {
    const auto b = u8();
    if (b > 1) fail(Error::bad_bool);
    return b == 1;
}

float Reader::f32() {
    const auto v = std::bit_cast<float>(u32());
    if (!std::isfinite(v)) {
        fail(Error::non_finite);
        return 0;
    }
    return v;
}

// Rejects overlong forms so every value has exactly one encoding.
std::uint32_t Reader::varint() {
    std::uint32_t v = 0;
    for (int i = 0; i < 5; ++i) {
        auto b = take(1);
        if (b.empty()) return 0;
        const std::uint8_t c = b[0];
        if (i == 4 && c > 0x0f) {
            fail(Error::bad_varint);
            return 0;
        }
        v |= static_cast<std::uint32_t>(c & 0x7f) << (7 * i);
        if (c < 0x80) {
            if (c == 0 && i > 0) {
                fail(Error::bad_varint);
                return 0;
            }
            return v;
        }
    }
    fail(Error::bad_varint);
    return 0;
}

std::size_t Reader::count(std::size_t bound, std::size_t min_elem) {
    const std::uint64_t n = varint();
    if (!err_ && n > bound) fail(Error::over_bound);
    if (!err_ && n * min_elem > buf_.size()) fail(Error::truncated);
    return err_ ? 0 : static_cast<std::size_t>(n);
}

std::string Reader::string(std::size_t bound) {
    auto b = take(count(bound, 1));
    if (err_) return {};
    std::string s(b.begin(), b.end());
    if (!valid_utf8(s)) {
        fail(Error::bad_utf8);
        return {};
    }
    return s;
}

double Reader::quant(const Quant& q) {
    const auto n = fixed(q.width);
    if (!err_ && n > q.steps) fail(Error::out_of_range);
    if (err_) return 0;
    return (static_cast<double>(n) + q.min * q.per_unit) / q.per_unit;
}

std::optional<Error> Reader::finish() {
    if (!err_ && !buf_.empty()) err_ = Error::trailing;
    return err_;
}

}
