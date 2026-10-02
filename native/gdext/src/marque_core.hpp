#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

class MarqueCore : public godot::RefCounted {
    GDCLASS(MarqueCore, godot::RefCounted)

protected:
    static void _bind_methods();
};
