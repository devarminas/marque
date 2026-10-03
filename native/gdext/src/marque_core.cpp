#include "marque_core.hpp"
#include <algorithm>
#include <chrono>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;
using namespace marque;

namespace {
std::string text(const String& value){const auto bytes=value.utf8();return std::string(bytes.get_data(),bytes.length());}
template<class W,class G,class N> std::optional<W> target_native(const Ref<G>& value){
    if(value.is_null() || !value->native()) return std::nullopt;
    const auto* id=std::get_if<N>(&*value->native());
    if(!id) return std::nullopt;
    return W{id->index,id->generation};
}
template<class G,class W> Ref<G> optional_value(const std::optional<W>& value){return value ? marque_value<G>(*value) : Ref<G>{};}
}

void MarqueEntityView::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_handle"),&MarqueEntityView::get_handle);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"handle"),"","get_handle");
    ClassDB::bind_method(D_METHOD("get_transform"),&MarqueEntityView::get_transform);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"transform"),"","get_transform");
    ClassDB::bind_method(D_METHOD("get_vitals"),&MarqueEntityView::get_vitals);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"vitals"),"","get_vitals");
    ClassDB::bind_method(D_METHOD("get_gear"),&MarqueEntityView::get_gear);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"gear"),"","get_gear");
    ClassDB::bind_method(D_METHOD("get_cast"),&MarqueEntityView::get_cast);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"cast"),"","get_cast");
    ClassDB::bind_method(D_METHOD("get_look"),&MarqueEntityView::get_look);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"look"),"","get_look");
}
Ref<MarqueTransform> MarqueEntityView::get_transform() const{return optional_value<MarqueTransform>(std::get<std::optional<wire::Transform>>(values_));}
Ref<MarqueVitals> MarqueEntityView::get_vitals() const{return optional_value<MarqueVitals>(std::get<std::optional<wire::Vitals>>(values_));}
Ref<MarqueGear> MarqueEntityView::get_gear() const{return optional_value<MarqueGear>(std::get<std::optional<wire::Gear>>(values_));}
Ref<MarqueCastBar> MarqueEntityView::get_cast() const{return optional_value<MarqueCastBar>(std::get<std::optional<wire::CastBar>>(values_));}
Ref<MarqueLook> MarqueEntityView::get_look() const{return optional_value<MarqueLook>(std::get<std::optional<wire::Look>>(values_));}

void MarqueWorldView::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueWorldView::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_alpha"),&MarqueWorldView::get_alpha);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT,"alpha"),"","get_alpha");
    ClassDB::bind_method(D_METHOD("get_entities"),&MarqueWorldView::get_entities);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"entities"),"","get_entities");
}
TypedArray<MarqueEntityView> MarqueWorldView::get_entities() const{
    TypedArray<MarqueEntityView> out;
    if(value_) for(const auto& id:value_->current->world().entities()){
        client::Catalog::values values;
        auto fetch=[&]<class T>(){if(const auto* v=value_->current->world().table<T>().find(id))std::get<std::optional<T>>(values)=*v;};
        fetch.template operator()<wire::Transform>();fetch.template operator()<wire::Vitals>();
        fetch.template operator()<wire::Gear>();fetch.template operator()<wire::CastBar>();fetch.template operator()<wire::Look>();
        if(value_->previous){
            const auto* a=value_->previous->world().table<wire::Transform>().find(id);
            auto& b=std::get<std::optional<wire::Transform>>(values);
            if(a && b)b=client::Catalog::interpolate(*a,*b,alpha_);
        }
        Ref<MarqueEntityView> entry;entry.instantiate();entry->set_native(id,std::move(values));out.push_back(entry);
    }
    out.make_read_only();return out;
}

void MarqueOwnerView::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_inventory"),&MarqueOwnerView::get_inventory);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"inventory"),"","get_inventory");
    ClassDB::bind_method(D_METHOD("get_equipment"),&MarqueOwnerView::get_equipment);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"equipment"),"","get_equipment");
    ClassDB::bind_method(D_METHOD("get_role"),&MarqueOwnerView::get_role);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"role"),"","get_role");
    ClassDB::bind_method(D_METHOD("get_skills"),&MarqueOwnerView::get_skills);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"skills"),"","get_skills");
    ClassDB::bind_method(D_METHOD("get_quests"),&MarqueOwnerView::get_quests);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"quests"),"","get_quests");
    ClassDB::bind_method(D_METHOD("get_dialog"),&MarqueOwnerView::get_dialog);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"dialog"),"","get_dialog");
    ClassDB::bind_method(D_METHOD("get_party"),&MarqueOwnerView::get_party);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"party"),"","get_party");
    ClassDB::bind_method(D_METHOD("get_invite"),&MarqueOwnerView::get_invite);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"invite"),"","get_invite");
    ClassDB::bind_method(D_METHOD("get_admin"),&MarqueOwnerView::get_admin);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"admin"),"","get_admin");
    ClassDB::bind_method(D_METHOD("get_refusal"),&MarqueOwnerView::get_refusal);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"refusal"),"","get_refusal");
    ClassDB::bind_method(D_METHOD("get_cooldowns"),&MarqueOwnerView::get_cooldowns);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"cooldowns"),"","get_cooldowns");
}
Ref<MarqueInventory> MarqueOwnerView::get_inventory() const{return value_ ? optional_value<MarqueInventory>(value_->inventory) : Ref<MarqueInventory>{};}
Ref<MarqueEquipment> MarqueOwnerView::get_equipment() const{return value_ ? optional_value<MarqueEquipment>(value_->equipment) : Ref<MarqueEquipment>{};}
Ref<MarqueClass> MarqueOwnerView::get_role() const{return value_ ? optional_value<MarqueClass>(value_->role) : Ref<MarqueClass>{};}
Ref<MarqueSkills> MarqueOwnerView::get_skills() const{return value_ ? optional_value<MarqueSkills>(value_->skills) : Ref<MarqueSkills>{};}
Ref<MarqueQuestLog> MarqueOwnerView::get_quests() const{return value_ ? optional_value<MarqueQuestLog>(value_->quests) : Ref<MarqueQuestLog>{};}
Ref<MarqueDialog> MarqueOwnerView::get_dialog() const{return value_ ? optional_value<MarqueDialog>(value_->dialog) : Ref<MarqueDialog>{};}
Ref<MarqueParty> MarqueOwnerView::get_party() const{return value_ ? optional_value<MarqueParty>(value_->party) : Ref<MarqueParty>{};}
Ref<MarqueInvite> MarqueOwnerView::get_invite() const{return value_ ? optional_value<MarqueInvite>(value_->invite) : Ref<MarqueInvite>{};}
Ref<MarqueAdminReply> MarqueOwnerView::get_admin() const{return value_ ? optional_value<MarqueAdminReply>(value_->admin) : Ref<MarqueAdminReply>{};}
Ref<MarqueRefused> MarqueOwnerView::get_refusal() const{return value_ ? optional_value<MarqueRefused>(value_->refusal) : Ref<MarqueRefused>{};}
TypedArray<MarqueCooldown> MarqueOwnerView::get_cooldowns() const{
    TypedArray<MarqueCooldown> out;if(value_)for(const auto& [ability,value]:value_->cooldowns){(void)ability;out.push_back(marque_value<MarqueCooldown>(value));}
    out.make_read_only();return out;
}

void MarqueTickView::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueTickView::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueTickView::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_epoch"),&MarqueTickView::get_epoch);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"epoch"),"","get_epoch");
    ClassDB::bind_method(D_METHOD("get_event_end"),&MarqueTickView::get_event_end);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_end"),"","get_event_end");
    ClassDB::bind_method(D_METHOD("get_next_intent"),&MarqueTickView::get_next_intent);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"next_intent"),"","get_next_intent");
}
void MarqueCore::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_world"),&MarqueCore::get_world);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"world"),"","get_world");
    ClassDB::bind_method(D_METHOD("get_owner"),&MarqueCore::get_owner);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"owner"),"","get_owner");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueCore::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_prediction_available"),&MarqueCore::get_prediction_available);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL,"prediction_available"),"","get_prediction_available");
    ClassDB::bind_method(D_METHOD("get_predicted_local_pose"),&MarqueCore::get_predicted_local_pose);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"predicted_local_pose"),"","get_predicted_local_pose");
    ClassDB::bind_method(D_METHOD("get_connection"),&MarqueCore::get_connection);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"connection"),"","get_connection");
    ClassDB::bind_method(D_METHOD("get_error"),&MarqueCore::get_error);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"error"),"","get_error");
    ClassDB::bind_method(D_METHOD("move","dx","dz","jump"),&MarqueCore::move);
    ClassDB::bind_method(D_METHOD("pickup","item"),&MarqueCore::pickup);
    ClassDB::bind_method(D_METHOD("gather","node"),&MarqueCore::gather);
    ClassDB::bind_method(D_METHOD("drop","slot"),&MarqueCore::drop);
    ClassDB::bind_method(D_METHOD("equip","slot"),&MarqueCore::equip);
    ClassDB::bind_method(D_METHOD("unequip","worn"),&MarqueCore::unequip);
    ClassDB::bind_method(D_METHOD("use_self","slot"),&MarqueCore::use_self);
    ClassDB::bind_method(D_METHOD("use_station","slot","station"),&MarqueCore::use_station);
    ClassDB::bind_method(D_METHOD("attack_player","target"),&MarqueCore::attack_player);
    ClassDB::bind_method(D_METHOD("attack_npc","target"),&MarqueCore::attack_npc);
    ClassDB::bind_method(D_METHOD("respawn"),&MarqueCore::respawn);
    ClassDB::bind_method(D_METHOD("cast_self","ability"),&MarqueCore::cast_self);
    ClassDB::bind_method(D_METHOD("cast_player","ability","target"),&MarqueCore::cast_player);
    ClassDB::bind_method(D_METHOD("cast_npc","ability","target"),&MarqueCore::cast_npc);
    ClassDB::bind_method(D_METHOD("talk","npc"),&MarqueCore::talk);
    ClassDB::bind_method(D_METHOD("dialog_option","npc","option"),&MarqueCore::dialog_option);
    ClassDB::bind_method(D_METHOD("give","npc","slot"),&MarqueCore::give);
    ClassDB::bind_method(D_METHOD("party_invite","target"),&MarqueCore::party_invite);
    ClassDB::bind_method(D_METHOD("party_accept"),&MarqueCore::party_accept);
    ClassDB::bind_method(D_METHOD("party_decline"),&MarqueCore::party_decline);
    ClassDB::bind_method(D_METHOD("party_leave"),&MarqueCore::party_leave);
    ClassDB::bind_method(D_METHOD("party_kick","target"),&MarqueCore::party_kick);
    ClassDB::bind_method(D_METHOD("admin","line"),&MarqueCore::admin);
    ADD_SIGNAL(MethodInfo("tick_applied",PropertyInfo(Variant::OBJECT,"tick",PROPERTY_HINT_RESOURCE_TYPE,"MarqueTickView")));
    ADD_SIGNAL(MethodInfo("inventory_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueInventory")));
    ADD_SIGNAL(MethodInfo("equipment_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueEquipment")));
    ADD_SIGNAL(MethodInfo("class_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueClass")));
    ADD_SIGNAL(MethodInfo("skills_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueSkills")));
    ADD_SIGNAL(MethodInfo("quests_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueQuestLog")));
    ADD_SIGNAL(MethodInfo("dialog_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueDialog")));
    ADD_SIGNAL(MethodInfo("party_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueParty")));
    ADD_SIGNAL(MethodInfo("invite_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueInvite")));
    ADD_SIGNAL(MethodInfo("admin_reply",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueAdminReply")));
    ADD_SIGNAL(MethodInfo("cooldown_changed",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueCooldown")));
    ADD_SIGNAL(MethodInfo("refused",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueRefused")));
    ADD_SIGNAL(MethodInfo("dialog_cleared",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueDialogClear")));
    ADD_SIGNAL(MethodInfo("party_cleared",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarquePartyClear")));
    ADD_SIGNAL(MethodInfo("invite_cleared",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueInviteClear")));
    ADD_SIGNAL(MethodInfo("swing",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueSwing")));
    ADD_SIGNAL(MethodInfo("cast_phase",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueCastPhase")));
    ADD_SIGNAL(MethodInfo("gather_start",PropertyInfo(Variant::OBJECT,"value",PROPERTY_HINT_RESOURCE_TYPE,"MarqueGatherStart")));
}
Ref<MarqueWorldView> MarqueCore::get_world() const{
    Ref<MarqueWorldView> value;value.instantiate();
    if(publication_){
        double alpha=1;
        if(publication_->previous){
            const auto a=publication_->previous->sample_time().microseconds;
            const auto b=publication_->current->sample_time().microseconds;
            const auto now=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
            alpha=static_cast<double>(std::clamp((static_cast<long double>(now)-40000-a)/(b-a),0.0L,1.0L));
        }
        value->set_native(*publication_,alpha);
    }
    return value;
}
Ref<MarqueOwnerView> MarqueCore::get_owner() const{
    Ref<MarqueOwnerView> value;value.instantiate();if(publication_)value->set_native(publication_->current->events().owner);return value;
}
Ref<MarqueTickView> MarqueCore::get_tick() const{
    Ref<MarqueTickView> value;value.instantiate();if(publication_)value->set_native(publication_->current);return value;
}
void MarqueCore::latch(client::Publication publication){
    publication_=std::move(publication);
    for(const auto& event:publication_->current->events().changes)std::visit([&](const auto& value){
        using T=std::decay_t<decltype(value)>;
        if constexpr(std::is_same_v<T,wire::Inventory>)emit_signal("inventory_changed",marque_value<MarqueInventory>(value));
        else if constexpr(std::is_same_v<T,wire::Equipment>)emit_signal("equipment_changed",marque_value<MarqueEquipment>(value));
        else if constexpr(std::is_same_v<T,wire::Class>)emit_signal("class_changed",marque_value<MarqueClass>(value));
        else if constexpr(std::is_same_v<T,wire::Skills>)emit_signal("skills_changed",marque_value<MarqueSkills>(value));
        else if constexpr(std::is_same_v<T,wire::QuestLog>)emit_signal("quests_changed",marque_value<MarqueQuestLog>(value));
        else if constexpr(std::is_same_v<T,wire::Dialog>)emit_signal("dialog_changed",marque_value<MarqueDialog>(value));
        else if constexpr(std::is_same_v<T,wire::Party>)emit_signal("party_changed",marque_value<MarqueParty>(value));
        else if constexpr(std::is_same_v<T,wire::Invite>)emit_signal("invite_changed",marque_value<MarqueInvite>(value));
        else if constexpr(std::is_same_v<T,wire::AdminReply>)emit_signal("admin_reply",marque_value<MarqueAdminReply>(value));
        else if constexpr(std::is_same_v<T,wire::Cooldown>)emit_signal("cooldown_changed",marque_value<MarqueCooldown>(value));
        else if constexpr(std::is_same_v<T,wire::Refused>)emit_signal("refused",marque_value<MarqueRefused>(value));
        else if constexpr(std::is_same_v<T,wire::DialogClear>)emit_signal("dialog_cleared",marque_value<MarqueDialogClear>(value));
        else if constexpr(std::is_same_v<T,wire::PartyClear>)emit_signal("party_cleared",marque_value<MarquePartyClear>(value));
        else if constexpr(std::is_same_v<T,wire::InviteClear>)emit_signal("invite_cleared",marque_value<MarqueInviteClear>(value));
    },event);
    for(const auto& event:publication_->current->events().presentation)std::visit([&](const auto& value){
        using T=std::decay_t<decltype(value)>;
        if constexpr(std::is_same_v<T,wire::Swing>)emit_signal("swing",marque_value<MarqueSwing>(value));
        else if constexpr(std::is_same_v<T,wire::CastPhase>)emit_signal("cast_phase",marque_value<MarqueCastPhase>(value));
        else if constexpr(std::is_same_v<T,wire::GatherStart>)emit_signal("gather_start",marque_value<MarqueGatherStart>(value));
    },event);
    emit_signal("tick_applied",get_tick());
}
bool MarqueCore::move(double dx,double dz,bool jump){return runtime_ && runtime_->move(dx,dz,jump);}
bool MarqueCore::pickup(const Ref<MarqueItemHandle>& item){auto id=target_native<wire::ItemId,MarqueItemHandle,world::Item>(item);return runtime_ && id && runtime_->queue(wire::PickupFields{0,*id});}
bool MarqueCore::gather(const Ref<MarqueNodeHandle>& node){auto id=target_native<wire::NodeId,MarqueNodeHandle,world::Node>(node);return runtime_ && id && runtime_->queue(wire::GatherFields{0,*id});}
bool MarqueCore::attack_player(const Ref<MarquePlayerHandle>& target){auto id=target_native<wire::PlayerId,MarquePlayerHandle,world::Player>(target);return runtime_ && id && runtime_->queue(wire::AttackPlayerFields{0,*id});}
bool MarqueCore::attack_npc(const Ref<MarqueNpcHandle>& target){auto id=target_native<wire::NpcId,MarqueNpcHandle,world::Npc>(target);return runtime_ && id && runtime_->queue(wire::AttackNpcFields{0,*id});}
bool MarqueCore::talk(const Ref<MarqueNpcHandle>& npc){auto id=target_native<wire::NpcId,MarqueNpcHandle,world::Npc>(npc);return runtime_ && id && runtime_->queue(wire::TalkFields{0,*id});}
bool MarqueCore::party_invite(const Ref<MarquePlayerHandle>& target){auto id=target_native<wire::PlayerId,MarquePlayerHandle,world::Player>(target);return runtime_ && id && runtime_->queue(wire::PartyInviteFields{0,*id});}
bool MarqueCore::party_kick(const Ref<MarquePlayerHandle>& target){auto id=target_native<wire::PlayerId,MarquePlayerHandle,world::Player>(target);return runtime_ && id && runtime_->queue(wire::PartyKickFields{0,*id});}
bool MarqueCore::drop(int64_t slot){return runtime_ && slot>=0 && slot<28 && runtime_->queue(wire::DropFields{0,static_cast<std::uint8_t>(slot)});}
bool MarqueCore::equip(int64_t slot){return runtime_ && slot>=0 && slot<28 && runtime_->queue(wire::EquipFields{0,static_cast<std::uint8_t>(slot)});}
bool MarqueCore::use_self(int64_t slot){return runtime_ && slot>=0 && slot<28 && runtime_->queue(wire::UseSelfFields{0,static_cast<std::uint8_t>(slot)});}
bool MarqueCore::unequip(const String& worn){return runtime_ && runtime_->queue(wire::UnequipFields{0,text(worn)});}
bool MarqueCore::cast_self(const String& ability){return runtime_ && runtime_->queue(wire::CastSelfFields{0,text(ability)});}
bool MarqueCore::admin(const String& line){return runtime_ && runtime_->queue(wire::AdminFields{0,text(line)});}
bool MarqueCore::respawn(){return runtime_ && runtime_->queue(wire::RespawnFields{0});}
bool MarqueCore::party_accept(){return runtime_ && runtime_->queue(wire::PartyAcceptFields{0});}
bool MarqueCore::party_decline(){return runtime_ && runtime_->queue(wire::PartyDeclineFields{0});}
bool MarqueCore::party_leave(){return runtime_ && runtime_->queue(wire::PartyLeaveFields{0});}
bool MarqueCore::cast_player(const String& ability,const Ref<MarquePlayerHandle>& value){auto id=target_native<wire::PlayerId,MarquePlayerHandle,world::Player>(value);return runtime_ && id && runtime_->queue(wire::CastPlayerFields{0,text(ability),*id});}
bool MarqueCore::cast_npc(const String& ability,const Ref<MarqueNpcHandle>& value){auto id=target_native<wire::NpcId,MarqueNpcHandle,world::Npc>(value);return runtime_ && id && runtime_->queue(wire::CastNpcFields{0,text(ability),*id});}
bool MarqueCore::use_station(int64_t slot,const Ref<MarqueNodeHandle>& station){auto id=target_native<wire::NodeId,MarqueNodeHandle,world::Node>(station);return runtime_ && id && slot>=0 && slot<28 && runtime_->queue(wire::UseStationFields{0,static_cast<std::uint8_t>(slot),*id});}
bool MarqueCore::dialog_option(const Ref<MarqueNpcHandle>& npc,const String& option){auto id=target_native<wire::NpcId,MarqueNpcHandle,world::Npc>(npc);return runtime_ && id && runtime_->queue(wire::DialogOptionFields{0,*id,text(option)});}
bool MarqueCore::give(const Ref<MarqueNpcHandle>& npc,int64_t slot){auto id=target_native<wire::NpcId,MarqueNpcHandle,world::Npc>(npc);return runtime_ && id && slot>=0 && slot<28 && runtime_->queue(wire::GiveFields{0,*id,static_cast<std::uint8_t>(slot)});}

void MarqueRuntime::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_core"),&MarqueRuntime::get_core);
    ClassDB::bind_method(D_METHOD("connect_token","token"),&MarqueRuntime::connect_token);
    ClassDB::bind_method(D_METHOD("disconnect"),&MarqueRuntime::disconnect);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"core",PROPERTY_HINT_RESOURCE_TYPE,"MarqueCore"),"","get_core");
}
MarqueRuntime::MarqueRuntime(){runtime_=std::make_shared<client::Runtime>();core_.instantiate();core_->attach(runtime_);}
MarqueRuntime::~MarqueRuntime(){runtime_->disconnect();}
bool MarqueRuntime::connect_token(const PackedByteArray& token){return is_inside_tree() && runtime_->connect(std::span<const std::uint8_t>(token.ptr(),token.size()));}
void MarqueRuntime::disconnect(){runtime_->disconnect();}
void MarqueRuntime::_notification(int what){
    if(what==NOTIFICATION_ENTER_TREE){set_process_mode(PROCESS_MODE_ALWAYS);set_process_internal(true);}
    else if(what==NOTIFICATION_EXIT_TREE){set_process_internal(false);runtime_->disconnect();}
    else if(what==NOTIFICATION_INTERNAL_PROCESS)for(std::size_t count=0;count<64;++count){auto publication=runtime_->take();if(!publication)break;core_->latch(std::move(*publication));}
}
