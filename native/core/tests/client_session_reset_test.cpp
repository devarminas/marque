#include "check.hpp"
#include "marque/client/session.hpp"
#include "marque/netsim/simulator.hpp"
#include "marque/transport/session_seal.hpp"

#include <cmath>
#include <cstdlib>
#include <iostream>

using namespace marque;
using test::check;
namespace {
template<class T> T must(std::expected<T, transport::ConfigError> result) {
    if (!result) std::abort();
    return std::move(*result);
}
template<class M> std::vector<std::uint8_t> bytes(const M &value) {
    std::vector<std::uint8_t> result;
    if (!wire::encode(value, result)) std::abort();
    return result;
}
transport::SessionKeys keys(unsigned salt) {
    transport::SessionKeys value{};
    for (std::size_t i=0;i<transport::kKeySize;++i) {
        value.client_to_server[i]=i+salt;
        value.server_to_client[i]=i+salt+64;
    }
    return value;
}
wire::OwnerMotion owner(std::uint64_t epoch=1,std::uint32_t tick=10,std::uint32_t cursor=0,float x=0,float dx=0) {
    return *wire::OwnerMotion::build({88,epoch,{7,1},tick,cursor,x,0,0,0,dx,0,true,wire::MotionMode::free,0,"village",2,128,0,40000});
}
wire::EntitySnapshot row(double x) {
    return *wire::EntitySnapshot::build({wire::PlayerId{7,1},*wire::Transform::build({x,0,0}),{},{},{},{}});
}
wire::ResetCertificate certificate(std::uint64_t epoch=2,std::uint64_t lease=42,std::uint32_t next=2) {
    return *wire::ResetCertificate::build({88,epoch,lease,7,10,2,next,1,1});
}
wire::ResetBegin begin(const wire::ResetCertificate &c,std::uint32_t input=1,float x=.124f,std::string map="village",float dx=0) {
    return *wire::ResetBegin::build({c,*wire::MotionBaseline::build({88,c.epoch(),{7,1},10,input,x,0,0,0,dx,0,true,wire::MotionMode::free,0,std::move(map),2,128,0,40000})});
}
struct Fixture {
    std::unique_ptr<client::Session> session;
    std::optional<transport::Endpoint> server;
    std::size_t notifications=0;
    std::vector<std::uint8_t> first=bytes(*wire::Pickup::build({1,wire::ItemId{3,1}}));
    std::vector<std::uint8_t> second=bytes(*wire::Drop::build({2,0}));
    std::shared_ptr<const client::Tick> pinned;
    std::shared_ptr<const motion::PredictedPose> predicted_pin;
    std::filesystem::path capture_directory;
    ~Fixture() {
        session.reset();
        if (!capture_directory.empty()) std::filesystem::remove_all(capture_directory);
    }
    explicit Fixture(bool sampled=true,client::RuntimeLimits limits={},transport::Config config=transport::default_config(wire::schema_hash),bool recording=false) {
        auto seals=transport::session_seal(transport::Role::client,keys(1));
        session=std::make_unique<client::Session>(std::move(seals.opener),std::move(seals.sealer),
            std::vector<motion::PredictionMap>{{{},"village",2}},limits,400000,config);
        session->observe([&](const client::Publication &p){
            ++notifications;
            check(session->latest()==p.current && session->prediction()!=nullptr,"observer sees world and prepared prediction together");
        });
        if(recording) {
            auto directory=(std::filesystem::temp_directory_path()/"marque-retained-reject-XXXXXX").string();
            if(!mkdtemp(directory.data())) std::abort();
            capture_directory=directory;
            check(session->record_to(capture_directory/"capture.bin",400000),"cold active capture created");
        }
        auto peer=transport::session_seal(transport::Role::server,keys(1));
        server=must(transport::Endpoint::create(transport::Role::server,transport::default_config(wire::schema_hash),std::move(peer.opener),std::move(peer.sealer),400000));
        transport::Unreliable state{10,{bytes(*wire::EntityReplace::build({row(0)})),bytes(owner(1,10,0,0,sampled ? 0 : 1))}};
        check(server->send(bytes(*wire::Inventory::build({88,1,9,28,{*wire::BagEntry::build({0,"sword"})}}))).has_value() &&
            server->send(bytes(*wire::TickClose::build({88,1,10,1,2,1}))).has_value(),"cold real owner prefix and close queued");
        auto packets=server->flush(400000,state);
        if(!packets)std::abort();
        for(const auto &packet:packets->datagrams)check(session->receive(packet,400000).has_value(),"cold ciphertext enters actual Session");
        for(const auto &packet:session->turn(400000))check(server->receive(packet,400000).has_value(),"cold commit enters actual peer");
        pinned=session->latest();predicted_pin=session->prediction();
        check(pinned && pinned->events().event_end==1 && predicted_pin && predicted_pin->tick==10,"cold known-map Session publishes nonzero cursor and prediction");
        check(session->admit(first,400000) && session->admit(second,400000) && session->next_intent()==3 && session->journal_size()==2,"two actual canonical commands admitted once");
        if(sampled){
            check(session->sample({1,0,false},440000),"actual local movement sampled");
            (void)session->turn(440000);
            check(session->sample({0,0,false},480000),"actual explicit stop sampled");
            (void)session->turn(480000);
            check(session->prediction()->tick==12 && session->prediction()->state.x==.12,"nonempty movement history and deliberate stop retained before replacement");
        }
    }
    bool replace(std::uint64_t epoch=2,std::uint64_t lease=42,std::uint64_t now=480000,client::ResetLimits limits={}) {
        auto seals=transport::session_seal(transport::Role::client,keys(epoch));
        const auto result=session->replace_lease({88,epoch,lease,{7,1}},std::move(seals.opener),std::move(seals.sealer),now,limits);
        if(!result)return false;
        auto peer=transport::session_seal(transport::Role::server,keys(epoch));
        server=must(transport::Endpoint::create(transport::Role::server,transport::default_config(wire::schema_hash),std::move(peer.opener),std::move(peer.sealer),now));
        return true;
    }
    void offer(const wire::ResetCertificate &c,const wire::ResetBegin &b,double x=.12) {
        for(const auto &message:std::vector<std::vector<std::uint8_t>>{bytes(b),bytes(*wire::Inventory::build({88,1,9,28,{*wire::BagEntry::build({0,"duplicate"})}})),
            bytes(*wire::QuestLog::build({88,2,9,{*wire::QuestEntry::build({"q","Quest","Gather","active"})}})),
            bytes(*wire::ResetPart::build({c,0,{row(x)}})),bytes(*wire::ResetClose::build({c}))})
            check(server->send(message).has_value(),"actual reset controls and retained owner prefix queued");
    }
    void deliver(std::uint64_t now=480000) {
        auto packets=server->flush(now);if(!packets)std::abort();
        for(const auto &packet:packets->datagrams)check(session->receive(packet,now).has_value(),"actual replacement ciphertext decoded");
    }
};
}
int main() {
    Fixture f;
    const auto address=f.session.get();
    const auto old_pose=f.session->prediction();
    auto old_packets=f.server->flush(480000);
    check(f.replace(),"fresh authenticated lease replaces transport on retained Session");
    check(f.session.get()==address && f.session->latest()==f.pinned && f.session->prediction()==old_pose &&
        f.session->phase()==client::DomainPhase::reset_pending && f.session->next_intent()==3 && f.session->journal_size()==2,
        "lease replacement retains actual Session Reader prediction frontier and journal");
    if(old_packets)for(const auto &packet:old_packets->datagrams)
        check(!f.session->receive(packet,480000) && f.session->latest()==f.pinned && f.session->error()==client::LocalError::none,"old traffic-key ciphertext cannot mutate replacement");
    const auto cert=certificate();f.offer(cert,begin(cert));
    netsim::Simulator sim(netsim::kBadWifi,36320261007ULL);
    bool committed=false,dropped=false,saw_command=false,saw_stop=false;
    std::size_t commits=0,deliveries=0;
    std::uint64_t completed=0,last_turn=0;
    const auto stop=bytes(*wire::Input::build({0,0,false,2}));
    for(std::uint64_t now=480000;now<=4480000 && !(committed && saw_command && saw_stop);now+=40000){
        last_turn=now;
        auto packets=f.server->flush(now);if(!packets)std::abort();
        std::size_t total=0;
        for(auto &packet:packets->datagrams){total+=packet.size();sim.send(netsim::Direction::kAToB,std::move(packet),now);}
        check(total<=4800,"one server flush obeys actual tick budget");
        for(const auto &delivery:sim.poll(netsim::Direction::kAToB,now)){
            if(f.session->receive(delivery.packet,now))++deliveries;
        }
        auto outgoing=f.session->turn(now);total=0;
        for(auto &packet:outgoing){total+=packet.size();sim.send(netsim::Direction::kBToA,std::move(packet),now);}
        check(total<=4800 && f.session->turn(now).empty(),"one Session flush including controls and resends per tick");
        check(f.session->error()==client::LocalError::none,"retained Session remains coherent during real bad_wifi reset");
        for(const auto &delivery:sim.poll(netsim::Direction::kBToA,now)){
            const auto received=f.server->receive(delivery.packet,now);if(!received)continue;
            for(const auto &message:received->reliable){
                auto decoded=wire::decode_intents(message);if(!decoded)std::abort();
                if(const auto *control=std::get_if<wire::ResetCommit>(&*decoded)){
                    ++commits;check(control->certificate()==cert,"actual peer gets exact certificate control before command resend");
                    if(!dropped){dropped=true;check(f.server->send(bytes(*wire::ResetClose::build({cert}))).has_value(),"lost application control causes actual duplicate close");}
                    else{committed=true;completed=now;}
                }else{
                    check(commits>0 && message==f.second,"only unconsumed canonical bytes resend after control actual admission");
                    saw_command=true;
                }
            }
            if(received->unreliable)for(const auto &message:received->unreliable->items){
                check(message==stop,"explicit stop repeats exact canonical bytes and original input high water");saw_stop=true;
            }
        }
    }
    check(committed && deliveries>0 && saw_command && saw_stop && commits==2,"actual encrypted bad_wifi Session completes one reset and matching lost-control retry");
    check(f.notifications==2 && f.session->latest()->tick().value==10 && f.session->latest()->sample_time().microseconds==400000 &&
        f.session->latest()->events().event_end==2 && f.session->latest()->events().changes.size()==1 && f.session->journal_size()==1 &&
        f.session->journal_bytes()==f.second.size() && f.session->next_intent()==3,"one world owner prediction publication trims only frozen consumed next_intent");
    auto initial=f.session->take(completed);auto reset=f.session->take(completed);
    check(initial && reset && !reset->previous && reset->current==f.session->latest() && !f.session->take(completed),"one reset FIFO notification has no zero-time interpolation pair");
    check(f.pinned->world().table<wire::Transform>().find(world::Player{7,1})->x()==0 && f.pinned->events().event_end==1 &&
        f.predicted_pin->tick==10 && f.predicted_pin->state.x==0,"original pinned world owner and prediction remain immutable");
    const auto horizon=f.session->prediction()->tick;
    (void)f.session->turn(last_turn+40000);
    check(f.session->prediction()->tick==horizon+1 && f.session->prediction()->tick==10+(last_turn+40000-400000)/40000 &&
        f.session->prediction()->state.x==static_cast<double>(.124f),"next40ms uses original prediction anchor and preserves unconsumed stop");
    check(f.session->admit(bytes(*wire::Drop::build({3,0})),last_turn+40000) && f.session->next_intent()==4,"new admission after canonical resend increments once");
    std::cout<<"retained Session bad_wifi seed=36320261007 notifications="<<f.notifications<<" commits="<<commits<<" deliveries="<<deliveries<<" completion_us="<<completed<<'\n';

    for(unsigned kind=0;kind<4;++kind){
        Fixture invalid;check(invalid.replace(),"invalid reset fixture retains real predictor and commands");
        const auto c=certificate(2,42,kind==0 ? 4 : 2);
        invalid.offer(c,begin(c,kind==1 ? 3 : 1,.124f,kind==2 ? "wrong" : "village"),kind==3 ? 9 : .12);
        invalid.deliver();const auto prediction=invalid.session->prediction();(void)invalid.session->turn(480000);
        check(invalid.session->phase()==client::DomainPhase::unavailable && invalid.session->latest()==invalid.pinned &&
            invalid.session->prediction()==prediction && invalid.session->journal_size()==2 && invalid.session->next_intent()==3 &&
            invalid.notifications==1 && invalid.session->pending_commit().empty(),"future consumed cursor input cursor map or pose refuses whole tuple without losing history");
    }
    {
        Fixture passive(false);check(passive.replace(),"passive retained Session lease");const auto c=certificate();passive.offer(c,begin(c,0,.124f,"village",1));passive.deliver();
        const auto packets=passive.session->turn(480000);bool invented=false;
        for(const auto &packet:packets){const auto got=passive.server->receive(packet,480000);if(got && got->unreliable && !got->unreliable->items.empty())invented=true;}
        check(!invented && passive.session->prediction()->state.dx==1 && passive.session->prediction()->tick==12,"passive replacement integrates authoritative approach without fabricated zero input");
    }
    {
        Fixture jumping(false);
        check(jumping.session->sample({0,0,true},440000),"actual pending jump samples one canonical edge");
        (void)jumping.session->turn(440000);
        check(jumping.session->prediction()->tick==11 && std::abs(jumping.session->prediction()->state.y-.168)<1e-9 &&
            jumping.session->prediction()->state.vy==4.2,"actual pre-lease jump has literal airborne pose");
        check(jumping.replace(),"airborne history replaces lease without a second jump");
        const auto c=certificate();jumping.offer(c,begin(c,0,0),0);jumping.deliver();
        const auto packets=jumping.session->turn(480000);
        bool retained_jump=false;
        for(const auto &packet:packets){
            const auto got=jumping.server->receive(packet,480000);
            if(got && got->unreliable) for(const auto &message:got->unreliable->items)
                retained_jump=message==bytes(*wire::Input::build({0,0,true,1}));
        }
        check(retained_jump && jumping.session->prediction()->tick==12 &&
            std::abs(jumping.session->prediction()->state.y-.304)<1e-9 &&
            std::abs(jumping.session->prediction()->state.vy-3.4)<1e-9,
            "certified reset replays the original jump once and continues gravity");
        (void)jumping.session->turn(520000);
        check(jumping.session->prediction()->tick==13 && std::abs(jumping.session->prediction()->state.y-.408)<1e-9 &&
            std::abs(jumping.session->prediction()->state.vy-2.6)<1e-9,
            "next original-clock tick continues airborne stop without retriggering jump");
    }
    {
        Fixture identity;
        for(const auto &candidate:std::vector<client::LeaseIdentity>{{88,1,42,{7,1}},{89,2,42,{7,1}},{88,2,42,{7,2}}}){
            auto fresh=transport::session_seal(transport::Role::client,keys(2));
            const auto old=identity.session->prediction();
            check(!identity.session->replace_lease(candidate,std::move(fresh.opener),std::move(fresh.sealer),480000) &&
                identity.session->latest()==identity.pinned && identity.session->prediction()==old && identity.session->phase()==client::DomainPhase::live &&
                identity.session->journal_size()==2 && identity.session->next_intent()==3,
                "old epoch changed stream or owner generation refuses replacement before mutation");
        }
        check(identity.replace(),"current identity still replaces after refused identity attempts");
        const auto c=certificate(2,43);identity.offer(c,begin(c));identity.deliver();
        const auto old=identity.session->prediction();(void)identity.session->turn(480000);
        check(identity.session->phase()==client::DomainPhase::unavailable && identity.session->latest()==identity.pinned &&
            identity.session->prediction()==old && identity.session->journal_size()==2 && identity.notifications==1 && identity.session->pending_commit().empty(),
            "wrong certified lease cannot publish or discard retained history");
    }
    {
        Fixture deadline;client::ResetLimits limits;limits.timeout_us=40000;check(deadline.replace(2,42,480000,limits),"deadline retained Session lease");
        const auto old=deadline.session->prediction();(void)deadline.session->turn(520001);
        check(deadline.session->error()==client::LocalError::recovery && deadline.session->domain_error()==client::DomainError::deadline &&
            deadline.session->latest()==deadline.pinned && deadline.session->prediction()==old && deadline.session->journal_size()==2,"deadline explicitly refuses before predictor or checkpoint mutation");
    }
    {
        Fixture history;check(history.replace(),"bounded history retained lease");
        for(std::uint64_t now=520000;now<=10640000;now+=40000){
            const auto peer=history.server->flush(now);if(!peer) std::abort();
            for(const auto &packet:peer->datagrams)
                check(history.session->receive(packet,now).has_value(),"real peer keepalive retains pending lease");
            for(const auto &packet:history.session->turn(now))
                check(history.server->receive(packet,now).has_value(),"real Session keepalive retains pending transport");
        }
        check(history.session->error()==client::LocalError::none && history.session->phase()==client::DomainPhase::reset_pending &&
            history.session->prediction()->tick==266 && history.session->prediction()->mode==motion::PredictionMode::predicting &&
            history.session->prediction()->state.x==.12 && history.session->journal_size()==2 && history.session->latest()==history.pinned,
            "pending prediction reaches exact256tick horizon with canonical stop retained");
        const auto old=history.session->prediction();(void)history.session->turn(10680000);
        check(history.session->error()==client::LocalError::recovery && history.session->latest()==history.pinned && history.session->prediction()==old &&
            history.session->journal_size()==2 && history.notifications==1,"pending history exhaustion is explicit before destructive recovery");
    }
    {
        Fixture capacity(true,{1,128*1024*1024});check(capacity.replace(),"FIFO capacity retained lease");const auto c=certificate();capacity.offer(c,begin(c));capacity.deliver();(void)capacity.session->turn(480000);
        check(capacity.session->error()==client::LocalError::capacity && capacity.session->latest()==capacity.pinned && capacity.session->journal_size()==2 &&
            capacity.notifications==1,"bounded FIFO refuses reset before world and prediction switch");
    }
    {
        auto config=transport::default_config(wire::schema_hash);config.backlog_bytes=45;
        Fixture refused(true,{},config);
        check(bytes(*wire::ApplicationCommit::build({88,1,10,1})).size()+refused.first.size()+refused.second.size()==45 &&
            bytes(*wire::ResetCommit::build({certificate()})).size()==58,"actual cold queue fits45bytes and certified control exceeds it");
        check(refused.replace(),"actual Sender capacity fixture lease");const auto c=certificate();refused.offer(c,begin(c));refused.deliver();(void)refused.session->turn(480000);
        const auto control=wire::decode_intents(refused.session->pending_commit());
        check(refused.session->error()==client::LocalError::transport && refused.session->latest()!=refused.pinned && refused.notifications==2 &&
            refused.session->prediction()->state.x==static_cast<double>(.124f) && refused.session->journal_size()==1 && refused.session->next_intent()==3 &&
            control && std::get<wire::ResetCommit>(*control).certificate()==c,"Sender nil-return slow_client cannot split world prediction FIFO or lose exact retry control");
        const auto publication=refused.session->take(480000);const auto reset=refused.session->take(480000);
        check(publication && reset && reset->current==refused.session->latest() && reset->application_commit.size()==58,"post-switch Sender refusal retains one exact58byte certified FIFO publication");
    }
    {
        Fixture capture(true,{},transport::default_config(wire::schema_hash),true);const auto old=capture.session->prediction();
        check(!capture.replace() && capture.session->latest()==capture.pinned && capture.session->prediction()==old && capture.session->phase()==client::DomainPhase::live &&
            capture.session->journal_size()==2 && capture.session->next_intent()==3,"active-capture warm operation refuses before all mutation");
        check(capture.session->finish_recording(480000),"cold-only capture remains valid after refused warm operation");
    }
    const auto result=test::check_finish();
    if(!result)std::cout<<"retained actual Session reset tests passed known_map=1 canonical_commands=2 move_stop_history=2 one_flush=4800\n";
    return result;
}
