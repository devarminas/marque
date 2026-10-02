#include "marque/wire/codec.hpp"

#include <bit>
#include <charconv>
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
    case Error::rule: return "value breaks a schema rule";
    }
    return "unknown error";
}

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
    if (writing()) out_->push_back(v);
}

void Writer::u16(std::uint16_t v) { fixed(v, 2); }
void Writer::u32(std::uint32_t v) { fixed(v, 4); }
void Writer::u64(std::uint64_t v) { fixed(v, 8); }

void Writer::fixed(std::uint64_t v, int width) {
    if (!writing()) return;
    for (int i = 0; i < width; ++i) {
        out_->push_back(static_cast<std::uint8_t>(v >> (8 * i)));
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
    if (!writing()) return;
    while (v >= 0x80) {
        out_->push_back(static_cast<std::uint8_t>(v | 0x80));
        v >>= 7;
    }
    out_->push_back(static_cast<std::uint8_t>(v));
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
    if (writing()) out_->insert(out_->end(), s.begin(), s.end());
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
    fixed(q.step(v), q.width);
}

std::uint64_t Quant::step(double v) const {
    return static_cast<std::uint64_t>(std::round(v * per_unit) - min * per_unit);
}

double Quant::value(std::uint64_t n) const { return (static_cast<double>(n) + min * per_unit) / per_unit; }

double Quant::snap(double v) const {
    const double r = std::round(v * per_unit);
    if (!(r >= min * per_unit && r <= max * per_unit)) return v;
    return value(step(v));
}

std::expected<void, Error> Writer::finish() {
    if (err_) {
        if (out_ != nullptr) out_->resize(start_);
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
    return q.value(n);
}

std::optional<Error> Reader::finish() {
    if (!err_ && !buf_.empty()) err_ = Error::trailing;
    return err_;
}

namespace {

template <typename F>
void text_float(std::string& out, F v) {
    char buf[64];
    const auto res = std::to_chars(buf, buf + sizeof buf, v, std::chars_format::scientific);
    std::string_view sci(buf, static_cast<std::size_t>(res.ptr - buf));
    if (sci.front() == '-') {
        out += '-';
        sci.remove_prefix(1);
    }
    const auto e = sci.find('e');
    std::string digits;
    for (char c : sci.substr(0, e)) {
        if (c != '.') digits += c;
    }
    auto exp_text = sci.substr(e + 1);
    if (exp_text.front() == '+') exp_text.remove_prefix(1);
    int exp = 0;
    std::from_chars(exp_text.data(), exp_text.data() + exp_text.size(), exp);

    const int nd = static_cast<int>(digits.size());
    if (exp < -4 || exp >= 6) {
        out += digits[0];
        if (nd > 1) {
            out += '.';
            out.append(digits, 1);
        }
        out += exp < 0 ? "e-" : "e+";
        const int mag = exp < 0 ? -exp : exp;
        if (mag < 10) out += '0';
        out += std::to_string(mag);
        return;
    }
    const int dp = exp + 1;
    if (dp > 0) {
        for (int i = 0; i < dp; ++i) out += i < nd ? digits[static_cast<std::size_t>(i)] : '0';
    } else {
        out += '0';
    }
    if (nd > dp) {
        out += '.';
        for (int j = dp; j < nd; ++j) out += j >= 0 ? digits[static_cast<std::size_t>(j)] : '0';
    }
}

void hex_digits(std::string& out, std::uint32_t v, int n) {
    static constexpr char digits[] = "0123456789abcdef";
    for (int i = n - 1; i >= 0; --i) out += digits[(v >> (4 * i)) & 0xf];
}

}

void text_f64(std::string& out, double v) { text_float(out, v); }
void text_f32(std::string& out, float v) { text_float(out, v); }

void text_quoted(std::string& out, std::string_view s) {
    out += '"';
    for (std::size_t i = 0; i < s.size();) {
        const auto c = static_cast<unsigned char>(s[i]);
        const std::size_t len = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        std::uint32_t r = len == 1 ? c : c & (0x7f >> len);
        for (std::size_t k = 1; k < len && i + k < s.size(); ++k) {
            r = (r << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3f);
        }
        i += len;
        if (r == '"' || r == '\\') {
            out += '\\';
            out += static_cast<char>(r);
        } else if (r >= 0x20 && r < 0x7f) {
            out += static_cast<char>(r);
        } else if (r == '\a') {
            out += "\\a";
        } else if (r == '\b') {
            out += "\\b";
        } else if (r == '\f') {
            out += "\\f";
        } else if (r == '\n') {
            out += "\\n";
        } else if (r == '\r') {
            out += "\\r";
        } else if (r == '\t') {
            out += "\\t";
        } else if (r == '\v') {
            out += "\\v";
        } else if (r < 0x20 || r == 0x7f) {
            out += "\\x";
            hex_digits(out, r, 2);
        } else if (r < 0x10000) {
            out += "\\u";
            hex_digits(out, r, 4);
        } else {
            out += "\\U";
            hex_digits(out, r, 8);
        }
    }
    out += '"';
}

}
