#pragma once

#include <godot_cpp/classes/ref_counted.hpp>

class MarqueCore : public godot::RefCounted {
    GDCLASS(MarqueCore, godot::RefCounted)

public:
    int64_t scaffold_answer() const;

protected:
    static void _bind_methods();
};
