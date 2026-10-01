#include "marque/transport/session_seal.hpp"

#include "crypto.hpp"
#include "format.hpp"

namespace marque::transport {

SessionSeal::SessionSeal(Role role, const SessionKeys& keys)
    : send_key_(role == Role::server ? keys.server_to_client : keys.client_to_server),
      recv_key_(role == Role::server ? keys.client_to_server : keys.server_to_client) {}

void SessionSeal::seal(std::span<const std::uint8_t> header, std::span<const std::uint8_t> body,
                       std::vector<std::uint8_t>& out) {
    auto n = send_nonce_++;
    format::put_u64(out, n);
    crypto::ietf_seal(send_key_, n, body, header, out);
}

bool SessionSeal::open(std::span<const std::uint8_t> header, std::span<const std::uint8_t> sealed,
                       std::vector<std::uint8_t>& out) {
    if (sealed.size() < kSessionOverhead) {
        return false;
    }
    auto n = format::load_le(sealed.first(8));
    if (!fresh(n) || !crypto::ietf_open(recv_key_, n, sealed.subspan(8), header, out)) {
        return false;
    }
    accept(n);
    return true;
}

bool SessionSeal::fresh(std::uint64_t n) const {
    if (!have_ || n > newest_) {
        return true;
    }
    auto behind = newest_ - n;
    return behind < kReplayWindow && (bits_ & std::uint64_t{1} << behind) == 0;
}

void SessionSeal::accept(std::uint64_t n) {
    if (!have_) {
        have_ = true;
        newest_ = n;
        bits_ = 1;
    } else if (n > newest_) {
        auto ahead = n - newest_;
        bits_ = ahead < kReplayWindow ? bits_ << ahead | 1 : 1;
        newest_ = n;
    } else {
        bits_ |= std::uint64_t{1} << (newest_ - n);
    }
}

}
