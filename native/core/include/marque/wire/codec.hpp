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
    rule,
};

const char* to_string(Error e);

// Maps a double onto 0..steps: q = round(v * per_unit) - min * per_unit.
struct Quant {
    double min;
    double max;
    double per_unit;
    std::uint64_t steps;
    int width;

    // The wire integer for v. Call it only on a finite v inside the range;
    // generated rule checks compare quants by step, never as doubles.
    std::uint64_t step(double v) const;
};

class Writer {
public:
    // A Writer made without a buffer runs every check and appends nothing, so
    // build() refuses exactly what encode() refuses.
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

    // Returns the first error and truncates out back to its starting size.
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
    // Fails with Error::truncated when n elements of at least min_elem bytes
    // each cannot fit in what remains, so a hostile count never sizes an
    // allocation.
    std::size_t count(std::size_t bound, std::size_t min_elem);
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

// Reports whether no two of n elements are equal. It compares every pair; the
// schema caps unique lists at 256 elements.
template <typename Equal>
bool unique(std::size_t n, Equal equal) {
    for (std::size_t i = 1; i < n; ++i) {
        for (std::size_t j = 0; j < i; ++j) {
            if (equal(i, j)) return false;
        }
    }
    return true;
}

// Text form helpers. Each appends exactly what the Go generated String()
// writes: strconv.AppendFloat(v, 'g', -1, 64 or 32) for numbers and
// strconv.AppendQuoteToASCII for strings.
void text_f64(std::string& out, double v);
void text_f32(std::string& out, float v);
void text_quoted(std::string& out, std::string_view s);

}
