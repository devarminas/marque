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
};

const char* to_string(Error e);

struct Quant {
    double min;
    double max;
    double per_unit;
    std::uint64_t steps;
    int width;
};

class Writer {
public:
    explicit Writer(std::vector<std::uint8_t>& out) : out_(out), start_(out.size()) {}

    void fail(Error e);
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
    void fixed(std::uint64_t v, int width);

    std::vector<std::uint8_t>& out_;
    std::size_t start_;
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

}
