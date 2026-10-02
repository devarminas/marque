#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace marque::wire::codec {

enum class Channel : std::uint8_t { state = 1, events, input, intents };

enum class Error : std::uint8_t {
    truncated,
    trailing,
    unknown_message,
    over_bound,
    non_finite,
    out_of_range,
    bad_bool,
    bad_enum,
    bad_varint,
    bad_utf8,
    rule,
};

const char* to_string(Error e);

struct Quant {
    double min;
    double max;
    double per_unit;
    std::uint64_t steps;
    int width;

    std::uint64_t step(double v) const;
    double value(std::uint64_t n) const;
    double snap(double v) const;
};

class Writer {
public:
    Writer() = default;
    explicit Writer(std::vector<std::uint8_t>& out) : out_(&out), start_(out.size()) {}

    void fail(Error e);
    std::optional<Error> error() const { return err_; }
    void u8(std::uint8_t v);
    void u16(std::uint16_t v);
    void u32(std::uint32_t v);
    void u64(std::uint64_t v);
    void boolean(bool v) { u8(v ? 1 : 0); }
    void f32(float v);
    void varint(std::uint32_t v);
    void count(std::size_t n, std::size_t bound);
    void string(std::string_view s, std::size_t bound);
    void quant(double v, const Quant& q);

    std::expected<void, Error> finish();

private:
    bool writing() const { return !err_ && out_ != nullptr; }
    void fixed(std::uint64_t v, int width);

    std::vector<std::uint8_t>* out_ = nullptr;
    std::size_t start_ = 0;
    std::optional<Error> err_;
};

class Reader {
public:
    explicit Reader(std::span<const std::uint8_t> bytes) : buf_(bytes) {}

    void fail(Error e);
    std::optional<Error> error() const { return err_; }
    std::size_t remaining() const { return buf_.size(); }
    std::uint8_t u8();
    std::uint16_t u16();
    std::uint32_t u32();
    std::uint64_t u64();
    bool boolean();
    float f32();
    std::uint32_t varint();
    std::size_t count(std::size_t bound, std::size_t min_elem);
    std::string string(std::size_t bound);
    double quant(const Quant& q);

    std::optional<Error> finish();

private:
    std::span<const std::uint8_t> take(std::size_t n);
    std::uint64_t fixed(int width);

    std::span<const std::uint8_t> buf_;
    std::optional<Error> err_;
};

bool valid_utf8(std::string_view s);

template <typename Equal>
bool unique(std::size_t n, Equal equal) {
    for (std::size_t i = 1; i < n; ++i) {
        for (std::size_t j = 0; j < i; ++j) {
            if (equal(i, j)) return false;
        }
    }
    return true;
}

void text_f64(std::string& out, double v);
void text_f32(std::string& out, float v);
void text_quoted(std::string& out, std::string_view s);

}
