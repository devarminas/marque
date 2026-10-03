#include "marque_core.hpp"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

static void initialize_marque(ModuleInitializationLevel level) {
    if (level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }
    GDREGISTER_CLASS(MarqueId64);
    GDREGISTER_CLASS(MarqueHandle);
    GDREGISTER_CLASS(MarquePlayerHandle);
    GDREGISTER_CLASS(MarqueNpcHandle);
    GDREGISTER_CLASS(MarqueItemHandle);
    GDREGISTER_CLASS(MarqueNodeHandle);
    GDREGISTER_CLASS(MarqueBagEntry);
    GDREGISTER_CLASS(MarqueWornName);
    GDREGISTER_CLASS(MarqueWornEntry);
    GDREGISTER_CLASS(MarqueToolEntry);
    GDREGISTER_CLASS(MarqueSkillEntry);
    GDREGISTER_CLASS(MarqueQuestEntry);
    GDREGISTER_CLASS(MarqueTextLine);
    GDREGISTER_CLASS(MarqueDialogChoice);
    GDREGISTER_CLASS(MarqueTransform);
    GDREGISTER_CLASS(MarqueVitals);
    GDREGISTER_CLASS(MarqueGear);
    GDREGISTER_CLASS(MarqueCasting);
    GDREGISTER_CLASS(MarqueCastBar);
    GDREGISTER_CLASS(MarqueLook);
    GDREGISTER_CLASS(MarqueInventory);
    GDREGISTER_CLASS(MarqueEquipment);
    GDREGISTER_CLASS(MarqueClass);
    GDREGISTER_CLASS(MarqueSkills);
    GDREGISTER_CLASS(MarqueQuestLog);
    GDREGISTER_CLASS(MarqueDialog);
    GDREGISTER_CLASS(MarqueParty);
    GDREGISTER_CLASS(MarqueInvite);
    GDREGISTER_CLASS(MarqueAdminReply);
    GDREGISTER_CLASS(MarqueCooldown);
    GDREGISTER_CLASS(MarqueRefused);
    GDREGISTER_CLASS(MarqueDialogClear);
    GDREGISTER_CLASS(MarquePartyClear);
    GDREGISTER_CLASS(MarqueInviteClear);
    GDREGISTER_CLASS(MarqueSwing);
    GDREGISTER_CLASS(MarqueCastPhase);
    GDREGISTER_CLASS(MarqueGatherStart);
    GDREGISTER_CLASS(MarqueEntityView);
    GDREGISTER_CLASS(MarqueWorldView);
    GDREGISTER_CLASS(MarqueOwnerView);
    GDREGISTER_CLASS(MarqueTickView);
    GDREGISTER_CLASS(MarqueCore);
    GDREGISTER_CLASS(MarqueRuntime);
}

static void uninitialize_marque(ModuleInitializationLevel) {}

extern "C" {
GDExtensionBool GDE_EXPORT marque_library_init(GDExtensionInterfaceGetProcAddress get_proc_address,
                                               GDExtensionClassLibraryPtr library,
                                               GDExtensionInitialization* initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer(initialize_marque);
    init.register_terminator(uninitialize_marque);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
}
