#include "marque/transport/sender.hpp"

#include <algorithm>
#include <optional>

#include "format.hpp"

namespace marque::transport {

namespace {

std::uint64_t elapsed(std::uint64_t now, std::uint64_t since) { return now < since ? 0 : now - since; }

std::int64_t section_cost(const std::vector<format::Entry>& entries) {
    return entries.empty() ? static_cast<std::int64_t>(format::kReliableSectionHeader) : 0;
}

std::size_t fit_items(const std::vector<std::vector<std::uint8_t>>& items, std::int64_t room) {
    auto used = static_cast<std::int64_t>(format::kUnreliableSectionHeader);
    for (std::size_t i = 0; i < items.size(); ++i) {
        used += static_cast<std::int64_t>(format::item_size(items[i].size()));
        if (used > room) {
            return i;
        }
    }
    return items.size();
}

}

const char* to_string(State s) {
    switch (s) {
    case State::open:
        return "open";
    case State::timed_out:
        return "timed_out";
    case State::slow_client:
        return "slow_client";
    }
    return "state?";
}

struct Sender::Datagram {
    std::int64_t size = 0;
    std::int64_t cap = 0;
    std::size_t items = 0;
    std::vector<format::Entry> entries;
    std::vector<FragmentRef> refs;
};

Sender::Sender(Role role, const Config& cfg, std::uint64_t now)
    : role_(role), cfg_(cfg), last_send_(now), last_receive_(now) {}

std::expected<Sender, ConfigError> Sender::create(Role role, const Config& cfg, std::uint64_t now) {
    if (auto ok = cfg.validate(); !ok) {
        return std::unexpected(ok.error());
    }
    return Sender(role, cfg, now);
}

std::expected<void, Error> Sender::send(std::span<const std::uint8_t> msg) {
    if (state_ != State::open) {
        return std::unexpected(Error::closed);
    }
    if (msg.empty() || msg.size() > kMaxMessage) {
        return std::unexpected(Error::message);
    }
    std::size_t n = (msg.size() + kFragmentSize - 1) / kFragmentSize;
    queue_.push_back(OutMessage{.data = {msg.begin(), msg.end()}, .fragments = std::vector<OutFragment>(n)});
    queued_bytes_ += msg.size();
    if (queue_.size() > cfg_.backlog_limit || queued_bytes_ > cfg_.backlog_bytes) {
        close(State::slow_client);
    }
    return {};
}

void Sender::close(State state) {
    state_ = state;
    queue_ = {};
    queued_bytes_ = 0;
    ring_ = {};
}

void Sender::observe(AckWindow peer_ack, AckWindow own_ack, std::uint64_t now) {
    if (state_ != State::open) {
        return;
    }
    last_receive_ = std::max(last_receive_, now);
    own_ = own_ack;
    if (peer_ack == kNoAcks) {
        return;
    }
    ack(peer_ack.latest);
    for (std::uint16_t i = 0; i < kAckBits; ++i) {
        if (peer_ack.bits & (std::uint32_t{1} << i)) {
            ack(static_cast<std::uint16_t>(peer_ack.latest - 1 - i));
        }
    }
    while (!queue_.empty() && std::ranges::all_of(queue_.front().fragments, &OutFragment::acked)) {
        queued_bytes_ -= queue_.front().data.size();
        queue_.pop_front();
        ++front_;
    }
}

void Sender::ack(std::uint16_t seq) {
    SentDatagram& p = ring_[seq % ring_.size()];
    if (!p.live || p.seq != seq) {
        return;
    }
    p.live = false;
    for (const auto& f : p.fragments) {
        if (std::uint64_t i = f.serial - front_; i < queue_.size()) {
            queue_[i].fragments[f.index].acked = true;
        }
    }
    p.fragments = {};
}

std::expected<Flushed, Error> Sender::flush(std::uint64_t now, const Unreliable& unreliable) {
    if (state_ == State::open && elapsed(now, last_receive_) >= kTimeoutAfter) {
        close(State::timed_out);
    }
    if (state_ != State::open) {
        return Flushed{.datagrams = {}, .unreliable_sent = 0, .state = state_};
    }
    const auto empty = static_cast<std::int64_t>(kHeaderSize + cfg_.seal->overhead());
    for (const auto& item : unreliable.items) {
        if (item.empty() ||
            static_cast<std::size_t>(empty) + format::kUnreliableSectionHeader + format::item_size(item.size()) >
                kMaxDatagram) {
            return std::unexpected(Error::item);
        }
    }

    constexpr auto max_datagram = static_cast<std::int64_t>(kMaxDatagram);
    auto left = static_cast<std::int64_t>(cfg_.tick_budget);
    std::vector<Datagram> done;
    std::optional<Datagram> cur;
    auto room = [&] { return std::min(max_datagram, cur ? left - cur->size : left); };
    auto open = [&] {
        if (cur) {
            left -= cur->size;
            done.push_back(std::move(*cur));
        }
        cur = Datagram{.size = empty, .cap = std::min(max_datagram, left), .items = 0, .entries = {}, .refs = {}};
    };

    std::size_t window_bytes = 0;
    bool packing = true;
    for (std::size_t i = 0; packing && i < queue_.size(); ++i) {
        OutMessage& m = queue_[i];
        window_bytes += m.data.size();
        if (i >= kWindowMessages || window_bytes > kWindowBytes) {
            break;
        }
        for (std::size_t j = 0; j < m.fragments.size(); ++j) {
            OutFragment& f = m.fragments[j];
            if (f.acked || (f.sent && elapsed(now, f.last_sent) < cfg_.resend_after)) {
                continue;
            }
            std::size_t lo = j * kFragmentSize;
            auto data = std::span<const std::uint8_t>(m.data).subspan(lo, std::min(kFragmentSize, m.data.size() - lo));
            auto add = static_cast<std::int64_t>(format::entry_size(data.size()));
            if (!cur || cur->size + add + section_cost(cur->entries) > cur->cap) {
                if (empty + static_cast<std::int64_t>(format::kReliableSectionHeader) + add > room()) {
                    packing = false;
                    break;
                }
                open();
            }
            cur->size += add + section_cost(cur->entries);
            std::uint64_t serial = front_ + i;
            cur->entries.push_back(format::Entry{.id = static_cast<std::uint16_t>(serial),
                                                 .index = static_cast<std::uint8_t>(j),
                                                 .count = static_cast<std::uint8_t>(m.fragments.size()),
                                                 .data = data});
            cur->refs.push_back(FragmentRef{.serial = serial, .index = static_cast<std::uint8_t>(j)});
            f.sent = true;
            f.last_sent = now;
        }
    }

    std::size_t sent = 0;
    if (!unreliable.items.empty()) {
        std::size_t in_cur = cur ? fit_items(unreliable.items, cur->cap - cur->size) : 0;
        std::size_t in_new = fit_items(unreliable.items, room() - empty);
        if (in_cur >= in_new && in_cur > 0) {
            sent = in_cur;
        } else if (in_new > 0) {
            open();
            sent = in_new;
        }
        if (sent > 0) {
            cur->items = sent;
        }
    }
    if (cur) {
        done.push_back(std::move(*cur));
    }
    if (done.empty() && elapsed(now, last_send_) >= kKeepaliveAfter) {
        done.emplace_back();
    }

    Flushed out{.datagrams = {}, .unreliable_sent = sent, .state = State::open};
    out.datagrams.reserve(done.size());
    for (Datagram& d : done) {
        std::uint16_t seq = next_seq_++;
        ring_[seq % ring_.size()] = SentDatagram{.live = true, .seq = seq, .fragments = std::move(d.refs)};

        std::vector<std::uint8_t> header;
        header.reserve(kHeaderSize);
        format::put_header(header, format::Header{
                                       .protocol = kProtocolId, .hash = cfg_.schema_hash, .seq = seq, .ack = own_});
        std::vector<std::uint8_t> body;
        format::put_body(body, role_, unreliable.stamp,
                         std::span(unreliable.items).first(d.items), d.entries);
        std::vector<std::uint8_t> datagram;
        datagram.reserve(kMaxDatagram);
        datagram.insert(datagram.end(), header.begin(), header.end());
        cfg_.seal->seal(header, body, datagram);
        out.datagrams.push_back(std::move(datagram));
    }
    if (!done.empty()) {
        last_send_ = now;
    }
    return out;
}

}
