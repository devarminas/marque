#include "marque/transport/receiver.hpp"

#include <algorithm>

#include "format.hpp"

namespace marque::transport {

namespace {

std::expected<AckWindow, Error> accept(std::optional<AckWindow> window, std::uint16_t seq) {
    if (!window) {
        return AckWindow{.latest = seq, .bits = 0};
    }
    AckWindow w = *window;
    auto ahead = static_cast<std::uint16_t>(seq - w.latest);
    if (ahead == 0) {
        return std::unexpected(Error::duplicate);
    }
    if (ahead < 0x8000) {
        std::uint32_t bits = 0;
        if (ahead < kAckBits) {
            bits = w.bits << ahead | std::uint32_t{1} << (ahead - 1);
        } else if (ahead == kAckBits) {
            bits = std::uint32_t{1} << (kAckBits - 1);
        }
        return AckWindow{.latest = seq, .bits = bits};
    }
    auto behind = static_cast<std::uint16_t>(w.latest - seq);
    if (behind > kAckBits) {
        return std::unexpected(Error::too_old);
    }
    std::uint32_t bit = std::uint32_t{1} << (behind - 1);
    if (w.bits & bit) {
        return std::unexpected(Error::duplicate);
    }
    w.bits |= bit;
    return w;
}

}

Receiver::Receiver(Role role, const Config& cfg, std::shared_ptr<Opener> opener)
    : from_(peer(role)), hash_(cfg.schema_hash), opener_(std::move(opener)) {}

std::expected<Receiver, ConfigError> Receiver::create(Role role, const Config& cfg, std::shared_ptr<Opener> opener, PlaintextObserver observer) {
    if (auto ok = cfg.validate(); !ok) {
        return std::unexpected(ok.error());
    }
    if (opener == nullptr) {
        return std::unexpected(ConfigError::opener_missing);
    }
    Receiver result(role, cfg, std::move(opener));
    result.observer_=std::move(observer);
    return result;
}

std::expected<Received, Error> Receiver::receive(std::span<const std::uint8_t> d) {
    if (d.size() < kHeaderSize + opener_->overhead() || d.size() > kMaxDatagram) {
        ++stats_.malformed;
        return std::unexpected(Error::malformed);
    }
    auto h = format::read_header(d);
    if (h.protocol != kProtocolId || h.hash != hash_) {
        ++stats_.foreign;
        return std::unexpected(Error::foreign);
    }
    scratch_.clear();
    if (!opener_->open(d.first(kHeaderSize), d.subspan(kHeaderSize), scratch_)) {
        ++stats_.malformed;
        return std::unexpected(Error::malformed);
    }
    if(observer_)observer_(d.first(kHeaderSize),scratch_);
    return consume(d.first(kHeaderSize),scratch_);
}

std::expected<Received,Error> Receiver::consume(std::span<const std::uint8_t> header,std::span<const std::uint8_t> plaintext) {
    const auto h=format::read_header(header);
    auto body = format::parse_body(plaintext, from_);
    if (!body) {
        ++stats_.malformed;
        return std::unexpected(Error::malformed);
    }
    auto accepted = accept(window_, h.seq);
    if (!accepted) {
        if (accepted.error() == Error::duplicate) {
            ++stats_.duplicate;
        } else {
            ++stats_.too_old;
        }
        return std::unexpected(accepted.error());
    }

    window_ = *accepted;
    ++stats_.accepted;
    Received out{.peer_ack = h.ack, .own_ack = *accepted, .unreliable = {}, .stale = false, .reliable = {}};
    if (body->unreliable) {
        const auto& u = *body->unreliable;
        if (newest_stamp_ && u.stamp <= *newest_stamp_) {
            ++stats_.stale;
            out.stale = true;
        } else {
            newest_stamp_ = u.stamp;
            Unreliable delivered{.stamp = u.stamp, .items = {}};
            delivered.items.reserve(u.items.size());
            for (auto item : u.items) {
                delivered.items.emplace_back(item.begin(), item.end());
            }
            out.unreliable = std::move(delivered);
        }
    }
    for (const auto& e : body->entries) {
        store(e.id, e.index, e.count, e.data);
    }
    for (;;) {
        Partial& m = partial_[next_ % kWindowMessages];
        if (m.count == 0 || m.fragments.size() != m.count) {
            break;
        }
        std::vector<std::uint8_t> msg;
        for (const auto& f : m.fragments) {
            msg.insert(msg.end(), f.data.begin(), f.data.end());
        }
        buffered_ -= msg.size();
        out.reliable.push_back(std::move(msg));
        m = Partial{};
        ++next_;
    }
    return out;
}

void Receiver::store(std::uint16_t id, std::uint8_t index, std::uint8_t count, std::span<const std::uint8_t> data) {
    if (static_cast<std::uint16_t>(id - next_) >= kWindowMessages) {
        return;
    }
    Partial& m = partial_[id % kWindowMessages];
    if (m.count != 0 && m.count != count) {
        return;
    }
    auto at = std::ranges::lower_bound(m.fragments, index, {}, &Fragment::index);
    if (at != m.fragments.end() && at->index == index) {
        return;
    }
    if (buffered_ + data.size() > kWindowBytes) {
        return;
    }
    m.count = count;
    m.fragments.insert(at, Fragment{.index = index, .data = {data.begin(), data.end()}});
    buffered_ += data.size();
}

}
