#include "world_client.hpp"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void WorldClient::_bind_methods() {
    ClassDB::bind_method(D_METHOD("feed_frame", "frame"), &WorldClient::feed_frame);
    ClassDB::bind_method(D_METHOD("player_hp", "id"), &WorldClient::player_hp);
    ClassDB::bind_method(D_METHOD("player_max_hp", "id"), &WorldClient::player_max_hp);
    ClassDB::bind_method(D_METHOD("player_count"), &WorldClient::player_count);
}

String WorldClient::feed_frame(const PackedByteArray& frame) {
    auto result = replicator_.apply(std::span<const std::uint8_t>(frame.ptr(), frame.size()));
    if (!result) {
        return String(result.error().c_str());
    }
    return String();
}

int64_t WorldClient::player_hp(int64_t id) const {
    auto v = world_.vitals({id});
    return v ? v->hp : -1;
}

int64_t WorldClient::player_max_hp(int64_t id) const {
    auto v = world_.vitals({id});
    return v ? v->max_hp : -1;
}

int64_t WorldClient::player_count() const {
    return static_cast<int64_t>(world_.player_count());
}
