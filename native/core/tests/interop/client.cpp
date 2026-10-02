#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <sodium.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <memory>
#include <optional>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

#include "marque/transport/endpoint.hpp"
#include "marque/transport/handshake.hpp"
#include "marque/transport/session_seal.hpp"

namespace mt = marque::transport;
using Bytes = std::vector<std::uint8_t>;
constexpr std::size_t frame_limit = 262144;
constexpr std::size_t packet_limit = 256;

void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}

void transfer(int fd, std::uint8_t* p, std::size_t n, bool writing) {
    while (n != 0) {
        pollfd ready{fd, static_cast<short>(writing ? POLLOUT : POLLIN), 0};
        require(poll(&ready, 1, 3000) == 1, "pipe timeout");
        auto count = writing ? write(fd, p, n) : read(fd, p, n);
        require(count > 0, "pipe closed");
        p += count;
        n -= static_cast<std::size_t>(count);
    }
}

struct Frame {
    Bytes bytes;
    std::size_t cursor = 0;

    void put(std::uint64_t value, std::size_t n) {
        for (std::size_t i = 0; i < n; ++i) bytes.push_back(static_cast<std::uint8_t>(value >> (8 * i)));
        require(bytes.size() <= frame_limit, "output frame limit");
    }
    std::uint64_t get(std::size_t n) {
        require(n <= bytes.size() - cursor, "truncated frame");
        std::uint64_t value = 0;
        for (std::size_t i = 0; i < n; ++i) value |= static_cast<std::uint64_t>(bytes[cursor++]) << (8 * i);
        return value;
    }
    Bytes take(std::size_t n) {
        require(n <= bytes.size() - cursor, "truncated bytes");
        Bytes out(bytes.begin() + cursor, bytes.begin() + cursor + n);
        cursor += n;
        return out;
    }
    Bytes blob() {
        auto n = get(4);
        require(n <= mt::kMaxMessage, "blob limit");
        return take(n);
    }
    void blob(std::span<const std::uint8_t> b) {
        require(b.size() <= mt::kMaxMessage, "blob output limit");
        put(b.size(), 4);
        bytes.insert(bytes.end(), b.begin(), b.end());
        require(bytes.size() <= frame_limit, "output frame limit");
    }
    std::vector<Bytes> list() {
        auto n = get(4);
        require(n <= packet_limit, "list limit");
        std::vector<Bytes> out;
        for (std::size_t i = 0; i < n; ++i) out.push_back(blob());
        return out;
    }
    void list(const std::vector<Bytes>& b) {
        require(b.size() <= packet_limit, "list output limit");
        put(b.size(), 4);
        for (const auto& item : b) blob(item);
    }
    void end() { require(cursor == bytes.size(), "trailing frame bytes"); }
};

Frame receive_frame() {
    std::array<std::uint8_t, 4> header{};
    transfer(STDIN_FILENO, header.data(), header.size(), false);
    std::uint32_t size = 0;
    for (int i = 0; i < 4; ++i) size |= static_cast<std::uint32_t>(header[i]) << (8 * i);
    require(size > 0 && size <= frame_limit, "input frame limit");
    Frame frame{Bytes(size)};
    transfer(STDIN_FILENO, frame.bytes.data(), size, false);
    return frame;
}

void send_frame(Frame frame) {
    Frame header;
    header.put(frame.bytes.size(), 4);
    transfer(STDOUT_FILENO, header.bytes.data(), 4, true);
    transfer(STDOUT_FILENO, frame.bytes.data(), frame.bytes.size(), true);
}

struct Fingerprint {
    std::uint32_t size;
    std::array<std::uint8_t, crypto_hash_sha256_BYTES> digest;
    friend bool operator==(const Fingerprint&, const Fingerprint&) = default;
    friend auto operator<=>(const Fingerprint&, const Fingerprint&) = default;
};

Fingerprint fingerprint(const Bytes& bytes) {
    Fingerprint f{static_cast<std::uint32_t>(bytes.size()), {}};
    crypto_hash_sha256(f.digest.data(), bytes.data(), bytes.size());
    return f;
}

std::uint64_t little(const Bytes& bytes, std::size_t offset, std::size_t n) {
    require(offset + n <= bytes.size(), "short datagram metadata");
    std::uint64_t v = 0;
    for (std::size_t i = 0; i < n; ++i) v |= static_cast<std::uint64_t>(bytes[offset + i]) << (8 * i);
    return v;
}

struct Socket {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    ~Socket() { if (fd >= 0) close(fd); }
};

int main() {
    try {
        require(sodium_init() >= 0, "sodium init");
        auto init = receive_frame();
        require(init.get(1) == 1, "expected startup");
        auto token = mt::ConnectToken::parse(init.blob());
        require(token.has_value(), "token parse");
        auto hash = init.get(8);
        auto intents = init.list();
        auto input = init.list();
        auto workload_ticks = init.get(4);
        auto stale = init.get(1) != 0;
        auto confirmation = init.blob();
        init.end();
        require(workload_ticks <= 64 && !intents.empty() && !input.empty(), "workload bounds");
        Socket socket;
        require(socket.fd >= 0, "socket creation");
        sockaddr_in local{};
        local.sin_family = AF_INET;
        local.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        require(bind(socket.fd, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == 0, "socket bind");
        socklen_t address_size = sizeof(local);
        require(getsockname(socket.fd, reinterpret_cast<sockaddr*>(&local), &address_size) == 0, "socket address");
        sockaddr_in proxy{};
        proxy.sin_family = AF_INET;
        proxy.sin_port = htons(token->shard.port);
        require(token->shard.ip[10] == 0xff && token->shard.ip[11] == 0xff, "expected mapped IPv4 shard");
        std::copy_n(token->shard.ip.begin() + 12, 4, reinterpret_cast<std::uint8_t*>(&proxy.sin_addr));
        require(proxy.sin_addr.s_addr == htonl(INADDR_LOOPBACK), "expected loopback shard");
        Frame ready;
        ready.put(ntohs(local.sin_port), 2);
        send_frame(std::move(ready));
        std::optional<mt::Endpoint> endpoint;
        bool connected = false;
        std::size_t queued = 0;
        std::uint32_t active_tick = 0;
        std::uint64_t retry_at = 0;
        std::uint64_t renew_at = 0;
        Bytes cached_response;
        std::set<Bytes> answered;
        std::set<Fingerprint> opened;
        std::uint64_t newest_nonce = 0;
        bool have_nonce = false;
        std::uint64_t last_emitted_nonce = 0;
        bool emitted_nonce = false;
        for (std::uint32_t step = 0; step < 1000; ++step) {
            auto command = receive_frame();
            auto kind = command.get(1);
            if (kind == 3) {
                command.end();
                pollfd residual{socket.fd, POLLIN, 0};
                require(poll(&residual, 1, 0) == 0, "unlisted residual client datagram");
                require(endpoint && connected && endpoint->state() == mt::State::open && endpoint->backlog() == 0,
                        "unfinished client");
                Frame finished;
                finished.put(3, 1);
                send_frame(std::move(finished));
                return 0;
            }
            require(kind == 2, "expected step");
            auto now = command.get(8);
            auto count = command.get(4);
            require(count <= packet_limit, "ingress count limit");
            std::vector<Fingerprint> expected;
            for (std::size_t i = 0; i < count; ++i) {
                Fingerprint f{static_cast<std::uint32_t>(command.get(4)), {}};
                require(f.size <= mt::kMaxDatagram, "ingress size limit");
                auto digest = command.take(f.digest.size());
                std::copy(digest.begin(), digest.end(), f.digest.begin());
                expected.push_back(f);
            }
            command.end();
            std::vector<Bytes> packets(count);
            std::vector<bool> matched(count, false);
            for (std::size_t i = 0; i < count; ++i) {
                pollfd available{socket.fd, POLLIN, 0};
                require(poll(&available, 1, 3000) == 1, "client UDP timeout");
                Bytes buffer(mt::kMaxDatagram + 1);
                sockaddr_in source{};
                socklen_t source_size = sizeof(source);
                auto n = recvfrom(socket.fd, buffer.data(), buffer.size(), 0, reinterpret_cast<sockaddr*>(&source), &source_size);
                require(n > 0 && n <= static_cast<ssize_t>(mt::kMaxDatagram), "client UDP length");
                require(source.sin_addr.s_addr == proxy.sin_addr.s_addr && source.sin_port == proxy.sin_port, "client UDP source");
                buffer.resize(n);
                auto f = fingerprint(buffer);
                std::size_t at = 0;
                while (at < count && (matched[at] || expected[at] != f)) ++at;
                require(at < count, "unlisted client UDP buffer");
                matched[at] = true;
                packets[at] = std::move(buffer);
            }
            std::vector<Bytes> outgoing;
            std::vector<Bytes> reliable;
            std::vector<mt::Unreliable> unreliable;
            std::vector<std::uint8_t> outcomes;
            for (const auto& packet : packets) {
                auto protocol = little(packet, 0, 4);
                if (protocol == mt::kHandshakeId) {
                    require(packet.size() == mt::kChallengeSize && packet[4] == 2, "invalid challenge");
                    Bytes identity(packet.begin() + 5, packet.begin() + 5 + mt::kTokenNonceSize);
                    if (answered.contains(identity)) { outcomes.push_back(2); continue; }
                    require(answered.size() < 64, "answered challenge limit");
                    auto response = token->respond(packet);
                    require(response.has_value(), "challenge response");
                    answered.insert(identity);
                    cached_response = *response;
                    if (!connected) {
                        outgoing.push_back(cached_response);
                        retry_at = now + 200000;
                        renew_at = now + 2000000;
                    }
                    outcomes.push_back(1);
                    continue;
                }
                require(protocol == mt::kProtocolId, "unknown client protocol");
                if (!endpoint) {
                    auto seals = mt::session_seal(mt::Role::client, token->keys);
                    auto created = mt::Endpoint::create(mt::Role::client, mt::default_config(hash),
                        std::shared_ptr<mt::Opener>(std::move(seals.opener)),
                        std::shared_ptr<mt::Sealer>(std::move(seals.sealer)), now);
                    require(created.has_value(), "client endpoint create");
                    endpoint.emplace(std::move(*created));
                }
                auto f = fingerprint(packet);
                auto nonce = little(packet, mt::kHeaderSize, 8);
                auto received = endpoint->receive(packet, now);
                if (!received) {
                    auto error = received.error();
                    bool duplicate = opened.contains(f);
                    bool aged = have_nonce && nonce <= newest_nonce && newest_nonce - nonce >= mt::kReplayWindow;
                    require((error == mt::Error::malformed && (duplicate || aged)) || error == mt::Error::too_old,
                            std::string("client receive ") + mt::to_string(error));
                    if (error == mt::Error::too_old) opened.insert(f);
                    outcomes.push_back(error == mt::Error::too_old ? 5 : duplicate ? 3 : 4);
                    continue;
                }
                opened.insert(f);
                newest_nonce = have_nonce ? std::max(newest_nonce, nonce) : nonce;
                have_nonce = true;
                outcomes.push_back(received->stale ? 7 : 6);
                for (const auto& message : received->reliable) {
                    if (!connected) {
                        require(message == confirmation, "first reliable confirmation bytes");
                        connected = true;
                    }
                    reliable.push_back(message);
                }
                if (received->unreliable) unreliable.push_back(*received->unreliable);
            }
            if (!connected && now >= retry_at) {
                require(now <= 10000000, "handshake virtual timeout");
                if (cached_response.empty() || now >= renew_at) {
                    outgoing.push_back(token->request(hash));
                    renew_at = now + 2000000;
                } else outgoing.push_back(cached_response);
                retry_at = now + 200000;
            }
            mt::Unreliable sample;
            if (connected) {
                if (queued < intents.size()) {
                    require(endpoint->send(intents[queued]).has_value(), "intent queue");
                    ++queued;
                }
                if (active_tick < workload_ticks) {
                    sample.stamp = stale ? (active_tick == 0 ? 30 : 29) : active_tick + 1;
                    sample.items = input;
                }
                ++active_tick;
            }
            std::size_t sent = 0;
            if (endpoint) {
                auto flushed = endpoint->flush(now, sample);
                require(flushed.has_value() && flushed->state == mt::State::open, "client flush state");
                sent = flushed->unreliable_sent;
                for (auto& packet : flushed->datagrams) outgoing.push_back(std::move(packet));
            }
            require(outgoing.size() <= packet_limit && opened.size() <= 8192, "client packet history limit");
            Frame reply;
            reply.put(outgoing.size(), 4);
            for (const auto& packet : outgoing) {
                require(packet.size() <= mt::kMaxDatagram, "outgoing UDP limit");
                if (little(packet, 0, 4) == mt::kProtocolId) {
                    auto nonce = little(packet, mt::kHeaderSize, 8);
                    require(!emitted_nonce || nonce > last_emitted_nonce, "client nonce restarted");
                    emitted_nonce = true;
                    last_emitted_nonce = nonce;
                }
                require(sendto(socket.fd, packet.data(), packet.size(), 0, reinterpret_cast<sockaddr*>(&proxy), sizeof(proxy)) ==
                        static_cast<ssize_t>(packet.size()), "client UDP send");
                auto f = fingerprint(packet);
                reply.put(f.size, 4);
                reply.bytes.insert(reply.bytes.end(), f.digest.begin(), f.digest.end());
            }
            reply.list(reliable);
            reply.put(unreliable.size(), 4);
            for (const auto& sample : unreliable) { reply.put(sample.stamp, 4); reply.list(sample.items); }
            reply.put(outcomes.size(), 4);
            for (auto outcome : outcomes) reply.put(outcome, 1);
            reply.put(connected, 1);
            reply.put(endpoint ? 1 : 0, 1);
            reply.put(endpoint ? static_cast<std::uint8_t>(endpoint->state()) : 0, 1);
            reply.put(endpoint ? endpoint->backlog() : 0, 4);
            reply.put(queued, 4);
            reply.put(sample.stamp, 4);
            reply.put(sent, 4);
            send_frame(std::move(reply));
        }
        throw std::runtime_error("client step limit");
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
