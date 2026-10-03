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
    if(vitals) fields.vitals=*wire::Vitals::build({90,100,10,20});
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
    auto stale=wire::Entity::build({wire::PlayerId{7,1},{},*wire::Vitals::build({1,100,0,20}),{},{},{}});
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
