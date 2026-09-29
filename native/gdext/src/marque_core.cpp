#include "marque_core.hpp"

#include "marque/scaffold.hpp"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

void MarqueCore::_bind_methods() {
    ClassDB::bind_method(D_METHOD("scaffold_answer"), &MarqueCore::scaffold_answer);
}

int64_t MarqueCore::scaffold_answer() const {
    return marque::scaffold::answer();
}
