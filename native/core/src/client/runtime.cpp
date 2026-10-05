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
    queued_bytes_=0;
}

bool Runtime::record_to(const std::filesystem::path& path) {
    std::lock_guard lock(mutex_);
    if(connection_!=Connection::disconnected || worker_.joinable())return false;
    recording_path_=path;recording_error_.reset();return true;
}
std::optional<recording::Error> Runtime::recording_error() const {
    std::lock_guard lock(mutex_);return session_ ? session_->recording_error() : recording_error_;
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
    if(session_ && recording_path_) {
        (void)session_->finish_recording(micros());recording_error_=session_->recording_error();
    }
    session_.reset();
    commands_.clear(); input_.reset();
    queued_bytes_=0;
}

bool Runtime::queue(Action action) {
    auto bytes=encode_action(action,1);
    if(!bytes) return false;
    std::lock_guard lock(mutex_);
    if(connection_!=Connection::connected || commands_.size()>=256 || session_->journal_size()+commands_.size()>=4096 ||
       bytes->size()>256*1024-queued_bytes_ || bytes->size()>4*1024*1024-session_->journal_bytes()-queued_bytes_) return false;
    commands_.push_back({std::move(action),bytes->size()});
    queued_bytes_+=bytes->size();
    wake_.notify_all();
    return true;
}

bool Runtime::move(double dx,double dz,bool jump) {
    auto value=wire::Input::build({dx,dz,jump,1});
    if(!value) return false;
    std::lock_guard lock(mutex_);
    if(connection_!=Connection::connected || !session_->prediction()) return false;
    input_=motion::Input{dx,dz,jump || (input_ && input_->jump)};
    wake_.notify_all();
    return true;
}

std::optional<Publication> Runtime::take() {
    std::lock_guard lock(mutex_);
    return session_ ? session_->take(micros()) : std::nullopt;
}
std::shared_ptr<const motion::PredictedPose> Runtime::prediction() const {std::lock_guard lock(mutex_);return session_ ? session_->prediction() : nullptr;}
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
    const auto started=micros();
    {std::lock_guard lock(mutex_);session_=std::make_unique<Session>(opener,sealer,maps_,limits_,started);
        if(recording_path_)(void)session_->record_to(*recording_path_,started);}
    std::uint64_t retry=0;
    bool active=false;
    for(;;) {
        {std::lock_guard lock(mutex_);if(stop_) return;}
        auto now=micros();
        if(!active && now-started>10'000'000){fail(LocalError::handshake);return;}
        if(!active && now>=retry) {
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
            if(!active && size==static_cast<ssize_t>(transport::kChallengeSize)) {
                if(!response.empty()) {if(!socket.send(response)){fail(LocalError::socket);return;}continue;}
                auto answered=token.respond(bytes);
                if(!answered) continue;
                response=std::move(*answered);
                if(!socket.send(response)){fail(LocalError::socket);return;}
                retry=now+200'000;
                continue;
            }
            LocalError error;
            {std::lock_guard lock(mutex_);
                (void)session_->receive(bytes,now);
                active=session_->active();
                if(active)connection_=Connection::connected;
                error=session_->error();
            }
            if(error!=LocalError::none){fail(error);return;}
        }
        if(active) {
            for(std::size_t count=0;count<64;++count) {
                LocalError error=LocalError::none;
                bool present=false;
                {std::lock_guard lock(mutex_);if(!commands_.empty()) {
                    auto command=std::move(commands_.front());commands_.pop_front();queued_bytes_-=command.bytes;
                    present=true;
                    auto bytes=encode_action(std::move(command.action),session_->next_intent());
                    if(!bytes)error=LocalError::transport;
                    else {session_->admit(*bytes,now);error=session_->error();}
                }}
                if(error!=LocalError::none){fail(error);return;}
                if(!present)break;
            }
            now=micros();
            LocalError error;
            std::vector<std::vector<std::uint8_t>> packets;
            {std::lock_guard lock(mutex_);
                if(session_->flush_due(now) && session_->prediction() && input_) {
                    session_->sample(*input_,now);input_.reset();
                }
                packets=session_->turn(now);
                error=session_->error();
            }
            if(error!=LocalError::none){fail(error);return;}
            for(const auto& bytes:packets)if(!socket.send(bytes)){fail(LocalError::socket);return;}
        }
        std::unique_lock lock(mutex_);
        wake_.wait_for(lock,std::chrono::milliseconds(5),[&]{return stop_;});
    }
}

}
