#include "marque/client/domain.hpp"
#include "marque/client/runtime.hpp"

#include <cstdlib>
#include <iostream>
#include <filesystem>
#include <chrono>
#include "marque/transport/handshake.hpp"

using namespace marque;
void check(bool value,const char* message){if(!value){std::cerr<<message<<'\n';std::exit(1);}}
template<class M> std::vector<std::uint8_t> bytes(const M& value){std::vector<std::uint8_t> out;check(wire::encode(value,out).has_value(),"encoded fixture");return out;}
wire::Entity player(std::uint32_t generation,double x,bool vitals=true){
    wire::EntityFields fields;
    fields.id=wire::PlayerId{7,generation};
    fields.transform=*wire::Transform::build({x,2,3});
    if(vitals) fields.vitals=*wire::VitalsUpdate::build({*wire::Vitals::build({90,100,10,20})});
    return *wire::Entity::build(std::move(fields));
}
transport::Received slice(std::uint32_t tick,std::vector<std::vector<std::uint8_t>> items){
    transport::Received packet{};packet.unreliable=transport::Unreliable{tick,std::move(items)};return packet;
}
void close(client::Assembler& core,std::uint32_t tick,std::uint64_t end,std::uint16_t count,std::uint32_t cursor=1){
    transport::Received packet{};
    packet.reliable={bytes(*wire::TickClose::build({88,1,tick,end,count,cursor}))};
    check(core.receive(packet,{40000*tick}).has_value(),"received closed tick");
}
int main(){
    auto core=client::Assembler::create();
    auto first=slice(1,{bytes(player(1,1))});
    first.reliable={bytes(*wire::Inventory::build({88,1,1,28,{*wire::BagEntry::build({0,"sword"})}}))};
    check(core.receive(first,{40000}).has_value(),"staged first component and event");
    check(!core.latest(),"received component is unpublished");
    auto next=slice(2,{bytes(*wire::Entity::build({wire::PlayerId{7,1},*wire::Transform::build({5,2,3}),{},{},{},{}}))});
    check(core.receive(next,{80000}).has_value(),"staged omitted vitals later slice");
    close(core,2,1,1);
    auto result=core.publish(128*1024*1024);
    check(result.has_value() && result->has_value(),"cumulative publication");
    const auto old=(**result).current;
    check(old->tick().value==2,"literal publication tick");
    check(old->world().table<wire::Transform>().find(world::Player{7,1})->x()==5,"latest transform");
    check(old->world().table<wire::Vitals>().find(world::Player{7,1})->hp()==90,"unpublished earlier component retained");
    check(old->events().owner->inventory->slots()[0].kind()=="sword","ordered owner fact");
    check(std::get<wire::Inventory>(old->events().changes[0]).tick()==1,"producing tick retained");
    auto commit=wire::decode_intents((**result).application_commit);
    check(commit && std::get<wire::ApplicationCommit>(*commit).tick()==2,"commit offered publication");
    close(core,3,1,0,2);
    auto invalid=core.publish(128*1024*1024);
    check(!invalid && invalid.error()==client::DomainError::cursor,"future cursor refused");
    check(core.latest()==old,"cursor failure preserves prior world and owner");
    core.admitted_frontier(2);
    auto zero=core.publish(128*1024*1024);
    check(zero && zero->has_value() && (**zero).current->events().next_intent==2,"cursor-only publication");
    check(old->tick().value==2 && old->events().next_intent==1,"old pinned publication unchanged");
    check(core.receive(slice(4,{bytes(*wire::Gone::build({wire::PlayerId{7,1}}))}),{160000}).has_value(),"gone received");
    close(core,4,1,1,2);
    check(core.publish(128*1024*1024)->has_value(),"gone published");
    check(!core.latest()->world().contains(world::Player{7,1}),"gone hidden");
    auto stale=wire::Entity::build({wire::PlayerId{7,1},{},*wire::VitalsUpdate::build({*wire::Vitals::build({1,100,0,20})}),{},{},{}});
    check(core.receive(slice(5,{bytes(*stale)}),{200000}).has_value(),"retired stale partial accepted for generation fence");
    close(core,5,1,1,2);
    check(core.publish(128*1024*1024)->has_value(),"stale partial does not resurrect");
    check(!core.latest()->world().contains(world::Player{7,1}),"retired generation remains absent");
    check(old->world().contains(world::Player{7,1}) && old->world().table<wire::Vitals>().find(world::Player{7,1})->hp()==90,"pinned prior snapshot unchanged after stale retired update");
    check(core.receive(slice(6,{bytes(player(2,9,false))}),{200000}).has_value(),"new generation received");
    close(core,6,1,1,2);
    check(core.publish(128*1024*1024)->has_value(),"new generation published");
    check(!core.latest()->world().table<wire::Vitals>().find(world::Player{7,2}),"old generation component absent");
    auto malformed=slice(7,{bytes(player(2,8)),{0xff}});
    const auto before=core.staged_bytes();
    check(!core.receive(malformed,{240000}),"whole malformed slice refused");
    check(core.staged_bytes()==before,"malformed staging unchanged");
    transport::Received resume{};resume.reliable={bytes(*wire::ResumeBoundary::build({88,2,6,1,1,2}))};
    auto recover=core.receive(resume,{240000});
    check(!recover && recover.error()==client::DomainError::recovery_required,"resume does not certify current reset");
    auto lost=client::Assembler::create();
    transport::Received prefix{};
    prefix.reliable={bytes(*wire::AdminReply::build({88,1,1,"delayed"}))};
    check(lost.receive(prefix,{40000}).has_value(),"split ordered prefix received");
    close(lost,1,1,1);
    auto missing=lost.publish(128*1024*1024);
    check(missing && !missing->has_value(),"missing nonzero scheduled state waits");
    close(lost,2,1,0);
    auto cumulative=lost.publish(128*1024*1024);
    check(cumulative && cumulative->has_value() && (**cumulative).current->tick().value==2 && (**cumulative).current->events().owner->admin->text()=="delayed","zero certificate publishes cumulative older owner fact");
    check((**cumulative).current->world().entities().empty(),"zero certificate invents no world entities");
    auto limited=client::Assembler::create({1,1,1,1024,1});
    check(limited.receive(slice(1,{bytes(player(1,1))}),{40000}).has_value(),"bounded first staged slice");
    check(!limited.receive(slice(2,{bytes(player(1,2))}),{80000}) && !limited.latest(),"staging capacity fails before publication");
    close(limited,1,0,2);
    auto mismatch=limited.publish(128*1024*1024);
    check(!mismatch && mismatch.error()==client::DomainError::state_count && !limited.latest(),"literal actual count mismatch refuses whole publication");
    auto motion_atomic=client::Assembler::create();
    check(motion_atomic.receive(slice(1,{bytes(player(1,1))}),{40000}).has_value(),"initial motion atomic world received");
    close(motion_atomic,1,0,1);
    auto good_motion_world=motion_atomic.publish(128*1024*1024);
    check(good_motion_world && good_motion_world->has_value(),"initial motion atomic world published");
    const auto pinned_motion_world=motion_atomic.latest();
    wire::OwnerMotionFields bad_motion;
    bad_motion.stream=88;bad_motion.epoch=1;bad_motion.player={7,1};bad_motion.tick=2;
    bad_motion.x=129;bad_motion.map_id="village";bad_motion.map_revision=2;
    bad_motion.half_extent=128;bad_motion.tick_interval_us=40000;bad_motion.mode=wire::MotionMode::free;
    auto invalid_motion=wire::OwnerMotion::build(bad_motion);
    check(invalid_motion.has_value(),"wire-valid motion tuple crosses domain boundary");
    auto bad_motion_packet=slice(2,{bytes(player(1,9)),bytes(*invalid_motion)});
    bad_motion_packet.reliable={bytes(*wire::Inventory::build({88,1,2,28,{*wire::BagEntry::build({0,"logs"})}}))};
    check(motion_atomic.receive(bad_motion_packet,{80000}).has_value(),"wire-valid tuple and world and owner staged together");
    motion_atomic.admitted_frontier(2);
    close(motion_atomic,2,1,2,2);
    const auto staged_bad_motion=motion_atomic.staged_bytes();
    auto bad_motion_publication=motion_atomic.publish(128*1024*1024);
    check(!bad_motion_publication && bad_motion_publication.error()==client::DomainError::world,"full motion tuple rejected before world apply");
    check(motion_atomic.latest()==pinned_motion_world && motion_atomic.latest()->events().event_end==0 &&
          motion_atomic.latest()->events().next_intent==1 && !motion_atomic.latest()->events().owner->inventory &&
          motion_atomic.latest()->world().table<wire::Transform>().find(world::Player{7,1})->x()==1 &&
          motion_atomic.staged_bytes()==staged_bad_motion,"invalid motion preserves world owner cursor and staged transaction");
    {
        const auto id=wire::PlayerId{7,1};
        const auto full=*wire::EntitySnapshot::build({id,*wire::Transform::build({1,2,3}),
            *wire::Vitals::build({90,100,10,20}),*wire::Gear::build({{},{},{},{},{} ,"sword"}),
            *wire::CastBar::build({*wire::Casting::build({"fireball",1,38})}),*wire::Look::build({"human"})});
        for(int component=0;component<4;++component){
            auto operations=client::Assembler::create();
            check(operations.receive(slice(1,{bytes(*client::complete_entity(full))}),{40000}).has_value(),"complete Entity bytes stage");
            close(operations,1,0,1);check(operations.publish(128*1024*1024)->has_value(),"complete Entity publishes");
            const auto pin=operations.latest();
            wire::EntityFields patch;patch.id=id;
            if(component==0) patch.vitals=*wire::VitalsUpdate::build({});
            if(component==1) patch.gear=*wire::GearUpdate::build({});
            if(component==2) patch.cast=*wire::CastUpdate::build({});
            if(component==3) patch.look=*wire::LookUpdate::build({});
            check(operations.receive(slice(2,{bytes(*wire::Entity::build(patch))}),{80000}).has_value(),"clear-only Entity bytes stage");
            close(operations,2,0,1);check(operations.publish(128*1024*1024)->has_value(),"clear-only Entity publishes");
            const auto& after=operations.latest()->world();
            check(bool(after.table<wire::Vitals>().find(world::Player{7,1}))==(component!=0) &&
                bool(after.table<wire::Gear>().find(world::Player{7,1}))==(component!=1) &&
                bool(after.table<wire::CastBar>().find(world::Player{7,1}))==(component!=2) &&
                bool(after.table<wire::Look>().find(world::Player{7,1}))==(component!=3),"clear changes exactly selected outer column");
            check(after.table<wire::Transform>().find(world::Player{7,1})->x()==1 &&
                pin->world().table<wire::Vitals>().find(world::Player{7,1})->hp()==90 &&
                pin->world().table<wire::Gear>().find(world::Player{7,1})->right_hand()==std::optional<std::string>{"sword"} &&
                pin->world().table<wire::CastBar>().find(world::Player{7,1})->casting() &&
                pin->world().table<wire::Look>().find(world::Player{7,1})->kind()=="human","immutable pin retains complete literal row");
            check(operations.receive(slice(3,{bytes(*wire::Entity::build({id,{},{},{},{},{}}))}),{120000}).has_value(),"omitted operations stage");
            close(operations,3,0,1);check(operations.publish(128*1024*1024)->has_value(),"omitted operations publish without restoring cleared column");
            check(bool(operations.latest()->world().table<wire::Vitals>().find(world::Player{7,1}))==(component!=0) &&
                bool(operations.latest()->world().table<wire::Gear>().find(world::Player{7,1}))==(component!=1) &&
                bool(operations.latest()->world().table<wire::CastBar>().find(world::Player{7,1}))==(component!=2) &&
                bool(operations.latest()->world().table<wire::Look>().find(world::Player{7,1}))==(component!=3),"omitted operations preserve exact presence");
        }
        auto empty=client::Assembler::create();
        check(empty.receive(slice(1,{bytes(*wire::Entity::build({id,{},{},*wire::GearUpdate::build({}),{}, {}}))}),{40000}).has_value(),"missing Transform clear stages");
        close(empty,1,0,1);check(!empty.publish(128*1024*1024) && !empty.latest(),"clear-only row cannot create visible entry");
        auto hidden=client::Assembler::create();
        check(hidden.receive(slice(1,{bytes(*client::complete_entity(full))}),{40000}).has_value(),"generation fence full row stages");
        close(hidden,1,0,1);check(hidden.publish(128*1024*1024)->has_value(),"generation fence full row publishes");
        check(hidden.receive(slice(2,{bytes(*wire::Gone::build({id}))}),{80000}).has_value(),"generation fence Gone stages");
        close(hidden,2,0,1);check(hidden.publish(128*1024*1024)->has_value(),"generation fence Gone publishes");
        check(hidden.receive(slice(3,{bytes(*wire::Entity::build({id,{},{},{},*wire::CastUpdate::build({}),{}}))}),{120000}).has_value(),"hidden same-generation clear stages");
        close(hidden,3,0,1);check(hidden.publish(128*1024*1024)->has_value() && !hidden.latest()->world().contains(world::Player{7,1}),"clear-only update cannot resurrect hidden row");
        const auto hidden_pin=hidden.latest();
        check(hidden.receive(slice(4,{bytes(*wire::Entity::build({wire::PlayerId{7,2},{},{},{},*wire::CastUpdate::build({}),{}}))}),{160000}).has_value(),"new generation clear-only stages");
        close(hidden,4,0,1);check(!hidden.publish(128*1024*1024) && hidden.latest()==hidden_pin,"new-generation clear requires Transform and preserves prior publication");
        auto generation=client::Assembler::create();
        check(generation.receive(slice(1,{bytes(player(2,9))}),{40000}).has_value(),"new generation ordinary entry stages");
        close(generation,1,0,1);check(generation.publish(128*1024*1024)->has_value(),"new generation ordinary entry publishes");
        check(generation.receive(slice(2,{bytes(*client::complete_entity(full)),bytes(*wire::Gone::build({id}))}),{80000}).has_value(),"old generation full Entity and Gone stage");
        close(generation,2,0,2);check(generation.publish(128*1024*1024)->has_value() && generation.latest()->world().contains(world::Player{7,2}) &&
            generation.latest()->world().table<wire::Transform>().find(world::Player{7,2})->x()==9,"old-generation Entity and Gone cannot alter newer literal pose");
        auto inner=client::Assembler::create();
        check(inner.receive(slice(1,{bytes(*client::complete_entity(full))}),{40000}).has_value(),"inner clear full row stages");
        close(inner,1,0,1);check(inner.publish(128*1024*1024)->has_value(),"inner clear full row publishes");
        check(inner.receive(slice(2,{bytes(*wire::Entity::build({id,{},{},*wire::GearUpdate::build({*wire::Gear::build({})}),*wire::CastUpdate::build({*wire::CastBar::build({})}),{}}))}),{80000}).has_value(),"empty inner values stage");
        close(inner,2,0,1);check(inner.publish(128*1024*1024)->has_value(),"empty inner values publish");
        check(inner.latest()->world().table<wire::Gear>().find(world::Player{7,1}) &&
            !inner.latest()->world().table<wire::Gear>().find(world::Player{7,1})->right_hand() &&
            inner.latest()->world().table<wire::CastBar>().find(world::Player{7,1}) &&
            !inner.latest()->world().table<wire::CastBar>().find(world::Player{7,1})->casting(),"empty inner Gear and CastBar retain outer columns");
    }
    auto action=client::encode_action(wire::PickupFields{0,{11,3}},27);
    check(action.has_value(),"typed action encoding");
    auto decoded=wire::decode_intents(*action);
    const auto pickup=std::get<wire::Pickup>(*decoded);
    check(pickup.seq()==27 && pickup.item()==wire::ItemId{11,3},"literal allocated sequence and full item handle");
    const auto fd_count=[](){return std::distance(std::filesystem::directory_iterator("/proc/self/fd"),std::filesystem::directory_iterator{});};
    const auto before_shutdown=fd_count();
    transport::Address address{};address.ip[10]=address.ip[11]=0xff;address.ip[12]=127;address.ip[15]=1;address.port=9;
    transport::Grant grant{360,360,address,static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count()+60),{}};
    const auto token=transport::issue_token({}, {},grant).bytes();
    for(int count=0;count<4;++count){
        client::Runtime runtime;
        check(runtime.connect(token),"runtime begins genuine pending token handshake");
        check(runtime.connection()==client::Connection::connecting,"pending handshake readiness");
        runtime.disconnect();
        check(runtime.connection()==client::Connection::disconnected && !runtime.queue(wire::RespawnFields{}),"shutdown closes command admission");
    }
    check(fd_count()==before_shutdown,"pending-handshake destruction retains no socket descriptor");
    std::cout<<"client domain publication and action tests passed\n";
}
