#pragma once

#include "marque/world.hpp"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

class WorldClient : public godot::RefCounted {
    GDCLASS(WorldClient, godot::RefCounted)

public:
    WorldClient() : replicator_(world_) {}

    godot::String feed_frame(const godot::PackedByteArray& frame);
    int64_t player_hp(int64_t id) const;
    int64_t player_max_hp(int64_t id) const;
    int64_t player_count() const;

protected:
    static void _bind_methods();

private:
    marque::World world_;
    marque::Replicator replicator_;
};
