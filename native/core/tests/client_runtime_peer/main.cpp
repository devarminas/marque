#include "marque/client/runtime.hpp"
#include "marque/recording/replay.hpp"

#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>

using namespace marque;

int main(int argc,char** argv){
    if(argc!=3)return 2;
    const std::string mode=argv[2];
    std::ifstream file(argv[1],std::ios::binary);
    std::vector<std::uint8_t> token((std::istreambuf_iterator<char>(file)),{});
    client::RuntimeLimits limits;
    if(mode=="count")limits.publications=2;
    else if(mode=="bytes")limits.publication_bytes=2*1024*1024;
    client::Runtime runtime({{motion::Map{128,0,{}} ,"village",2}},limits);
    const auto recording_path=std::string(argv[1])+".recording";
    if(!runtime.record_to(recording_path))return 18;
    std::vector<std::vector<std::uint8_t>> observed;
    auto stop_and_replay=[&](client::LocalError terminal) {
        runtime.disconnect();
        if(runtime.recording_error())return false;
        auto trace=recording::Replay::load(recording_path);
        if(!trace)return false;
        std::size_t compared=0;bool equal=true;
        auto replay=trace->run([&](const client::Publication& publication){
            if(compared>=observed.size() || recording::canonical(publication)!=observed[compared])equal=false;
            ++compared;
        });
        return replay && equal && compared==observed.size() && replay->terminal==terminal && replay->publications==observed.size() && !observed.empty();
    };
    if(!runtime.connect(token))return 3;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(12);
    std::optional<client::Publication> pinned;
    std::shared_ptr<const client::Tick> cumulative;
    std::shared_ptr<const motion::PredictedPose> pinned_pose;
    while(std::chrono::steady_clock::now()<deadline){
        if(!pinned){
            pinned=runtime.take();
            if(pinned){
                observed.push_back(recording::canonical(*pinned));
                if(pinned->current->tick().value!=1)return 4;
                pinned_pose=runtime.prediction();
                if(!runtime.queue(wire::RespawnFields{}))return 5;
                std::ofstream(std::string(argv[1])+".ready")<<"ready";
            }
        }
        if(mode=="gauntlet" && pinned){
            while(auto publication=runtime.take()){observed.push_back(recording::canonical(*publication));cumulative=publication->current;}
            if(cumulative && cumulative->tick().value==5){
                const auto* health=cumulative->world().table<wire::Vitals>().find(world::Player{7,1});
                const auto* position=cumulative->world().table<wire::Transform>().find(world::Player{7,1});
                const auto& events=cumulative->events();
                if(!health || health->hp()!=90 || !position || position->x()!=5 || events.event_end!=2 || events.next_intent!=2 ||
                   !events.owner->inventory || events.owner->inventory->slots()[0].kind()!=std::string("logs") ||
                   !events.owner->quests || events.owner->quests->quests()[0].id()!=std::string("quest_one") ||
                   events.changes.size()!=2 || events.presentation.size()!=3)return 13;
                if(std::get<wire::Inventory>(events.changes[0]).tick()!=2 || std::get<wire::QuestLog>(events.changes[1]).tick()!=3 ||
                   std::get<wire::Swing>(events.presentation[0]).amount()!=17 ||
                   std::get<wire::CastPhase>(events.presentation[1]).ability()!=std::string("fireball") ||
                   std::get<wire::GatherStart>(events.presentation[2]).node()!=wire::NodeId{21,1})return 14;
                if(pinned->current->world().table<wire::Vitals>().find(world::Player{7,1})->hp()!=100 ||
                   pinned->current->world().table<wire::Transform>().find(world::Player{7,1})->x()!=0)return 15;
                std::this_thread::sleep_for(std::chrono::milliseconds(150));
                if(runtime.connection()!=client::Connection::connected)return 16;
                std::cout<<"ARM360_LIVE_gauntlet_CUMULATIVE_PASS tick=5 hp=90 x=5 owner_prefix=2 presentation=3 pinned_hp=100\n";
                if(!stop_and_replay(client::LocalError::none))return 19;
                std::cout<<"ARM361_RUNTIME_RECORD_REPLAY_PASS publications="<<observed.size()<<'\n';return 0;
            }
        }
        if(runtime.connection()==client::Connection::failed)break;
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    const auto expected=(mode=="epoch" || mode=="invalid_motion") ? client::LocalError::decode :
        (mode=="wrong_map" || mode=="future_input") ? client::LocalError::recovery : client::LocalError::capacity;
    if(!pinned || runtime.connection()!=client::Connection::failed || runtime.error()!=expected)return 6;
    if(pinned->current->tick().value!=1 || pinned->current->events().event_end!=0 ||
       pinned->current->events().next_intent!=1 || runtime.queue(wire::RespawnFields{}))return 7;
    std::size_t queued=0,bytes=0;
    while(auto publication=runtime.take()){
        observed.push_back(recording::canonical(*publication));
        ++queued;bytes+=publication->retained_bytes;
        if(publication->current->tick().value>3)return 8;
    }
    if(mode=="count" && queued!=2)return 9;
    if(mode=="bytes" && queued!=1)return 10;
    if((mode=="epoch" || mode=="invalid_motion" || mode=="wrong_map" || mode=="future_input") && queued!=0)return 11;
    if(mode=="invalid_motion" || mode=="wrong_map" || mode=="future_input"){
        if(!pinned_pose || !runtime.prediction() || pinned_pose->state.x!=0 || runtime.prediction()->state.x!=0 ||
           runtime.prediction()->state.dx!=0)return 17;
    }
    if(queued>limits.publications || bytes>limits.publication_bytes)return 12;
    std::cout<<"ARM360_LIVE_"<<mode<<"_FAILURE_PASS queued="<<queued<<" bytes="<<bytes<<" pinned_tick=1\n";
    if(!stop_and_replay(expected))return 19;
    std::cout<<"ARM361_RUNTIME_RECORD_REPLAY_PASS publications="<<observed.size()<<'\n';
    return 0;
}
