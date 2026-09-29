#pragma once

// Hand-written runtime under the wiregen-generated message code. The byte
// rules match server/internal/wire/codec exactly: little-endian, byte-aligned,
// canonical 32-bit LEB128 varints for ids, handle parts, enums, and lengths.
// Writer and Reader keep the first error and turn every later call into a
// no-op, so generated code needs no per-field checks.

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

// Maps a double onto 0..steps: q = round(v * per_unit) - min * per_unit.
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

    // Returns the first error and truncates out back to its starting size.
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
    bool failed() const { return err_.has_value(); }
    std::uint8_t u8();
    std::uint16_t u16();
    std::uint32_t u32();
    std::uint64_t u64();
    bool boolean();
    float f32();
    std::uint32_t varint();
    std::size_t count(std::size_t bound);
    std::string string(std::size_t bound);
    double quant(const Quant& q);

    // The first error, or Error::trailing when bytes remain.
    std::optional<Error> finish();

private:
    std::span<const std::uint8_t> take(std::size_t n);
    std::uint64_t fixed(int width);

    std::span<const std::uint8_t> buf_;
    std::optional<Error> err_;
};

bool valid_utf8(std::string_view s);

}
