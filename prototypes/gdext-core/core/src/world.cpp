#include "marque/world.hpp"

#include <bit>
#include <cstring>

namespace marque {

namespace {

enum class Kind : std::uint8_t { Hp = 1, Despawn = 2 };

template <class... Ts>
struct Overloaded : Ts... {
    using Ts::operator()...;
};

template <typename T>
T read_le(std::span<const std::uint8_t> bytes, std::size_t at) {
    static_assert(std::endian::native == std::endian::little);
    T value;
    std::memcpy(&value, bytes.data() + at, sizeof(T));
    return value;
}

std::expected<ServerMsg, std::string> decode_hp(std::span<const std::uint8_t> frame) {
    if (frame.size() != 17) {
        return std::unexpected("hp frame must be 17 bytes, got " + std::to_string(frame.size()));
    }
    HpMsg msg{PlayerId{read_le<std::int64_t>(frame, 1)},
              Vitals{read_le<std::int32_t>(frame, 9), read_le<std::int32_t>(frame, 13)}};
    if (msg.id.value < 1) {
        return std::unexpected("hp.id must be >= 1");
    }
    if (msg.vitals.max_hp < 1 || msg.vitals.hp < 0 || msg.vitals.hp > msg.vitals.max_hp) {
        return std::unexpected("hp must satisfy 0 <= hp <= max_hp and max_hp >= 1");
    }
    return msg;
}

std::expected<ServerMsg, std::string> decode_despawn(std::span<const std::uint8_t> frame) {
    if (frame.size() != 9) {
        return std::unexpected("despawn frame must be 9 bytes, got " + std::to_string(frame.size()));
    }
    return DespawnMsg{PlayerId{read_le<std::int64_t>(frame, 1)}};
}

}

std::expected<ServerMsg, std::string> decode(std::span<const std::uint8_t> frame) {
    if (frame.empty()) {
        return std::unexpected("empty frame");
    }
    switch (static_cast<Kind>(frame[0])) {
        case Kind::Hp:
            return decode_hp(frame);
        case Kind::Despawn:
            return decode_despawn(frame);
    }
    return std::unexpected("unknown message kind " + std::to_string(frame[0]));
}

std::optional<Vitals> World::vitals(PlayerId id) const {
    auto found = vitals_.find(id.value);
    if (found == vitals_.end()) {
        return std::nullopt;
    }
    return found->second;
}

std::expected<void, std::string> Replicator::apply(std::span<const std::uint8_t> frame) {
    auto decoded = decode(frame);
    if (!decoded) {
        return std::unexpected(decoded.error());
    }
    std::visit(Overloaded{
                   [&](const HpMsg& m) { world_.vitals_[m.id.value] = m.vitals; },
                   [&](const DespawnMsg& m) { world_.vitals_.erase(m.id.value); },
               },
               *decoded);
    return {};
}

}
