#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "check.hpp"
#include "marque/wire/gen/probe.hpp"
#include "marque/wire/gen/schema.hpp"

using marque::test::check;
namespace wire = marque::wire;
namespace probe = marque::wire::probe;
using wire::codec::Error;

namespace {

std::map<std::string, std::string> read_vectors(const char* file) {
    const auto path = std::filesystem::path(__FILE__).parent_path() / "../../../shared/wire/vectors" / file;
    std::ifstream in(path);
    check(in.good(), ("open " + path.string()).c_str());
    std::map<std::string, std::string> out;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream fields(line);
        std::string name, hex;
        fields >> name >> hex;
        out[name] = hex;
    }
    return out;
}

std::string to_hex(const std::vector<std::uint8_t>& bytes) {
    static const char digits[] = "0123456789abcdef";
    std::string out;
    for (auto b : bytes) {
        out += digits[b >> 4];
        out += digits[b & 0xf];
    }
    return out;
}

std::vector<std::uint8_t> from_hex(const std::string& hex) {
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(i, 2), nullptr, 16)));
    }
    return out;
}

template <typename Msg>
std::string encode_hex(const Msg& m) {
    std::vector<std::uint8_t> out;
    auto ok = wire::encode(m, out);
    check(ok.has_value(), "encode succeeds");
    return to_hex(out);
}

template <typename Msg>
std::string probe_encode_hex(const Msg& m) {
    std::vector<std::uint8_t> out;
    auto ok = probe::encode(m, out);
    check(ok.has_value(), "probe encode succeeds");
    return to_hex(out);
}

// Decodes hex and reports whether it came back as exactly want.
template <typename Msg, typename Decode>
bool round_trips(Decode decode, const std::string& hex, const Msg& want) {
    auto got = decode(from_hex(hex));
    return got.has_value() && std::holds_alternative<Msg>(*got) && std::get<Msg>(*got) == want;
}

template <typename Decode>
bool rejects(Decode decode, const std::string& hex, Error want) {
    auto got = decode(from_hex(hex));
    return !got.has_value() && got.error() == want;
}

const wire::Input input_value{.dx = 0.5, .dz = -1, .jump = true, .seq = 300};
const wire::Pose pose_value{.id = {7, 2}, .x = 12.34, .y = 0.5, .z = -100.25};
const wire::Hp hp_value{.id = {7, 2}, .hp = 85, .max_hp = 120};
const wire::Refused refused_value{.tick = 1000, .seq = 42, .reason = wire::RefuseReason::cooldown};

const probe::Probe probe_value{
    .label = "h\xc3\xa9llo",
    .ratio = 1.5f,
    .pairs = {{.who = {3, 0}, .weight = 0.25f}, {.who = {200, 1}, .weight = -2.0f}},
    .flag = true,
    .color = probe::Color::blue,
    .at = -2.25,
    .shorts = {1, 65535},
    .a_u8 = 255,
    .a_u16 = 0x1234,
    .a_u32 = 0xdeadbeef,
    .a_u64 = 0x0102030405060708ULL,
    .a_i8 = -1,
    .a_i16 = -2,
    .a_i32 = -3,
    .a_i64 = -4,
    .owner = {16384, 5},
};

void starter_vectors() {
    const auto v = read_vectors("starter.vec");
    check(encode_hex(input_value) == v.at("input"), "input encodes to the committed vector");
    check(encode_hex(pose_value) == v.at("pose"), "pose encodes to the committed vector");
    check(encode_hex(hp_value) == v.at("hp"), "hp encodes to the committed vector");
    check(encode_hex(refused_value) == v.at("refused"), "refused encodes to the committed vector");

    check(round_trips(wire::decode_to_server, v.at("input"), input_value), "input round trips");
    check(round_trips(wire::decode_to_client, v.at("pose"), pose_value), "pose round trips");
    check(round_trips(wire::decode_to_client, v.at("hp"), hp_value), "hp round trips");
    check(round_trips(wire::decode_to_client, v.at("refused"), refused_value), "refused round trips");
}

void probe_vectors() {
    const auto v = read_vectors("probe.vec");
    check(probe_encode_hex(probe_value) == v.at("probe"), "probe encodes to the committed vector");
    check(probe_encode_hex(probe::Ping{.nonce = 42}) == v.at("ping"), "ping encodes to the committed vector");
    check(round_trips(probe::decode_to_client, v.at("probe"), probe_value), "probe round trips");
    check(round_trips(probe::decode_to_server, v.at("ping"), probe::Ping{.nonce = 42}), "ping round trips");
}

void quantization_snaps_to_grid() {
    std::vector<std::uint8_t> out;
    check(wire::encode(wire::Input{.dx = 0.123, .dz = -0.456, .seq = 1}, out).has_value(), "off-grid input encodes");
    auto got = wire::decode_to_server(out);
    check(got.has_value() && std::get<wire::Input>(*got).dx == 0.12 && std::get<wire::Input>(*got).dz == -0.46,
          "off-grid wish decodes to 0.12 and -0.46");
}

void decode_rejects() {
    const auto client = wire::decode_to_client;
    const auto server = wire::decode_to_server;
    const auto pr = probe::decode_to_client;
    check(rejects(client, "", Error::truncated), "empty input is truncated");
    check(rejects(client, "020702d244060032400600d71806", Error::truncated), "short pose is truncated");
    check(rejects(server, "019600012c01000000", Error::trailing), "byte after input is trailing");
    check(rejects(client, "7f", Error::unknown_message), "id 127 is unknown");
    check(rejects(server, "020702d244060032400600d7180600", Error::unknown_message), "pose is unknown to the server");
    check(rejects(client, "8100", Error::bad_varint), "overlong varint id");
    check(rejects(server, "01c900012c010000", Error::out_of_range), "wish above its range");
    check(rejects(server, "019600022c010000", Error::bad_bool), "bool byte 2");
    check(rejects(client, "04e80300002a00000000", Error::bad_enum), "refuse reason 0");
    check(rejects(pr, "0109616161616161616161", Error::over_bound), "string over bound");
    check(rejects(pr, "0101ff", Error::bad_utf8), "string not utf-8");
    check(rejects(pr, "01000000c07f", Error::non_finite), "f32 NaN");
    check(rejects(pr, "01000000807f", Error::non_finite), "f32 +Inf");
    check(rejects(pr, "01000000803f04", Error::over_bound), "list over bound");
}

template <typename Msg, typename Encode>
bool encode_rejects(Encode encode, const Msg& m, Error want) {
    std::vector<std::uint8_t> out{0xaa};
    auto got = encode(m, out);
    return !got.has_value() && got.error() == want && out == std::vector<std::uint8_t>{0xaa};
}

void encode_rejects_and_leaves_buffer_unchanged() {
    const auto enc = [](const auto& m, auto& out) { return wire::encode(m, out); };
    const auto penc = [](const auto& m, auto& out) { return probe::encode(m, out); };
    check(encode_rejects(enc, wire::Input{.dx = std::nan("")}, Error::non_finite), "NaN wish refused");
    check(encode_rejects(enc, wire::Input{.dz = 1.01}, Error::out_of_range), "wish above range refused");
    check(encode_rejects(enc, wire::Pose{.x = -4096.5}, Error::out_of_range), "pose below range refused");
    check(encode_rejects(enc, wire::Refused{.reason = static_cast<wire::RefuseReason>(99)}, Error::bad_enum),
          "unknown reason refused");
    check(encode_rejects(penc, probe::Probe{.label = "123456789"}, Error::over_bound), "label over bound refused");
    check(encode_rejects(penc, probe::Probe{.ratio = -std::numeric_limits<float>::infinity()}, Error::non_finite),
          "infinite ratio refused");
    check(encode_rejects(penc, probe::Probe{.pairs = std::vector<probe::Pair>(4)}, Error::over_bound),
          "four pairs refused");
}

}

int main() {
    starter_vectors();
    probe_vectors();
    quantization_snaps_to_grid();
    decode_rejects();
    encode_rejects_and_leaves_buffer_unchanged();
    return marque::test::check_finish();
}
