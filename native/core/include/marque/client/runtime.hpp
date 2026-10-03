#pragma once

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include "marque/client/domain.hpp"
#include "marque/transport/handshake.hpp"

namespace marque::client {

using Action=std::variant<wire::PickupFields,wire::DropFields,wire::EquipFields,wire::UnequipFields,
    wire::GatherFields,wire::UseSelfFields,wire::AttackPlayerFields,wire::RespawnFields,
    wire::CastSelfFields,wire::TalkFields,wire::DialogOptionFields,wire::GiveFields,
    wire::PartyInviteFields,wire::PartyAcceptFields,wire::PartyDeclineFields,wire::PartyLeaveFields,
    wire::PartyKickFields,wire::AdminFields,wire::UseStationFields,wire::AttackNpcFields,
    wire::CastPlayerFields,wire::CastNpcFields>;

std::expected<std::vector<std::uint8_t>,wire::codec::Error> encode_action(Action action,std::uint32_t seq);

enum class Connection { disconnected, connecting, connected, failed };
enum class LocalError { none, token, socket, handshake, transport, decode, capacity, recovery, sequence };

class Runtime {
    struct Command { Action action; std::size_t bytes; };
    struct Canonical { std::uint32_t seq; std::vector<std::uint8_t> bytes; };
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::thread worker_;
    bool stop_=false;
    Connection connection_=Connection::disconnected;
    LocalError error_=LocalError::none;
    std::deque<Command> commands_;
    std::deque<wire::InputFields> inputs_;
    std::deque<Publication> publications_;
    std::size_t queued_bytes_=0;
    std::size_t reserved_bytes_=0;
    std::size_t reserved_count_=0;
    std::size_t publication_bytes_=0;
    void run(transport::ConnectToken token);
    void fail(LocalError error);
public:
    Runtime()=default;
    Runtime(const Runtime&)=delete;
    Runtime& operator=(const Runtime&)=delete;
    ~Runtime();
    bool connect(std::span<const std::uint8_t> token);
    void disconnect();
    bool queue(Action action);
    bool move(double dx,double dz,bool jump);
    std::optional<Publication> take();
    Connection connection() const;
    LocalError error() const;
};

}
