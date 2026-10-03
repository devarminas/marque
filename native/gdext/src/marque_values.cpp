#include "marque_values.hpp"
#include <godot_cpp/core/class_db.hpp>
using namespace godot;
using namespace marque;

void MarqueId64::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_high"),&MarqueId64::get_high);
    ClassDB::bind_method(D_METHOD("get_low"),&MarqueId64::get_low);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"high"),"","get_high");
    ADD_PROPERTY(PropertyInfo(Variant::INT,"low"),"","get_low");
}
void MarqueHandle::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_valid"),&MarqueHandle::get_valid);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL,"valid"),"","get_valid");
    ClassDB::bind_method(D_METHOD("get_kind"),&MarqueHandle::get_kind);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"kind"),"","get_kind");
    ClassDB::bind_method(D_METHOD("get_index"),&MarqueHandle::get_index);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"index"),"","get_index");
    ClassDB::bind_method(D_METHOD("get_generation"),&MarqueHandle::get_generation);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"generation"),"","get_generation");
}
Ref<MarqueHandle> marque_handle(world::Entity value){
    return std::visit([](auto v)->Ref<MarqueHandle>{
        using T=std::decay_t<decltype(v)>;
        if constexpr(std::is_same_v<T,world::Player>) return marque_value<MarquePlayerHandle>(wire::PlayerId{v.index,v.generation});
        else if constexpr(std::is_same_v<T,world::Npc>) return marque_value<MarqueNpcHandle>(wire::NpcId{v.index,v.generation});
        else if constexpr(std::is_same_v<T,world::Item>) return marque_value<MarqueItemHandle>(wire::ItemId{v.index,v.generation});
        else return marque_value<MarqueNodeHandle>(wire::NodeId{v.index,v.generation});
    },value);
}

void MarqueBagEntry::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_slot"),&MarqueBagEntry::get_slot);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"slot"),"","get_slot");
    ClassDB::bind_method(D_METHOD("get_kind"),&MarqueBagEntry::get_kind);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"kind"),"","get_kind");
}
int64_t MarqueBagEntry::get_slot() const{return value_ ? static_cast<int64_t>(value_->slot()) : 0;}
godot::String MarqueBagEntry::get_kind() const{return value_ ? godot::String::utf8(value_->kind().data(),value_->kind().size()) : godot::String{};}

void MarqueWornName::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_name"),&MarqueWornName::get_name);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"name"),"","get_name");
}
godot::String MarqueWornName::get_name() const{return value_ ? godot::String::utf8(value_->name().data(),value_->name().size()) : godot::String{};}

void MarqueWornEntry::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_slot"),&MarqueWornEntry::get_slot);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"slot"),"","get_slot");
    ClassDB::bind_method(D_METHOD("get_kind"),&MarqueWornEntry::get_kind);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"kind"),"","get_kind");
}
godot::String MarqueWornEntry::get_slot() const{return value_ ? godot::String::utf8(value_->slot().data(),value_->slot().size()) : godot::String{};}
godot::String MarqueWornEntry::get_kind() const{return value_ ? godot::String::utf8(value_->kind().data(),value_->kind().size()) : godot::String{};}

void MarqueToolEntry::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_kind"),&MarqueToolEntry::get_kind);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"kind"),"","get_kind");
}
godot::String MarqueToolEntry::get_kind() const{return value_ ? godot::String::utf8(value_->kind().data(),value_->kind().size()) : godot::String{};}

void MarqueSkillEntry::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_id"),&MarqueSkillEntry::get_id);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"id"),"","get_id");
    ClassDB::bind_method(D_METHOD("get_xp"),&MarqueSkillEntry::get_xp);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"xp"),"","get_xp");
    ClassDB::bind_method(D_METHOD("get_level"),&MarqueSkillEntry::get_level);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"level"),"","get_level");
}
godot::String MarqueSkillEntry::get_id() const{return value_ ? godot::String::utf8(value_->id().data(),value_->id().size()) : godot::String{};}
int64_t MarqueSkillEntry::get_xp() const{return value_ ? static_cast<int64_t>(value_->xp()) : 0;}
int64_t MarqueSkillEntry::get_level() const{return value_ ? static_cast<int64_t>(value_->level()) : 0;}

void MarqueQuestEntry::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_id"),&MarqueQuestEntry::get_id);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"id"),"","get_id");
    ClassDB::bind_method(D_METHOD("get_title"),&MarqueQuestEntry::get_title);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"title"),"","get_title");
    ClassDB::bind_method(D_METHOD("get_objective"),&MarqueQuestEntry::get_objective);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"objective"),"","get_objective");
    ClassDB::bind_method(D_METHOD("get_status"),&MarqueQuestEntry::get_status);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"status"),"","get_status");
}
godot::String MarqueQuestEntry::get_id() const{return value_ ? godot::String::utf8(value_->id().data(),value_->id().size()) : godot::String{};}
godot::String MarqueQuestEntry::get_title() const{return value_ ? godot::String::utf8(value_->title().data(),value_->title().size()) : godot::String{};}
godot::String MarqueQuestEntry::get_objective() const{return value_ ? godot::String::utf8(value_->objective().data(),value_->objective().size()) : godot::String{};}
godot::String MarqueQuestEntry::get_status() const{return value_ ? godot::String::utf8(value_->status().data(),value_->status().size()) : godot::String{};}

void MarqueTextLine::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_text"),&MarqueTextLine::get_text);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"text"),"","get_text");
}
godot::String MarqueTextLine::get_text() const{return value_ ? godot::String::utf8(value_->text().data(),value_->text().size()) : godot::String{};}

void MarqueDialogChoice::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_id"),&MarqueDialogChoice::get_id);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"id"),"","get_id");
}
godot::String MarqueDialogChoice::get_id() const{return value_ ? godot::String::utf8(value_->id().data(),value_->id().size()) : godot::String{};}

void MarqueTransform::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_x"),&MarqueTransform::get_x);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT,"x"),"","get_x");
    ClassDB::bind_method(D_METHOD("get_y"),&MarqueTransform::get_y);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT,"y"),"","get_y");
    ClassDB::bind_method(D_METHOD("get_z"),&MarqueTransform::get_z);
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT,"z"),"","get_z");
}
double MarqueTransform::get_x() const{return value_ ? value_->x() : 0;}
double MarqueTransform::get_y() const{return value_ ? value_->y() : 0;}
double MarqueTransform::get_z() const{return value_ ? value_->z() : 0;}

void MarqueVitals::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_hp"),&MarqueVitals::get_hp);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"hp"),"","get_hp");
    ClassDB::bind_method(D_METHOD("get_max_hp"),&MarqueVitals::get_max_hp);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"max_hp"),"","get_max_hp");
    ClassDB::bind_method(D_METHOD("get_mana"),&MarqueVitals::get_mana);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"mana"),"","get_mana");
    ClassDB::bind_method(D_METHOD("get_max_mana"),&MarqueVitals::get_max_mana);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"max_mana"),"","get_max_mana");
}
int64_t MarqueVitals::get_hp() const{return value_ ? static_cast<int64_t>(value_->hp()) : 0;}
int64_t MarqueVitals::get_max_hp() const{return value_ ? static_cast<int64_t>(value_->max_hp()) : 0;}
int64_t MarqueVitals::get_mana() const{return value_ ? static_cast<int64_t>(value_->mana()) : 0;}
int64_t MarqueVitals::get_max_mana() const{return value_ ? static_cast<int64_t>(value_->max_mana()) : 0;}

void MarqueGear::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_helmet"),&MarqueGear::get_helmet);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"helmet"),"","get_helmet");
    ClassDB::bind_method(D_METHOD("get_chest"),&MarqueGear::get_chest);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"chest"),"","get_chest");
    ClassDB::bind_method(D_METHOD("get_trousers"),&MarqueGear::get_trousers);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"trousers"),"","get_trousers");
    ClassDB::bind_method(D_METHOD("get_feet"),&MarqueGear::get_feet);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"feet"),"","get_feet");
    ClassDB::bind_method(D_METHOD("get_left_hand"),&MarqueGear::get_left_hand);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"left_hand"),"","get_left_hand");
    ClassDB::bind_method(D_METHOD("get_right_hand"),&MarqueGear::get_right_hand);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"right_hand"),"","get_right_hand");
}
godot::String MarqueGear::get_helmet() const{return value_ && value_->helmet() ? godot::String::utf8(value_->helmet()->data(),value_->helmet()->size()) : godot::String{};}
godot::String MarqueGear::get_chest() const{return value_ && value_->chest() ? godot::String::utf8(value_->chest()->data(),value_->chest()->size()) : godot::String{};}
godot::String MarqueGear::get_trousers() const{return value_ && value_->trousers() ? godot::String::utf8(value_->trousers()->data(),value_->trousers()->size()) : godot::String{};}
godot::String MarqueGear::get_feet() const{return value_ && value_->feet() ? godot::String::utf8(value_->feet()->data(),value_->feet()->size()) : godot::String{};}
godot::String MarqueGear::get_left_hand() const{return value_ && value_->left_hand() ? godot::String::utf8(value_->left_hand()->data(),value_->left_hand()->size()) : godot::String{};}
godot::String MarqueGear::get_right_hand() const{return value_ && value_->right_hand() ? godot::String::utf8(value_->right_hand()->data(),value_->right_hand()->size()) : godot::String{};}

void MarqueCasting::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_ability"),&MarqueCasting::get_ability);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"ability"),"","get_ability");
    ClassDB::bind_method(D_METHOD("get_start"),&MarqueCasting::get_start);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"start"),"","get_start");
    ClassDB::bind_method(D_METHOD("get_ticks"),&MarqueCasting::get_ticks);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"ticks"),"","get_ticks");
}
godot::String MarqueCasting::get_ability() const{return value_ ? godot::String::utf8(value_->ability().data(),value_->ability().size()) : godot::String{};}
int64_t MarqueCasting::get_start() const{return value_ ? static_cast<int64_t>(value_->start()) : 0;}
int64_t MarqueCasting::get_ticks() const{return value_ ? static_cast<int64_t>(value_->ticks()) : 0;}

void MarqueCastBar::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_casting"),&MarqueCastBar::get_casting);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"casting",PROPERTY_HINT_RESOURCE_TYPE,"MarqueCasting"),"","get_casting");
}
godot::Ref<MarqueCasting> MarqueCastBar::get_casting() const{return value_ && value_->casting() ? marque_value<MarqueCasting>(*value_->casting()) : godot::Ref<MarqueCasting>{};}

void MarqueLook::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_kind"),&MarqueLook::get_kind);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"kind"),"","get_kind");
}
godot::String MarqueLook::get_kind() const{return value_ ? godot::String::utf8(value_->kind().data(),value_->kind().size()) : godot::String{};}

void MarqueInventory::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueInventory::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueInventory::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueInventory::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_size"),&MarqueInventory::get_size);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"size"),"","get_size");
    ClassDB::bind_method(D_METHOD("get_slots"),&MarqueInventory::get_slots);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"slots",PROPERTY_HINT_ARRAY_TYPE,"MarqueBagEntry"),"","get_slots");
}
godot::Ref<MarqueId64> MarqueInventory::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueInventory::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueInventory::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
int64_t MarqueInventory::get_size() const{return value_ ? static_cast<int64_t>(value_->size()) : 0;}
godot::TypedArray<MarqueBagEntry> MarqueInventory::get_slots() const{godot::TypedArray<MarqueBagEntry> out;if(value_)for(const auto& v:value_->slots())out.push_back(marque_value<MarqueBagEntry>(v));out.make_read_only();return out;}

void MarqueEquipment::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueEquipment::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueEquipment::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueEquipment::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_worn"),&MarqueEquipment::get_worn);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"worn",PROPERTY_HINT_ARRAY_TYPE,"MarqueWornName"),"","get_worn");
    ClassDB::bind_method(D_METHOD("get_slots"),&MarqueEquipment::get_slots);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"slots",PROPERTY_HINT_ARRAY_TYPE,"MarqueWornEntry"),"","get_slots");
}
godot::Ref<MarqueId64> MarqueEquipment::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueEquipment::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueEquipment::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::TypedArray<MarqueWornName> MarqueEquipment::get_worn() const{godot::TypedArray<MarqueWornName> out;if(value_)for(const auto& v:value_->worn())out.push_back(marque_value<MarqueWornName>(v));out.make_read_only();return out;}
godot::TypedArray<MarqueWornEntry> MarqueEquipment::get_slots() const{godot::TypedArray<MarqueWornEntry> out;if(value_)for(const auto& v:value_->slots())out.push_back(marque_value<MarqueWornEntry>(v));out.make_read_only();return out;}

void MarqueClass::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueClass::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueClass::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueClass::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_class_id"),&MarqueClass::get_class_id);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"class_id"),"","get_class_id");
    ClassDB::bind_method(D_METHOD("get_missing_slots"),&MarqueClass::get_missing_slots);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"missing_slots",PROPERTY_HINT_ARRAY_TYPE,"MarqueWornEntry"),"","get_missing_slots");
    ClassDB::bind_method(D_METHOD("get_missing_tools"),&MarqueClass::get_missing_tools);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"missing_tools",PROPERTY_HINT_ARRAY_TYPE,"MarqueToolEntry"),"","get_missing_tools");
}
godot::Ref<MarqueId64> MarqueClass::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueClass::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueClass::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::String MarqueClass::get_class_id() const{return value_ ? godot::String::utf8(value_->class_id().data(),value_->class_id().size()) : godot::String{};}
godot::TypedArray<MarqueWornEntry> MarqueClass::get_missing_slots() const{godot::TypedArray<MarqueWornEntry> out;if(value_)for(const auto& v:value_->missing_slots())out.push_back(marque_value<MarqueWornEntry>(v));out.make_read_only();return out;}
godot::TypedArray<MarqueToolEntry> MarqueClass::get_missing_tools() const{godot::TypedArray<MarqueToolEntry> out;if(value_)for(const auto& v:value_->missing_tools())out.push_back(marque_value<MarqueToolEntry>(v));out.make_read_only();return out;}

void MarqueSkills::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueSkills::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueSkills::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueSkills::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_skills"),&MarqueSkills::get_skills);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"skills",PROPERTY_HINT_ARRAY_TYPE,"MarqueSkillEntry"),"","get_skills");
}
godot::Ref<MarqueId64> MarqueSkills::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueSkills::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueSkills::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::TypedArray<MarqueSkillEntry> MarqueSkills::get_skills() const{godot::TypedArray<MarqueSkillEntry> out;if(value_)for(const auto& v:value_->skills())out.push_back(marque_value<MarqueSkillEntry>(v));out.make_read_only();return out;}

void MarqueQuestLog::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueQuestLog::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueQuestLog::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueQuestLog::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_quests"),&MarqueQuestLog::get_quests);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"quests",PROPERTY_HINT_ARRAY_TYPE,"MarqueQuestEntry"),"","get_quests");
}
godot::Ref<MarqueId64> MarqueQuestLog::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueQuestLog::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueQuestLog::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::TypedArray<MarqueQuestEntry> MarqueQuestLog::get_quests() const{godot::TypedArray<MarqueQuestEntry> out;if(value_)for(const auto& v:value_->quests())out.push_back(marque_value<MarqueQuestEntry>(v));out.make_read_only();return out;}

void MarqueDialog::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueDialog::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueDialog::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueDialog::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_npc"),&MarqueDialog::get_npc);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"npc",PROPERTY_HINT_RESOURCE_TYPE,"MarqueNpcHandle"),"","get_npc");
    ClassDB::bind_method(D_METHOD("get_lines"),&MarqueDialog::get_lines);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"lines",PROPERTY_HINT_ARRAY_TYPE,"MarqueTextLine"),"","get_lines");
    ClassDB::bind_method(D_METHOD("get_options"),&MarqueDialog::get_options);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"options",PROPERTY_HINT_ARRAY_TYPE,"MarqueDialogChoice"),"","get_options");
}
godot::Ref<MarqueId64> MarqueDialog::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueDialog::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueDialog::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarqueNpcHandle> MarqueDialog::get_npc() const{return value_ ? marque_value<MarqueNpcHandle>(value_->npc()) : godot::Ref<MarqueNpcHandle>{};}
godot::TypedArray<MarqueTextLine> MarqueDialog::get_lines() const{godot::TypedArray<MarqueTextLine> out;if(value_)for(const auto& v:value_->lines())out.push_back(marque_value<MarqueTextLine>(v));out.make_read_only();return out;}
godot::TypedArray<MarqueDialogChoice> MarqueDialog::get_options() const{godot::TypedArray<MarqueDialogChoice> out;if(value_)for(const auto& v:value_->options())out.push_back(marque_value<MarqueDialogChoice>(v));out.make_read_only();return out;}

void MarqueParty::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueParty::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueParty::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueParty::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_id"),&MarqueParty::get_id);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"id",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_id");
    ClassDB::bind_method(D_METHOD("get_leader"),&MarqueParty::get_leader);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"leader",PROPERTY_HINT_RESOURCE_TYPE,"MarquePlayerHandle"),"","get_leader");
    ClassDB::bind_method(D_METHOD("get_members"),&MarqueParty::get_members);
    ADD_PROPERTY(PropertyInfo(Variant::ARRAY,"members",PROPERTY_HINT_ARRAY_TYPE,"MarquePlayerHandle"),"","get_members");
}
godot::Ref<MarqueId64> MarqueParty::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueParty::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueParty::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarqueId64> MarqueParty::get_id() const{return marque_value<MarqueId64>(value_ ? value_->id() : 0);}
godot::Ref<MarquePlayerHandle> MarqueParty::get_leader() const{return value_ ? marque_value<MarquePlayerHandle>(value_->leader()) : godot::Ref<MarquePlayerHandle>{};}
godot::TypedArray<MarquePlayerHandle> MarqueParty::get_members() const{godot::TypedArray<MarquePlayerHandle> out;if(value_)for(const auto& v:value_->members())out.push_back(marque_value<MarquePlayerHandle>(v));out.make_read_only();return out;}

void MarqueInvite::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueInvite::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueInvite::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueInvite::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_from"),&MarqueInvite::get_from);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"from",PROPERTY_HINT_RESOURCE_TYPE,"MarquePlayerHandle"),"","get_from");
}
godot::Ref<MarqueId64> MarqueInvite::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueInvite::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueInvite::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarquePlayerHandle> MarqueInvite::get_from() const{return value_ ? marque_value<MarquePlayerHandle>(value_->from()) : godot::Ref<MarquePlayerHandle>{};}

void MarqueAdminReply::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueAdminReply::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueAdminReply::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueAdminReply::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_text"),&MarqueAdminReply::get_text);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"text"),"","get_text");
}
godot::Ref<MarqueId64> MarqueAdminReply::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueAdminReply::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueAdminReply::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::String MarqueAdminReply::get_text() const{return value_ ? godot::String::utf8(value_->text().data(),value_->text().size()) : godot::String{};}

void MarqueCooldown::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueCooldown::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueCooldown::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueCooldown::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_ability"),&MarqueCooldown::get_ability);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"ability"),"","get_ability");
    ClassDB::bind_method(D_METHOD("get_ready_tick"),&MarqueCooldown::get_ready_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"ready_tick"),"","get_ready_tick");
}
godot::Ref<MarqueId64> MarqueCooldown::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueCooldown::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueCooldown::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::String MarqueCooldown::get_ability() const{return value_ ? godot::String::utf8(value_->ability().data(),value_->ability().size()) : godot::String{};}
int64_t MarqueCooldown::get_ready_tick() const{return value_ ? static_cast<int64_t>(value_->ready_tick()) : 0;}

void MarqueRefused::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueRefused::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueRefused::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueRefused::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_source"),&MarqueRefused::get_source);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"source"),"","get_source");
    ClassDB::bind_method(D_METHOD("get_seq"),&MarqueRefused::get_seq);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"seq"),"","get_seq");
    ClassDB::bind_method(D_METHOD("get_reason"),&MarqueRefused::get_reason);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"reason"),"","get_reason");
}
godot::Ref<MarqueId64> MarqueRefused::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueRefused::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueRefused::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
int64_t MarqueRefused::get_source() const{return value_ ? static_cast<int64_t>(value_->source()) : 0;}
int64_t MarqueRefused::get_seq() const{return value_ ? static_cast<int64_t>(value_->seq()) : 0;}
int64_t MarqueRefused::get_reason() const{return value_ ? static_cast<int64_t>(value_->reason()) : 0;}

void MarqueDialogClear::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueDialogClear::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueDialogClear::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueDialogClear::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_npc"),&MarqueDialogClear::get_npc);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"npc",PROPERTY_HINT_RESOURCE_TYPE,"MarqueNpcHandle"),"","get_npc");
}
godot::Ref<MarqueId64> MarqueDialogClear::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueDialogClear::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueDialogClear::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarqueNpcHandle> MarqueDialogClear::get_npc() const{return value_ ? marque_value<MarqueNpcHandle>(value_->npc()) : godot::Ref<MarqueNpcHandle>{};}

void MarquePartyClear::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarquePartyClear::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarquePartyClear::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarquePartyClear::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
}
godot::Ref<MarqueId64> MarquePartyClear::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarquePartyClear::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarquePartyClear::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}

void MarqueInviteClear::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_stream"),&MarqueInviteClear::get_stream);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"stream",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_stream");
    ClassDB::bind_method(D_METHOD("get_event_seq"),&MarqueInviteClear::get_event_seq);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"event_seq",PROPERTY_HINT_RESOURCE_TYPE,"MarqueId64"),"","get_event_seq");
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueInviteClear::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
}
godot::Ref<MarqueId64> MarqueInviteClear::get_stream() const{return marque_value<MarqueId64>(value_ ? value_->stream() : 0);}
godot::Ref<MarqueId64> MarqueInviteClear::get_event_seq() const{return marque_value<MarqueId64>(value_ ? value_->event_seq() : 0);}
int64_t MarqueInviteClear::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}

void MarqueSwing::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueSwing::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_attacker"),&MarqueSwing::get_attacker);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"attacker",PROPERTY_HINT_RESOURCE_TYPE,"MarqueHandle"),"","get_attacker");
    ClassDB::bind_method(D_METHOD("get_target"),&MarqueSwing::get_target);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"target",PROPERTY_HINT_RESOURCE_TYPE,"MarqueHandle"),"","get_target");
    ClassDB::bind_method(D_METHOD("get_amount"),&MarqueSwing::get_amount);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"amount"),"","get_amount");
    ClassDB::bind_method(D_METHOD("get_crit"),&MarqueSwing::get_crit);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL,"crit"),"","get_crit");
    ClassDB::bind_method(D_METHOD("get_miss"),&MarqueSwing::get_miss);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL,"miss"),"","get_miss");
}
int64_t MarqueSwing::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarqueHandle> MarqueSwing::get_attacker() const{return value_ ? std::visit([](auto v)->godot::Ref<MarqueHandle>{using T=std::decay_t<decltype(v)>;if constexpr(std::is_same_v<T,marque::wire::PlayerId>)return marque_value<MarquePlayerHandle>(v);else return marque_value<MarqueNpcHandle>(v);},value_->attacker()) : godot::Ref<MarqueHandle>{};}
godot::Ref<MarqueHandle> MarqueSwing::get_target() const{return value_ ? std::visit([](auto v)->godot::Ref<MarqueHandle>{using T=std::decay_t<decltype(v)>;if constexpr(std::is_same_v<T,marque::wire::PlayerId>)return marque_value<MarquePlayerHandle>(v);else return marque_value<MarqueNpcHandle>(v);},value_->target()) : godot::Ref<MarqueHandle>{};}
int64_t MarqueSwing::get_amount() const{return value_ ? static_cast<int64_t>(value_->amount()) : 0;}
bool MarqueSwing::get_crit() const{return value_ && value_->crit();}
bool MarqueSwing::get_miss() const{return value_ && value_->miss();}

void MarqueCastPhase::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueCastPhase::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_caster"),&MarqueCastPhase::get_caster);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"caster",PROPERTY_HINT_RESOURCE_TYPE,"MarqueHandle"),"","get_caster");
    ClassDB::bind_method(D_METHOD("get_ability"),&MarqueCastPhase::get_ability);
    ADD_PROPERTY(PropertyInfo(Variant::STRING,"ability"),"","get_ability");
    ClassDB::bind_method(D_METHOD("get_step"),&MarqueCastPhase::get_step);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"step"),"","get_step");
    ClassDB::bind_method(D_METHOD("get_target"),&MarqueCastPhase::get_target);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"target",PROPERTY_HINT_RESOURCE_TYPE,"MarqueHandle"),"","get_target");
    ClassDB::bind_method(D_METHOD("get_amount"),&MarqueCastPhase::get_amount);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"amount"),"","get_amount");
}
int64_t MarqueCastPhase::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarqueHandle> MarqueCastPhase::get_caster() const{return value_ ? std::visit([](auto v)->godot::Ref<MarqueHandle>{using T=std::decay_t<decltype(v)>;if constexpr(std::is_same_v<T,marque::wire::PlayerId>)return marque_value<MarquePlayerHandle>(v);else return marque_value<MarqueNpcHandle>(v);},value_->caster()) : godot::Ref<MarqueHandle>{};}
godot::String MarqueCastPhase::get_ability() const{return value_ ? godot::String::utf8(value_->ability().data(),value_->ability().size()) : godot::String{};}
int64_t MarqueCastPhase::get_step() const{return value_ ? static_cast<int64_t>(value_->step()) : 0;}
godot::Ref<MarqueHandle> MarqueCastPhase::get_target() const{return value_ && value_->target() ? std::visit([](auto v)->godot::Ref<MarqueHandle>{using T=std::decay_t<decltype(v)>;if constexpr(std::is_same_v<T,marque::wire::PlayerId>)return marque_value<MarquePlayerHandle>(v);else return marque_value<MarqueNpcHandle>(v);},*value_->target()) : godot::Ref<MarqueHandle>{};}
int64_t MarqueCastPhase::get_amount() const{return value_ ? static_cast<int64_t>(value_->amount()) : 0;}

void MarqueGatherStart::_bind_methods(){
    ClassDB::bind_method(D_METHOD("get_tick"),&MarqueGatherStart::get_tick);
    ADD_PROPERTY(PropertyInfo(Variant::INT,"tick"),"","get_tick");
    ClassDB::bind_method(D_METHOD("get_player"),&MarqueGatherStart::get_player);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"player",PROPERTY_HINT_RESOURCE_TYPE,"MarquePlayerHandle"),"","get_player");
    ClassDB::bind_method(D_METHOD("get_node"),&MarqueGatherStart::get_node);
    ADD_PROPERTY(PropertyInfo(Variant::OBJECT,"node",PROPERTY_HINT_RESOURCE_TYPE,"MarqueNodeHandle"),"","get_node");
}
int64_t MarqueGatherStart::get_tick() const{return value_ ? static_cast<int64_t>(value_->tick()) : 0;}
godot::Ref<MarquePlayerHandle> MarqueGatherStart::get_player() const{return value_ ? marque_value<MarquePlayerHandle>(value_->player()) : godot::Ref<MarquePlayerHandle>{};}
godot::Ref<MarqueNodeHandle> MarqueGatherStart::get_node() const{return value_ ? marque_value<MarqueNodeHandle>(value_->node()) : godot::Ref<MarqueNodeHandle>{};}
