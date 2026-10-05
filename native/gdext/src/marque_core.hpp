#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include "marque_values.hpp"
#include "marque/client/runtime.hpp"

class MarqueEntityView : public godot::RefCounted {
    GDCLASS(MarqueEntityView,godot::RefCounted)
    marque::world::Entity id_=marque::world::Player{0,0};
    bool valid_=false;
    marque::client::Catalog::values values_;
protected:
    static void _bind_methods();
public:
    void set_native(marque::world::Entity id,marque::client::Catalog::values values){id_=id;values_=std::move(values);valid_=true;}
    godot::Ref<MarqueHandle> get_handle() const{return valid_ ? marque_handle(id_) : godot::Ref<MarqueHandle>{};}
    godot::Ref<MarqueTransform> get_transform() const;
    godot::Ref<MarqueVitals> get_vitals() const;
    godot::Ref<MarqueGear> get_gear() const;
    godot::Ref<MarqueCastBar> get_cast() const;
    godot::Ref<MarqueLook> get_look() const;
};

class MarqueWorldView : public godot::RefCounted {
    GDCLASS(MarqueWorldView,godot::RefCounted)
    std::optional<marque::client::Publication> value_;
    double alpha_=1;
protected:
    static void _bind_methods();
public:
    void set_native(marque::client::Publication value,double alpha){value_=std::move(value);alpha_=alpha;}
    int64_t get_tick() const{return value_ ? value_->current->tick().value : 0;}
    double get_alpha() const{return alpha_;}
    godot::TypedArray<MarqueEntityView> get_entities() const;
};

class MarqueOwnerView : public godot::RefCounted {
    GDCLASS(MarqueOwnerView,godot::RefCounted)
    std::shared_ptr<const marque::client::OwnerState> value_;
protected:
    static void _bind_methods();
public:
    void set_native(std::shared_ptr<const marque::client::OwnerState> value){value_=std::move(value);}
    godot::Ref<MarqueInventory> get_inventory() const;
    godot::Ref<MarqueEquipment> get_equipment() const;
    godot::Ref<MarqueClass> get_role() const;
    godot::Ref<MarqueSkills> get_skills() const;
    godot::Ref<MarqueQuestLog> get_quests() const;
    godot::Ref<MarqueDialog> get_dialog() const;
    godot::Ref<MarqueParty> get_party() const;
    godot::Ref<MarqueInvite> get_invite() const;
    godot::Ref<MarqueAdminReply> get_admin() const;
    godot::Ref<MarqueRefused> get_refusal() const;
    godot::TypedArray<MarqueCooldown> get_cooldowns() const;
};

class MarqueTickView : public godot::RefCounted {
    GDCLASS(MarqueTickView,godot::RefCounted)
    std::shared_ptr<const marque::client::Tick> value_;
protected:
    static void _bind_methods();
public:
    void set_native(std::shared_ptr<const marque::client::Tick> value){value_=std::move(value);}
    int64_t get_tick() const{return value_ ? value_->tick().value : 0;}
    godot::Ref<MarqueId64> get_stream() const{return marque_value<MarqueId64>(value_ ? value_->events().stream : 0);}
    godot::Ref<MarqueId64> get_epoch() const{return marque_value<MarqueId64>(value_ ? value_->events().epoch : 0);}
    godot::Ref<MarqueId64> get_event_end() const{return marque_value<MarqueId64>(value_ ? value_->events().event_end : 0);}
    int64_t get_next_intent() const{return value_ ? value_->events().next_intent : 0;}
};

class MarquePredictedPose : public godot::RefCounted {
    GDCLASS(MarquePredictedPose,godot::RefCounted)
    std::shared_ptr<const marque::motion::PredictedPose> value_;
protected:
    static void _bind_methods();
public:
    void set_native(std::shared_ptr<const marque::motion::PredictedPose> value){value_=std::move(value);}
    int64_t get_tick() const{return value_ ? value_->tick : 0;}
    int64_t get_mode() const{return value_ ? static_cast<int64_t>(value_->mode) : 2;}
    double get_x() const{return value_ ? value_->state.x : 0;}
    double get_y() const{return value_ ? value_->state.y : 0;}
    double get_z() const{return value_ ? value_->state.z : 0;}
    double get_vy() const{return value_ ? value_->state.vy : 0;}
    double get_dx() const{return value_ ? value_->state.dx : 0;}
    double get_dz() const{return value_ ? value_->state.dz : 0;}
};

class MarqueCore : public godot::RefCounted {
    GDCLASS(MarqueCore,godot::RefCounted)
    std::shared_ptr<marque::client::Runtime> runtime_;
    std::optional<marque::client::Publication> publication_;
protected:
    static void _bind_methods();
public:
    void attach(std::shared_ptr<marque::client::Runtime> runtime){runtime_=std::move(runtime);}
    void latch(marque::client::Publication publication);
    godot::Ref<MarqueWorldView> get_world() const;
    godot::Ref<MarqueOwnerView> get_owner() const;
    godot::Ref<MarqueTickView> get_tick() const;
    bool get_prediction_available() const{return runtime_ && runtime_->connection()==marque::client::Connection::connected && runtime_->prediction()!=nullptr;}
    godot::Ref<MarquePredictedPose> get_predicted_local_pose() const;
    int64_t get_connection() const{return runtime_ ? static_cast<int64_t>(runtime_->connection()) : 0;}
    int64_t get_error() const{return runtime_ ? static_cast<int64_t>(runtime_->error()) : 0;}
    bool move(double dx,double dz,bool jump);
    bool pickup(const godot::Ref<MarqueItemHandle>& item);
    bool gather(const godot::Ref<MarqueNodeHandle>& node);
    bool drop(int64_t slot);
    bool equip(int64_t slot);
    bool unequip(const godot::String& worn);
    bool use_self(int64_t slot);
    bool use_station(int64_t slot,const godot::Ref<MarqueNodeHandle>& station);
    bool attack_player(const godot::Ref<MarquePlayerHandle>& target);
    bool attack_npc(const godot::Ref<MarqueNpcHandle>& target);
    bool respawn();
    bool cast_self(const godot::String& ability);
    bool cast_player(const godot::String& ability,const godot::Ref<MarquePlayerHandle>& target);
    bool cast_npc(const godot::String& ability,const godot::Ref<MarqueNpcHandle>& target);
    bool talk(const godot::Ref<MarqueNpcHandle>& npc);
    bool dialog_option(const godot::Ref<MarqueNpcHandle>& npc,const godot::String& option);
    bool give(const godot::Ref<MarqueNpcHandle>& npc,int64_t slot);
    bool party_invite(const godot::Ref<MarquePlayerHandle>& target);
    bool party_accept();
    bool party_decline();
    bool party_leave();
    bool party_kick(const godot::Ref<MarquePlayerHandle>& target);
    bool admin(const godot::String& line);
};

class MarqueRuntime : public godot::Node {
    GDCLASS(MarqueRuntime,godot::Node)
    std::shared_ptr<marque::client::Runtime> runtime_;
    godot::Ref<MarqueCore> core_;
protected:
    static void _bind_methods();
    void _notification(int what);
public:
    MarqueRuntime();
    ~MarqueRuntime();
    godot::Ref<MarqueCore> get_core() const{return core_;}
    bool connect_token(const godot::PackedByteArray& token);
    void disconnect();
};
