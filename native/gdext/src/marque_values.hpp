#pragma once

#include <optional>
#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/typed_array.hpp>
#include "marque/client/domain.hpp"

class MarqueId64 : public godot::RefCounted {
    GDCLASS(MarqueId64,godot::RefCounted)
    std::uint64_t value_=0;
protected:
    static void _bind_methods();
public:
    void set_native(std::uint64_t value){value_=value;}
    int64_t get_high() const{return value_>>32;}
    int64_t get_low() const{return value_&0xffffffffULL;}
};

class MarqueHandle : public godot::RefCounted {
    GDCLASS(MarqueHandle,godot::RefCounted)
    std::optional<marque::world::Entity> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::world::Entity value){value_=value;}
    const std::optional<marque::world::Entity>& native() const{return value_;}
    bool get_valid() const{return value_.has_value();}
    int64_t get_kind() const{return value_ ? static_cast<int64_t>(marque::world::kind(*value_))+1 : 0;}
    int64_t get_index() const{return value_ ? std::visit([](auto v){return static_cast<int64_t>(v.index);},*value_) : 0;}
    int64_t get_generation() const{return value_ ? marque::world::generation(*value_) : 0;}
};

class MarquePlayerHandle : public MarqueHandle {
    GDCLASS(MarquePlayerHandle,MarqueHandle)
protected:
    static void _bind_methods(){}
public:
    void set_native(marque::wire::PlayerId value){MarqueHandle::set_native(marque::world::Player{value.index,value.gen});}
};

class MarqueNpcHandle : public MarqueHandle {
    GDCLASS(MarqueNpcHandle,MarqueHandle)
protected:
    static void _bind_methods(){}
public:
    void set_native(marque::wire::NpcId value){MarqueHandle::set_native(marque::world::Npc{value.index,value.gen});}
};

class MarqueItemHandle : public MarqueHandle {
    GDCLASS(MarqueItemHandle,MarqueHandle)
protected:
    static void _bind_methods(){}
public:
    void set_native(marque::wire::ItemId value){MarqueHandle::set_native(marque::world::Item{value.index,value.gen});}
};

class MarqueNodeHandle : public MarqueHandle {
    GDCLASS(MarqueNodeHandle,MarqueHandle)
protected:
    static void _bind_methods(){}
public:
    void set_native(marque::wire::NodeId value){MarqueHandle::set_native(marque::world::Node{value.index,value.gen});}
};

template<class T,class V> godot::Ref<T> marque_value(V value){
    godot::Ref<T> ref;ref.instantiate();ref->set_native(std::move(value));return ref;
}
godot::Ref<MarqueHandle> marque_handle(marque::world::Entity value);

class MarqueBagEntry : public godot::RefCounted {
    GDCLASS(MarqueBagEntry,godot::RefCounted)
    std::optional<marque::wire::BagEntry> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::BagEntry value){value_=std::move(value);}
    int64_t get_slot() const;
    godot::String get_kind() const;
};

class MarqueWornName : public godot::RefCounted {
    GDCLASS(MarqueWornName,godot::RefCounted)
    std::optional<marque::wire::WornName> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::WornName value){value_=std::move(value);}
    godot::String get_name() const;
};

class MarqueWornEntry : public godot::RefCounted {
    GDCLASS(MarqueWornEntry,godot::RefCounted)
    std::optional<marque::wire::WornEntry> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::WornEntry value){value_=std::move(value);}
    godot::String get_slot() const;
    godot::String get_kind() const;
};

class MarqueToolEntry : public godot::RefCounted {
    GDCLASS(MarqueToolEntry,godot::RefCounted)
    std::optional<marque::wire::ToolEntry> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::ToolEntry value){value_=std::move(value);}
    godot::String get_kind() const;
};

class MarqueSkillEntry : public godot::RefCounted {
    GDCLASS(MarqueSkillEntry,godot::RefCounted)
    std::optional<marque::wire::SkillEntry> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::SkillEntry value){value_=std::move(value);}
    godot::String get_id() const;
    int64_t get_xp() const;
    int64_t get_level() const;
};

class MarqueQuestEntry : public godot::RefCounted {
    GDCLASS(MarqueQuestEntry,godot::RefCounted)
    std::optional<marque::wire::QuestEntry> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::QuestEntry value){value_=std::move(value);}
    godot::String get_id() const;
    godot::String get_title() const;
    godot::String get_objective() const;
    godot::String get_status() const;
};

class MarqueTextLine : public godot::RefCounted {
    GDCLASS(MarqueTextLine,godot::RefCounted)
    std::optional<marque::wire::TextLine> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::TextLine value){value_=std::move(value);}
    godot::String get_text() const;
};

class MarqueDialogChoice : public godot::RefCounted {
    GDCLASS(MarqueDialogChoice,godot::RefCounted)
    std::optional<marque::wire::DialogChoice> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::DialogChoice value){value_=std::move(value);}
    godot::String get_id() const;
};

class MarqueTransform : public godot::RefCounted {
    GDCLASS(MarqueTransform,godot::RefCounted)
    std::optional<marque::wire::Transform> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Transform value){value_=std::move(value);}
    double get_x() const;
    double get_y() const;
    double get_z() const;
};

class MarqueVitals : public godot::RefCounted {
    GDCLASS(MarqueVitals,godot::RefCounted)
    std::optional<marque::wire::Vitals> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Vitals value){value_=std::move(value);}
    int64_t get_hp() const;
    int64_t get_max_hp() const;
    int64_t get_mana() const;
    int64_t get_max_mana() const;
};

class MarqueGear : public godot::RefCounted {
    GDCLASS(MarqueGear,godot::RefCounted)
    std::optional<marque::wire::Gear> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Gear value){value_=std::move(value);}
    godot::String get_helmet() const;
    godot::String get_chest() const;
    godot::String get_trousers() const;
    godot::String get_feet() const;
    godot::String get_left_hand() const;
    godot::String get_right_hand() const;
};

class MarqueCasting : public godot::RefCounted {
    GDCLASS(MarqueCasting,godot::RefCounted)
    std::optional<marque::wire::Casting> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Casting value){value_=std::move(value);}
    godot::String get_ability() const;
    int64_t get_start() const;
    int64_t get_ticks() const;
};

class MarqueCastBar : public godot::RefCounted {
    GDCLASS(MarqueCastBar,godot::RefCounted)
    std::optional<marque::wire::CastBar> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::CastBar value){value_=std::move(value);}
    godot::Ref<MarqueCasting> get_casting() const;
};

class MarqueLook : public godot::RefCounted {
    GDCLASS(MarqueLook,godot::RefCounted)
    std::optional<marque::wire::Look> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Look value){value_=std::move(value);}
    godot::String get_kind() const;
};

class MarqueInventory : public godot::RefCounted {
    GDCLASS(MarqueInventory,godot::RefCounted)
    std::optional<marque::wire::Inventory> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Inventory value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    int64_t get_size() const;
    godot::TypedArray<MarqueBagEntry> get_slots() const;
};

class MarqueEquipment : public godot::RefCounted {
    GDCLASS(MarqueEquipment,godot::RefCounted)
    std::optional<marque::wire::Equipment> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Equipment value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::TypedArray<MarqueWornName> get_worn() const;
    godot::TypedArray<MarqueWornEntry> get_slots() const;
};

class MarqueClass : public godot::RefCounted {
    GDCLASS(MarqueClass,godot::RefCounted)
    std::optional<marque::wire::Class> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Class value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::String get_class_id() const;
    godot::TypedArray<MarqueWornEntry> get_missing_slots() const;
    godot::TypedArray<MarqueToolEntry> get_missing_tools() const;
};

class MarqueSkills : public godot::RefCounted {
    GDCLASS(MarqueSkills,godot::RefCounted)
    std::optional<marque::wire::Skills> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Skills value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::TypedArray<MarqueSkillEntry> get_skills() const;
};

class MarqueQuestLog : public godot::RefCounted {
    GDCLASS(MarqueQuestLog,godot::RefCounted)
    std::optional<marque::wire::QuestLog> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::QuestLog value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::TypedArray<MarqueQuestEntry> get_quests() const;
};

class MarqueDialog : public godot::RefCounted {
    GDCLASS(MarqueDialog,godot::RefCounted)
    std::optional<marque::wire::Dialog> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Dialog value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::Ref<MarqueNpcHandle> get_npc() const;
    godot::TypedArray<MarqueTextLine> get_lines() const;
    godot::TypedArray<MarqueDialogChoice> get_options() const;
};

class MarqueParty : public godot::RefCounted {
    GDCLASS(MarqueParty,godot::RefCounted)
    std::optional<marque::wire::Party> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Party value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::Ref<MarqueId64> get_id() const;
    godot::Ref<MarquePlayerHandle> get_leader() const;
    godot::TypedArray<MarquePlayerHandle> get_members() const;
};

class MarqueInvite : public godot::RefCounted {
    GDCLASS(MarqueInvite,godot::RefCounted)
    std::optional<marque::wire::Invite> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Invite value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::Ref<MarquePlayerHandle> get_from() const;
};

class MarqueAdminReply : public godot::RefCounted {
    GDCLASS(MarqueAdminReply,godot::RefCounted)
    std::optional<marque::wire::AdminReply> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::AdminReply value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::String get_text() const;
};

class MarqueCooldown : public godot::RefCounted {
    GDCLASS(MarqueCooldown,godot::RefCounted)
    std::optional<marque::wire::Cooldown> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Cooldown value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::String get_ability() const;
    int64_t get_ready_tick() const;
};

class MarqueRefused : public godot::RefCounted {
    GDCLASS(MarqueRefused,godot::RefCounted)
    std::optional<marque::wire::Refused> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Refused value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    int64_t get_source() const;
    int64_t get_seq() const;
    int64_t get_reason() const;
};

class MarqueDialogClear : public godot::RefCounted {
    GDCLASS(MarqueDialogClear,godot::RefCounted)
    std::optional<marque::wire::DialogClear> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::DialogClear value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
    godot::Ref<MarqueNpcHandle> get_npc() const;
};

class MarquePartyClear : public godot::RefCounted {
    GDCLASS(MarquePartyClear,godot::RefCounted)
    std::optional<marque::wire::PartyClear> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::PartyClear value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
};

class MarqueInviteClear : public godot::RefCounted {
    GDCLASS(MarqueInviteClear,godot::RefCounted)
    std::optional<marque::wire::InviteClear> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::InviteClear value){value_=std::move(value);}
    godot::Ref<MarqueId64> get_stream() const;
    godot::Ref<MarqueId64> get_event_seq() const;
    int64_t get_tick() const;
};

class MarqueSwing : public godot::RefCounted {
    GDCLASS(MarqueSwing,godot::RefCounted)
    std::optional<marque::wire::Swing> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::Swing value){value_=std::move(value);}
    int64_t get_tick() const;
    godot::Ref<MarqueHandle> get_attacker() const;
    godot::Ref<MarqueHandle> get_target() const;
    int64_t get_amount() const;
    bool get_crit() const;
    bool get_miss() const;
};

class MarqueCastPhase : public godot::RefCounted {
    GDCLASS(MarqueCastPhase,godot::RefCounted)
    std::optional<marque::wire::CastPhase> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::CastPhase value){value_=std::move(value);}
    int64_t get_tick() const;
    godot::Ref<MarqueHandle> get_caster() const;
    godot::String get_ability() const;
    int64_t get_step() const;
    godot::Ref<MarqueHandle> get_target() const;
    int64_t get_amount() const;
};

class MarqueGatherStart : public godot::RefCounted {
    GDCLASS(MarqueGatherStart,godot::RefCounted)
    std::optional<marque::wire::GatherStart> value_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::wire::GatherStart value){value_=std::move(value);}
    int64_t get_tick() const;
    godot::Ref<MarquePlayerHandle> get_player() const;
    godot::Ref<MarqueNodeHandle> get_node() const;
};
