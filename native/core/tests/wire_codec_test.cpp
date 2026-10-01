#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "check.hpp"
#include "marque/wire/gen/probe.hpp"
#include "marque/wire/gen/schema.hpp"

using marque::test::check;
namespace wire = marque::wire;
namespace probe = marque::wire::probe;
namespace codec = marque::wire::codec;
using codec::Error;

namespace {

std::vector<std::uint8_t> from_hex(const std::string& hex) {
    std::vector<std::uint8_t> out;
    for (std::size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back(static_cast<std::uint8_t>(std::stoi(hex.substr(i, 2), nullptr, 16)));
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

struct Outcome {
    std::optional<Error> error;
    std::string text;
    std::optional<std::vector<std::uint8_t>> reencoded;
};

template <auto Decode, auto Text, auto Encode>
Outcome run(std::span<const std::uint8_t> bytes) {
    auto m = Decode(bytes);
    if (!m) return {m.error(), {}, {}};
    Outcome o{std::nullopt, Text(*m), std::vector<std::uint8_t>{}};
    if (!Encode(*m, *o.reencoded)) o.reencoded.reset();
    return o;
}

const std::map<std::string, std::function<Outcome(std::span<const std::uint8_t>)>> decoders{
    {"wire/state", run<wire::decode_state, wire::text_state, wire::encode_state>},
    {"wire/events", run<wire::decode_events, wire::text_events, wire::encode_events>},
    {"wire/input", run<wire::decode_input, wire::text_input, wire::encode_input>},
    {"wire/intents", run<wire::decode_intents, wire::text_intents, wire::encode_intents>},
    {"probe/state", run<probe::decode_state, probe::text_state, probe::encode_state>},
    {"probe/events", run<probe::decode_events, probe::text_events, probe::encode_events>},
    {"probe/input", run<probe::decode_input, probe::text_input, probe::encode_input>},
    {"probe/intents", run<probe::decode_intents, probe::text_intents, probe::encode_intents>},
};

const std::map<std::string, Error> error_names{
    {"truncated", Error::truncated},       {"trailing", Error::trailing},
    {"unknown_message", Error::unknown_message}, {"over_bound", Error::over_bound},
    {"non_finite", Error::non_finite},     {"out_of_range", Error::out_of_range},
    {"bad_bool", Error::bad_bool},         {"bad_enum", Error::bad_enum},
    {"bad_varint", Error::bad_varint},     {"bad_utf8", Error::bad_utf8},
    {"rule", Error::rule},
};

void vectors() {
    const auto dir = std::filesystem::path(__FILE__).parent_path() / "../../../shared/wire/vectors";
    std::vector<std::filesystem::path> files;
    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (entry.path().extension() == ".vec") files.push_back(entry.path());
    }
    std::ranges::sort(files);
    check(!files.empty(), "found vector files");
    int count = 0;
    for (const auto& path : files) {
        std::ifstream in(path);
        std::string line;
        std::string schema;
        for (int n = 1; std::getline(in, line); ++n) {
            const std::string where = path.filename().string() + ":" + std::to_string(n);
            if (line.empty() || line[0] == '#') continue;
            std::vector<std::string> fields;
            std::size_t start = 0;
            while (fields.size() < 4) {
                const auto space = line.find(' ', start);
                if (space == std::string::npos) break;
                fields.push_back(line.substr(start, space - start));
                start = space + 1;
            }
            fields.push_back(line.substr(start));
            if (fields.size() == 2 && fields[0] == "schema") {
                schema = fields[1];
                continue;
            }
            const bool accept = fields.size() == 5 && fields[0] == "accept";
            const bool reject = fields.size() == 5 && fields[0] == "reject";
            const auto decoder = decoders.find(schema + "/" + (fields.size() == 5 ? fields[2] : ""));
            if (!(accept || reject) || decoder == decoders.end()) {
                check(false, (where + ": malformed vector line").c_str());
                continue;
            }
            ++count;
            const auto bytes = from_hex(fields[3]);
            const auto got = decoder->second(bytes);
            const auto label = where + " " + fields[1];
            if (reject) {
                const auto want = error_names.find(fields[4]);
                check(want != error_names.end() && got.error == want->second,
                      (label + ": fails with " + fields[4] + ", got " +
                       (got.error ? codec::to_string(*got.error) : "success: " + got.text))
                          .c_str());
                continue;
            }
            check(!got.error, (label + ": decodes" + (got.error ? std::string(", got ") + codec::to_string(*got.error) : "")).c_str());
            check(got.text == fields[4], (label + ": text\n  got  " + got.text + "\n  want " + fields[4]).c_str());
            check(got.reencoded && *got.reencoded == bytes,
                  (label + ": re-encodes to " + fields[3] + ", got " + (got.reencoded ? to_hex(*got.reencoded) : "an error")).c_str());
        }
    }
    check(count > 0, "ran vectors");
}

template <typename T>
T must(std::expected<T, Error> v) {
    check(v.has_value(), "build succeeds");
    if (!v.has_value()) std::exit(marque::test::check_finish());
    return std::move(*v);
}

void built_messages_encode_to_vector_bytes() {
    const auto hex = [](const auto& m) {
        std::vector<std::uint8_t> out;
        const bool ok = encode(m, out).has_value();
        return ok ? to_hex(out) : std::string("error");
    };
    const wire::PlayerId id{7, 2};
    check(hex(must(wire::Input::build({.dx = 0.5, .dz = -1, .jump = true, .seq = 300}))) == "019600012c010000",
          "built input encodes to its vector");
    check(hex(must(wire::Pose::build({.id = id, .x = 12.34, .y = 0.5, .z = -100.25}))) ==
              "020702d244060032400600d7180600",
          "built pose encodes to its vector");
    check(hex(must(wire::Hp::build({.id = id, .hp = 85, .max_hp = 120}))) == "0307025500000078000000",
          "built hp encodes to its vector");
    check(hex(must(wire::Refused::build({.tick = 1000, .seq = 42, .reason = wire::RefuseReason::cooldown}))) ==
              "04e80300002a00000006",
          "built refused encodes to its vector");
    check(hex(must(probe::Party::build({.leader = {1, 0}, .members = {{1, 0}, {2, 0}}}))) == "0401000201000200",
          "built party encodes to its vector");
}

void quantization_snaps_to_grid() {
    std::vector<std::uint8_t> out;
    check(wire::encode(must(wire::Input::build({.dx = 0.123, .dz = -0.456, .seq = 1})), out).has_value(),
          "off-grid input encodes");
    auto got = wire::decode_input(out);
    check(got.has_value() && std::get<wire::Input>(*got).dx() == 0.12 && std::get<wire::Input>(*got).dz() == -0.46,
          "off-grid wish decodes to 0.12 and -0.46");
}

template <typename T>
bool refuses(const std::expected<T, Error>& got, Error want) {
    return !got.has_value() && got.error() == want;
}

void build_refuses_what_decoders_refuse() {
    const probe::NpcId npc{7, 0};
    const probe::PlayerId p1{1, 0};
    const probe::PlayerId p2{2, 0};
    const auto slot = [](std::uint8_t n, std::uint32_t item) {
        return must(probe::BagSlot::build({.slot = n, .item = {item, 0}}));
    };
    const auto offer = [](probe::PlayerId owner, std::uint32_t item) {
        return must(probe::Offer::build({.owner = owner, .item = {item, 0}}));
    };
    check(refuses(probe::Give::build({.npc = npc, .slot = 40}), Error::rule), "give slot 40");
    check(refuses(probe::BagSlot::build({.slot = 40}), Error::rule), "bag slot 40");
    check(refuses(probe::Inventory::build({}), Error::rule), "inventory size 0");
    check(refuses(probe::Zone::build({.tilt = 46}), Error::rule), "tilt 46");
    check(refuses(probe::Zone::build({.lo = -8.25, .hi = -8}), Error::rule), "lo -8.25");
    check(refuses(probe::Zone::build({.hi = 5.5}), Error::rule), "hi 5.5");
    check(refuses(probe::Zone::build({.lo = 11}), Error::out_of_range), "lo 11");
    check(refuses(probe::Dialog::build({.lines = {501}}), Error::rule), "line 501");
    check(refuses(probe::Pick::build({.option = probe::Option::trade}), Error::rule), "pick trade");
    check(refuses(probe::Pick::build({.option = static_cast<probe::Option>(9)}), Error::bad_enum),
          "pick undeclared");
    check(refuses(probe::Dialog::build({.options = std::vector<probe::Option>(5)}), Error::over_bound),
          "five options");
    check(refuses(probe::Party::build({.leader = p1, .members = {p1, p1}}), Error::rule), "repeated member");
    check(refuses(probe::Inventory::build({.size = 10, .slots = {slot(0, 5), slot(0, 6)}}), Error::rule),
          "repeated slot");
    check(refuses(probe::Party::build({.leader = p2, .members = {p1}}), Error::rule), "leader outside");
    check(refuses(probe::Inventory::build({.size = 9, .slots = {slot(9, 6)}}), Error::rule),
          "slot at size");
    check(refuses(probe::Zone::build({.lo = 2, .hi = 1.75}), Error::rule), "lo above hi");
    check(probe::Zone::build({.lo = 2.1, .hi = 2}).has_value(), "lo above hi on the grid is accepted");
    check(refuses(probe::Trade::build({.from = p1, .offers = {offer(p1, 5), offer(p2, 6)}}), Error::rule),
          "foreign offer");
    check(refuses(probe::Trade::build({.from = p1, .offers = {offer(p1, 5), offer(p1, 5)}}), Error::rule),
          "repeated item");
    check(refuses(probe::Duel::build({.challenger = p1, .target = p1}), Error::rule), "duel self");
    check(refuses(wire::Input::build({.dx = std::nan("")}), Error::non_finite), "NaN wish");
    check(refuses(wire::Input::build({.dz = 1.01}), Error::out_of_range), "wish above range");
    check(refuses(probe::Probe::build({.label = "123456789"}), Error::over_bound), "label over bound");
    check(refuses(probe::Probe::build({.ratio = -std::numeric_limits<float>::infinity()}), Error::non_finite),
          "infinite ratio");
}

void unions_and_opts_build_encode_and_print() {
    const probe::Who p1 = probe::PlayerId{1, 0};
    const probe::Who n2 = probe::NpcId{2, 0};
    const auto tag = must(probe::Tag::build({.who = p1,
                                             .other = n2,
                                             .crowd = {p1, n2},
                                             .by = n2,
                                             .note = "hi",
                                             .weight = std::uint8_t{3},
                                             .pair = std::nullopt,
                                             .slots = {std::nullopt, std::uint8_t{5}}}));
    std::vector<std::uint8_t> out;
    check(encode(tag, out).has_value() && to_hex(out) == "0c01010007020002010100070200010702000102686901030002000105",
          "built tag encodes to its vector");
    check(to_text(tag) == R"(tag{who:PlayerId(1/0) other:NpcId(2/0) crowd:[PlayerId(1/0) NpcId(2/0)] by:NpcId(2/0) note:"hi" weight:3 pair:_ slots:[_ 5]})",
          "built tag prints the absent opts as _");
    check(std::holds_alternative<probe::NpcId>(*tag.by()) && std::get<probe::NpcId>(*tag.by()).index == 2,
          "the opt union reads back as an NpcId");
    check(refuses(probe::Tag::build({.who = p1, .other = p1, .crowd = {p1}}), Error::rule), "other equal to who");
    check(refuses(probe::Tag::build({.who = p1, .other = n2, .crowd = {n2}}), Error::rule), "who outside crowd");
    check(refuses(probe::Tag::build({.who = p1, .other = n2, .crowd = {p1, p1}}), Error::rule), "repeated crowd member");
    check(refuses(probe::Tag::build({.who = p1, .other = n2, .crowd = {p1}, .weight = std::uint8_t{10}}), Error::rule),
          "present weight 10 outside 1..9");
    check(probe::Tag::build({.who = p1, .other = n2, .crowd = {p1}}).has_value(), "absent weight skips its range");

    const auto mark = must(probe::Mark::build({.spot = 1.13, .path = {std::nullopt, -2.6}}));
    check(mark.spot() == 1.25 && mark.path()[1] == -2.5, "build snaps opt and list quants to the grid");
    std::vector<std::uint8_t> mark_bytes;
    check(encode(mark, mark_bytes).has_value() && to_hex(mark_bytes) == "0d012d0200011e", "snapped mark encodes to its vector");
    const auto pose = must(wire::Pose::build({.id = {7, 2}, .x = 87.49238566911093, .y = 0.005, .z = -36.739013361827794}));
    check(pose.x() == 87.49 && pose.y() == 0.01 && pose.z() == -36.74, "build snaps a pose to what the peer decodes");
}

void decode_next_reads_packed_messages_in_order() {
    const auto bytes = from_hex("020702d244060032400600d7180600"
                                "0307025500000078000000"
                                "020100881300000000000000000000");
    codec::Reader r{bytes};
    const char* want[] = {
        "pose{id:PlayerId(7/2) x:12.34 y:0.5 z:-100.25}",
        "hp{id:PlayerId(7/2) hp:85 max_hp:120}",
        "pose{id:PlayerId(1/0) x:-4046 y:-4096 z:-4096}",
    };
    for (const char* w : want) {
        auto m = wire::decode_next_state(r);
        check(m.has_value() && wire::text_state(*m) == w, w);
    }
    check(r.remaining() == 0, "reader is empty after three messages");
    check(!r.finish().has_value(), "finish succeeds after three messages");
}

void text_matches_go() {
    const std::pair<double, const char*> f64[] = {
        {0.0, "0"},
        {-0.0, "-0"},
        {1.0, "1"},
        {-2.25, "-2.25"},
        {12.34, "12.34"},
        {0.1, "0.1"},
        {1e-4, "0.0001"},
        {1.5e-5, "1.5e-05"},
        {123456.0, "123456"},
        {1e6, "1e+06"},
        {1234567.0, "1.234567e+06"},
        {1e21, "1e+21"},
        {5e-324, "5e-324"},
        {std::numeric_limits<double>::max(), "1.7976931348623157e+308"},
        {-4096.0, "-4096"},
        {100000.5, "100000.5"},
        {0.3, "0.3"},
    };
    for (const auto& [v, want] : f64) {
        std::string got;
        codec::text_f64(got, v);
        check(got == want, (std::string("f64 ") + want + " got " + got).c_str());
    }
    const std::pair<float, const char*> f32[] = {
        {0.25f, "0.25"}, {-2.0f, "-2"}, {1.1f, "1.1"}, {3.4028235e38f, "3.4028235e+38"},
        {1e-7f, "1e-07"}, {16777216.0f, "1.6777216e+07"}, {0.1f, "0.1"},
    };
    for (const auto& [v, want] : f32) {
        std::string got;
        codec::text_f32(got, v);
        check(got == want, (std::string("f32 ") + want + " got " + got).c_str());
    }
    const std::pair<std::string, const char*> quoted[] = {
        {"h\xc3\xa9llo", R"("h\u00e9llo")"},
        {"tab\tq\"b\\", R"("tab\tq\"b\\")"},
        {std::string("\x00\x7f", 2), R"("\x00\x7f")"},
        {"\xf0\x9f\x98\x80", R"("\U0001f600")"},
        {"\xe2\x80\xa8", R"("\u2028")"},
    };
    for (const auto& [s, want] : quoted) {
        std::string got;
        codec::text_quoted(got, s);
        check(got == want, (std::string("quoted ") + want + " got " + got).c_str());
    }
}

}

int main() {
    vectors();
    built_messages_encode_to_vector_bytes();
    quantization_snaps_to_grid();
    build_refuses_what_decoders_refuse();
    unions_and_opts_build_encode_and_print();
    decode_next_reads_packed_messages_in_order();
    text_matches_go();
    return marque::test::check_finish();
}
