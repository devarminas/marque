#include "marque/motion/prediction.hpp"
#include "marque/transport/endpoint.hpp"

#include <bit>
#include <iostream>
#include <map>
#include <stdexcept>

namespace mo = marque::motion;
namespace tr = marque::transport;
namespace w = marque::wire;
using Bytes = std::vector<std::uint8_t>;

struct Reader {
    const Bytes &bytes;
    std::size_t at = 0;
    std::uint64_t number(unsigned size) {
        if (size > 8 || at + size > bytes.size())
            throw std::runtime_error("truncated frame");
        std::uint64_t v = 0;
        for (unsigned i = 0; i < size; ++i)
            v |= static_cast<std::uint64_t>(bytes[at++]) << (i * 8);
        return v;
    }
    double real() { return std::bit_cast<double>(number(8)); }
    Bytes packet() {
        auto size = number(2);
        if (size > 1200 || at + size > bytes.size())
            throw std::runtime_error("packet bound");
        Bytes value(bytes.begin() + at, bytes.begin() + at + size);
        at += size;
        return value;
    }
};
void number(Bytes &b, std::uint64_t v, unsigned size) {
    for (unsigned i = 0; i < size; ++i)
        b.push_back(static_cast<std::uint8_t>(v >> (i * 8)));
}
void real(Bytes &b, double v) { number(b, std::bit_cast<std::uint64_t>(v), 8); }
void send_frame(const Bytes &bytes) {
    Bytes size;
    number(size, bytes.size(), 4);
    std::cout.write(reinterpret_cast<const char *>(size.data()), 4);
    std::cout.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
    std::cout.flush();
    if (!std::cout)
        throw std::runtime_error("response write");
}
template <class T, class E> T required(std::expected<T, E> v) {
    if (!v)
        throw std::runtime_error("required operation refused");
    return std::move(*v);
}
template <class E> void required(std::expected<void, E> v) {
    if (!v)
        throw std::runtime_error("required operation refused");
}

int main() {
    try {
        auto endpoint = required(tr::Endpoint::create(
            tr::Role::client, tr::default_config(w::schema_hash),
            std::make_shared<tr::Plain>(), std::make_shared<tr::Plain>(), 0));
        std::optional<mo::Prediction> prediction;
        std::map<std::uint32_t, w::OwnerMotion> pending;
        std::map<std::uint32_t, w::TickClose> closes;
        std::optional<w::OwnerMotion> published;
        std::uint16_t latest = 0;
        bool have_window = false;
        std::uint64_t previous_now = 0;
        for (unsigned iteration = 0; iteration < 1000; ++iteration) {
            Bytes header(4);
            std::cin.read(reinterpret_cast<char *>(header.data()), 4);
            if (std::cin.eof() && std::cin.gcount() == 0)
                return 0;
            if (std::cin.gcount() != 4)
                throw std::runtime_error("frame header");
            Reader h{header};
            const auto length = h.number(4);
            if (length > 256 * 1024)
                throw std::runtime_error("frame capacity");
            Bytes frame(length);
            std::cin.read(reinterpret_cast<char *>(frame.data()), length);
            if (static_cast<std::uint64_t>(std::cin.gcount()) != length)
                throw std::runtime_error("frame body");
            Reader r{frame};
            const auto now = r.number(8);
            const auto sampling = r.number(1);
            if (sampling > 1)
                throw std::runtime_error("sample presence");
            const mo::Input sample{r.real(), r.real(), r.number(1) != 0};
            const auto command = r.packet();
            if (command.size() > 1032)
                throw std::runtime_error("intent capacity");
            const auto count = r.number(2);
            if (now < previous_now || count > 256)
                throw std::runtime_error("clock or batch bound");
            previous_now = now;
            std::size_t replayed = 0;
            for (std::uint64_t i = 0; i < count; ++i) {
                const auto bytes = r.packet();
                auto got = endpoint.receive(bytes, now);
                if (!got) {
                    if (got.error() == tr::Error::duplicate)
                        continue;
                    if (got.error() == tr::Error::too_old &&
                        bytes.size() >= 16) {
                        const std::uint16_t seq = static_cast<std::uint16_t>(
                            bytes[12] | bytes[13] << 8);
                        if (have_window &&
                            static_cast<std::uint16_t>(seq - latest) >=
                                0x8000 &&
                            static_cast<std::uint16_t>(latest - seq) >
                                tr::kAckBits)
                            continue;
                    }
                    throw std::runtime_error("actual endpoint receive refused");
                }
                latest = got->own_ack.latest;
                have_window = true;
                if (got->unreliable)
                    for (const auto &data : got->unreliable->items) {
                        const auto message = required(w::decode_state(data));
                        const auto *m = std::get_if<w::OwnerMotion>(&message);
                        if (!m || m->tick() != got->unreliable->stamp)
                            throw std::runtime_error("baseline producing tick");
                        pending.insert_or_assign(m->tick(), *m);
                    }
                for (const auto &data : got->reliable) {
                    const auto message = required(w::decode_events(data));
                    const auto *close = std::get_if<w::TickClose>(&message);
                    if (!close || close->state_items() != 1 ||
                        close->event_end() != 0)
                        throw std::runtime_error("fixture complete prefix");
                    closes.insert_or_assign(close->tick(), *close);
                }
            }
            if (r.at != frame.size())
                throw std::runtime_error("trailing frame");
            if (!command.empty()) {
                required(w::decode_intents(command));
                required(endpoint.send(command));
            }
            for (auto it = pending.rbegin(); it != pending.rend(); ++it) {
                if (published && it->first <= published->tick())
                    break;
                const auto close = closes.find(it->first);
                if (close == closes.end())
                    continue;
                const auto &m = it->second;
                if (close->second.stream() != m.stream() ||
                    close->second.epoch() != m.epoch())
                    throw std::runtime_error("publication identity");
                auto complete =
                    required(mo::PublishedBaseline::complete(m, it->first));
                if (!prediction)
                    prediction = required(mo::Prediction::create(
                        complete,
                        {{m.half_extent(), m.ground_y(), nullptr},
                         m.map_id(),
                         m.map_revision()},
                        now));
                else
                    replayed = required(prediction->reconcile(complete));
                published = m;
                break;
            }
            while (pending.size() > 256)
                pending.erase(pending.begin());
            while (closes.size() > 256)
                closes.erase(closes.begin());
            tr::Unreliable input;
            if (prediction) {
                if (sampling)
                    required(prediction->sample(sample));
                required(prediction->advance(now));
                for (const auto &m : prediction->inputs()) {
                    Bytes data;
                    required(w::encode(m, data));
                    input.items.push_back(std::move(data));
                }
                if (!prediction->inputs().empty())
                    input.stamp = prediction->inputs().front().seq();
            }
            auto flushed = required(endpoint.flush(now, input));
            if (flushed.state != tr::State::open ||
                flushed.datagrams.size() > 256)
                throw std::runtime_error("endpoint closed or packet count");
            Bytes response;
            number(response, prediction.has_value(), 1);
            const auto state =
                prediction ? prediction->pose()->state : mo::State{};
            for (double value :
                 {state.x, state.y, state.z, state.vy, state.dx, state.dz})
                real(response, value);
            number(response, prediction ? prediction->pose()->tick : 0, 4);
            number(response,
                   prediction ? static_cast<unsigned>(prediction->pose()->mode)
                              : 0,
                   1);
            number(response, input.stamp, 4);
            number(response, published ? published->tick() : 0, 4);
            number(response, published ? published->input_seq() : 0, 4);
            number(response, replayed, 4);
            for (double value :
                 {published ? static_cast<double>(published->x()) : 0,
                  published ? static_cast<double>(published->y()) : 0,
                  published ? static_cast<double>(published->z()) : 0})
                real(response, value);
            number(response, published && published->grounded(), 1);
            number(response, flushed.datagrams.size(), 2);
            for (const auto &bytes : flushed.datagrams) {
                number(response, bytes.size(), 2);
                response.insert(response.end(), bytes.begin(), bytes.end());
            }
            send_frame(response);
        }
        throw std::runtime_error("iteration capacity");
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
