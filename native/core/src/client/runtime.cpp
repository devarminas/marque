#include "marque/client/runtime.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <sys/socket.h>
#include <unistd.h>
#include <sodium.h>

#include "marque/transport/endpoint.hpp"
#include "marque/transport/session_seal.hpp"

namespace marque::client {

std::expected<std::vector<std::uint8_t>,wire::codec::Error> encode_action(Action action,std::uint32_t seq) {
    auto build_and_encode=[]<class M>(auto fields) -> std::expected<std::vector<std::uint8_t>,wire::codec::Error> {
        auto value=M::build(std::move(fields));
        if(!value) return std::unexpected(value.error());
        std::vector<std::uint8_t> bytes;
        if(auto result=wire::encode(*value,bytes);!result) return std::unexpected(result.error());
        return bytes;
    };
    return std::visit([&](auto fields) -> std::expected<std::vector<std::uint8_t>,wire::codec::Error> {
        using F=std::decay_t<decltype(fields)>;
        fields.seq=seq;
        if constexpr(std::is_same_v<F,wire::PickupFields>) return build_and_encode.template operator()<wire::Pickup>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::DropFields>) return build_and_encode.template operator()<wire::Drop>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::EquipFields>) return build_and_encode.template operator()<wire::Equip>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::UnequipFields>) return build_and_encode.template operator()<wire::Unequip>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::GatherFields>) return build_and_encode.template operator()<wire::Gather>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::UseSelfFields>) return build_and_encode.template operator()<wire::UseSelf>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::AttackPlayerFields>) return build_and_encode.template operator()<wire::AttackPlayer>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::RespawnFields>) return build_and_encode.template operator()<wire::Respawn>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::CastSelfFields>) return build_and_encode.template operator()<wire::CastSelf>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::TalkFields>) return build_and_encode.template operator()<wire::Talk>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::DialogOptionFields>) return build_and_encode.template operator()<wire::DialogOption>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::GiveFields>) return build_and_encode.template operator()<wire::Give>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::PartyInviteFields>) return build_and_encode.template operator()<wire::PartyInvite>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::PartyAcceptFields>) return build_and_encode.template operator()<wire::PartyAccept>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::PartyDeclineFields>) return build_and_encode.template operator()<wire::PartyDecline>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::PartyLeaveFields>) return build_and_encode.template operator()<wire::PartyLeave>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::PartyKickFields>) return build_and_encode.template operator()<wire::PartyKick>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::AdminFields>) return build_and_encode.template operator()<wire::Admin>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::UseStationFields>) return build_and_encode.template operator()<wire::UseStation>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::AttackNpcFields>) return build_and_encode.template operator()<wire::AttackNpc>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::CastPlayerFields>) return build_and_encode.template operator()<wire::CastPlayer>(std::move(fields));
        else if constexpr(std::is_same_v<F,wire::CastNpcFields>) return build_and_encode.template operator()<wire::CastNpc>(std::move(fields));
    },std::move(action));
}

namespace {
using Clock=std::chrono::steady_clock;
std::uint64_t micros() {return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now().time_since_epoch()).count();}
std::uint64_t unix_seconds() {return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();}
struct Socket {
    int fd=-1;
    ~Socket(){if(fd>=0) ::close(fd);}
    bool open(const transport::Address& address) {
        fd=::socket(AF_INET6,SOCK_DGRAM|SOCK_NONBLOCK|SOCK_CLOEXEC,0);
        if(fd<0) return false;
        int dual=0;
        if(setsockopt(fd,IPPROTO_IPV6,IPV6_V6ONLY,&dual,sizeof(dual))<0) return false;
        sockaddr_in6 peer{};
        peer.sin6_family=AF_INET6;
        peer.sin6_port=htons(address.port);
        std::memcpy(&peer.sin6_addr,address.ip.data(),address.ip.size());
        return ::connect(fd,reinterpret_cast<const sockaddr*>(&peer),sizeof(peer))==0;
    }
    bool send(std::span<const std::uint8_t> bytes) {
        const auto sent=::send(fd,bytes.data(),bytes.size(),MSG_DONTWAIT);
        return sent==static_cast<ssize_t>(bytes.size());
    }
};
}

Runtime::~Runtime(){disconnect();}

void Runtime::fail(LocalError error) {
    std::lock_guard lock(mutex_);
    error_=error;
    connection_=Connection::failed;
    commands_.clear(); input_.reset();
    queued_bytes_=reserved_bytes_=reserved_count_=0;
}

bool Runtime::connect(std::span<const std::uint8_t> bytes) {
    auto token=transport::ConnectToken::parse(bytes);
    if(!token || token->expires<=unix_seconds() || sodium_init()<0) return false;
    disconnect();
    {
        std::lock_guard lock(mutex_);
        stop_=false;
        error_=LocalError::none;
        connection_=Connection::connecting;
    }
    try {worker_=std::thread([this,token=*token]{
        try {run(token);} catch(...) {fail(LocalError::capacity);}
    });} catch(...) {fail(LocalError::capacity);return false;}
    return true;
}

void Runtime::disconnect() {
    {std::lock_guard lock(mutex_);stop_=true;}
    wake_.notify_all();
    if(worker_.joinable()) worker_.join();
    std::lock_guard lock(mutex_);
    connection_=Connection::disconnected;
    prediction_.reset();
    commands_.clear(); input_.reset(); publications_.clear();
    queued_bytes_=reserved_bytes_=reserved_count_=publication_bytes_=0;
}

bool Runtime::queue(Action action) {
    auto bytes=encode_action(action,1);
    if(!bytes) return false;
    std::lock_guard lock(mutex_);
    if(connection_!=Connection::connected || commands_.size()>=256 || reserved_count_>=4096 ||
       bytes->size()>256*1024-queued_bytes_ || bytes->size()>4*1024*1024-reserved_bytes_) return false;
    commands_.push_back({std::move(action),bytes->size()});
    queued_bytes_+=bytes->size(); reserved_bytes_+=bytes->size(); ++reserved_count_;
    wake_.notify_all();
    return true;
}

bool Runtime::move(double dx,double dz,bool jump) {
    auto value=wire::Input::build({dx,dz,jump,1});
    if(!value) return false;
    std::lock_guard lock(mutex_);
    if(connection_!=Connection::connected || !prediction_) return false;
    input_=motion::Input{dx,dz,jump || (input_ && input_->jump)};
    wake_.notify_all();
    return true;
}

std::optional<Publication> Runtime::take() {
    std::lock_guard lock(mutex_);
    if(publications_.empty()) return std::nullopt;
    auto value=std::move(publications_.front());publications_.pop_front();
    publication_bytes_-=value.retained_bytes;
    return value;
}
std::shared_ptr<const motion::PredictedPose> Runtime::prediction() const {std::lock_guard lock(mutex_);return prediction_;}
Connection Runtime::connection() const {std::lock_guard lock(mutex_);return connection_;}
LocalError Runtime::error() const {std::lock_guard lock(mutex_);return error_;}

void Runtime::run(transport::ConnectToken token) {
    Socket socket;
    if(!socket.open(token.shard)){fail(LocalError::socket);return;}
    auto request=token.request(wire::schema_hash);
    std::vector<std::uint8_t> response;
    auto seals=transport::session_seal(transport::Role::client,token.keys);
    std::shared_ptr<transport::Opener> opener=std::move(seals.opener);
    std::shared_ptr<transport::Sealer> sealer=std::move(seals.sealer);
    std::optional<transport::Endpoint> endpoint;
    auto assembler=Assembler::create();
    std::deque<Canonical> journal;
    std::uint32_t next_intent=1;
    std::optional<motion::Prediction> prediction;
    std::uint32_t interval=40000;
    const auto started=micros();
    std::uint64_t retry=0,flush=started;
    for(;;) {
        {std::lock_guard lock(mutex_);if(stop_) return;}
        auto now=micros();
        if(!endpoint && now-started>10'000'000){fail(LocalError::handshake);return;}
        if(!endpoint && now>=retry) {
            if(!socket.send(response.empty() ? request : response)){fail(LocalError::socket);return;}
            retry=now+200'000;
        }
        std::size_t received_bytes=0;
        for(std::size_t count=0;count<64 && received_bytes<96*1024;++count) {
            std::array<std::uint8_t,transport::kMaxDatagram+1> buffer;
            const auto size=recv(socket.fd,buffer.data(),buffer.size(),MSG_DONTWAIT);
            if(size<0) {
                if(errno==EAGAIN || errno==EWOULDBLOCK || errno==ECONNREFUSED) break;
                fail(LocalError::socket);return;
            }
            received_bytes+=size;
            if(size>static_cast<ssize_t>(transport::kMaxDatagram)) continue;
            auto bytes=std::span<const std::uint8_t>(buffer.data(),size);
            if(!endpoint && size==static_cast<ssize_t>(transport::kChallengeSize)) {
                if(!response.empty()) {if(!socket.send(response)){fail(LocalError::socket);return;}continue;}
                auto answered=token.respond(bytes);
                if(!answered) continue;
                response=std::move(*answered);
                if(!socket.send(response)){fail(LocalError::socket);return;}
                retry=now+200'000;
                continue;
            }
            if(!endpoint) {
                auto made=transport::Endpoint::create(transport::Role::client,transport::default_config(wire::schema_hash),opener,sealer,now);
                if(!made){fail(LocalError::transport);return;}
                auto admitted=made->receive(bytes,now);
                if(!admitted) continue;
                endpoint=std::move(*made);
                {std::lock_guard lock(mutex_);connection_=Connection::connected;}
                if(auto result=assembler.receive(*admitted,{static_cast<std::int64_t>(now)});!result){fail(result.error()==DomainError::recovery_required ? LocalError::recovery : LocalError::decode);return;}
            } else {
                auto packet=endpoint->receive(bytes,now);
                if(!packet) continue;
                if(auto result=assembler.receive(*packet,{static_cast<std::int64_t>(now)});!result){fail(result.error()==DomainError::recovery_required ? LocalError::recovery : LocalError::decode);return;}
            }
        }
        if(endpoint) {
            for(std::size_t count=0;count<64;++count) {
                std::optional<Command> command;
                {std::lock_guard lock(mutex_);if(!commands_.empty()) {
                    command=std::move(commands_.front());commands_.pop_front();queued_bytes_-=command->bytes;
                }}
                if(!command) break;
                if(next_intent==std::numeric_limits<std::uint32_t>::max()){fail(LocalError::sequence);return;}
                auto bytes=encode_action(std::move(command->action),next_intent);
                if(!bytes || !endpoint->send(*bytes)){fail(LocalError::transport);return;}
                journal.push_back({next_intent,std::move(*bytes)});
                ++next_intent;
                assembler.admitted_frontier(next_intent);
            }
            now=micros();
            if(now>=flush) {
                transport::Unreliable unreliable{};
                if(prediction) {
                    std::optional<motion::Input> input;
                    {std::lock_guard lock(mutex_);input=std::exchange(input_,std::nullopt);}
                    if(input && !prediction->sample(*input)){fail(LocalError::sequence);return;}
                    if(!prediction->advance(now)){fail(LocalError::sequence);return;}
                    for(const auto& input:prediction->inputs()) {
                        std::vector<std::uint8_t> bytes;
                        if(!wire::encode(input,bytes)){fail(LocalError::transport);return;}
                        unreliable.stamp=std::max(unreliable.stamp,input.seq());
                        unreliable.items.push_back(std::move(bytes));
                    }
                    {std::lock_guard lock(mutex_);prediction_=prediction->pose();}
                }
                auto packets=endpoint->flush(now,unreliable);
                if(!packets || packets->state!=transport::State::open){fail(LocalError::transport);return;}
                for(const auto& bytes:packets->datagrams) if(!socket.send(bytes)){fail(LocalError::socket);return;}
                flush=now+interval;
            }
            for(std::size_t count=0;count<64;++count) {
                std::size_t available;
                {std::lock_guard lock(mutex_);
                    available=limits_.publication_bytes-publication_bytes_;
                }
                bool full;
                {std::lock_guard lock(mutex_);full=publications_.size()>=limits_.publications;}
                if(full){fail(LocalError::capacity);return;}
                std::optional<motion::Prediction> initial_prediction;
                std::optional<motion::PublishedBaseline> published_baseline;
                auto value=assembler.publish(available,[&](const Events& events,world::Tick tick) -> std::expected<void,DomainError> {
                    if(const auto& value=events.motion;value) {
                        auto baseline=motion::PublishedBaseline::complete(*value,tick.value);
                        if(!baseline)return std::unexpected(DomainError::malformed);
                        published_baseline=*baseline;
                        if(prediction) {
                            if(!prediction->validate(*baseline))return std::unexpected(DomainError::recovery_required);
                        } else {
                            auto map=std::find_if(maps_.begin(),maps_.end(),[&](const auto& map){
                                return map.id==value->map_id() && map.revision==value->map_revision();
                            });
                            if(map!=maps_.end()) {
                                auto made=motion::Prediction::create(*baseline,*map,now);
                                if(!made)return std::unexpected(DomainError::recovery_required);
                                initial_prediction=std::move(*made);
                            }
                        }
                    }
                    return {};
                });
                if(!value){fail(value.error()==DomainError::capacity ? LocalError::capacity : value.error()==DomainError::recovery_required ? LocalError::recovery : LocalError::decode);return;}
                if(!*value) break;
                auto publication=std::move(**value);
                if(!endpoint->send(publication.application_commit)){fail(LocalError::transport);return;}
                if(published_baseline && prediction && !prediction->reconcile(*published_baseline)){fail(LocalError::recovery);return;}
                if(initial_prediction){prediction=std::move(initial_prediction);interval=published_baseline->motion().tick_interval_us();}
                const auto cursor=publication.current->events().next_intent;
                {std::lock_guard lock(mutex_);
                    while(!journal.empty() && journal.front().seq<cursor) {
                        reserved_bytes_-=journal.front().bytes.size();--reserved_count_;journal.pop_front();
                    }
                    if(prediction)prediction_=prediction->pose();
                    publication_bytes_+=publication.retained_bytes;
                    publications_.push_back(std::move(publication));
                }
            }
        }
        std::unique_lock lock(mutex_);
        wake_.wait_for(lock,std::chrono::milliseconds(5),[&]{return stop_;});
    }
}

}
