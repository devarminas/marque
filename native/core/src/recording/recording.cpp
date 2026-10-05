#include "marque/recording/recording.hpp"

#include <algorithm>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <sys/stat.h>
#include <unistd.h>

#include "../transport/format.hpp"
#include "marque/transport/config.hpp"
#include "marque/wire/codec.hpp"

namespace marque::recording {
namespace {
constexpr std::array<std::uint8_t, 8> magic = {'M', 'R', 'Q', 'R',
                                               'E', 'C', '0', '1'};
std::uint64_t load(std::span<const std::uint8_t> bytes) {
  std::uint64_t value = 0;
  for (std::size_t i = 0; i < bytes.size(); ++i)
    value |= std::uint64_t(bytes[i]) << (8 * i);
  return value;
}
std::vector<std::uint8_t> envelope(Kind kind, std::uint64_t ordinal,
                                   std::uint64_t offset, std::size_t length) {
  std::vector<std::uint8_t> out;
  wire::codec::Writer w(out);
  w.u8(static_cast<std::uint8_t>(kind));
  w.u8(0);
  w.u16(0);
  w.u32(length);
  w.u64(ordinal);
  w.u64(offset);
  (void)w.finish();
  return out;
}
}
const char *to_string(Error e) {
  switch (e) {
  case Error::io:
    return "io";
  case Error::exists:
    return "exists";
  case Error::version:
    return "version";
  case Error::schema:
    return "schema";
  case Error::length:
    return "length";
  case Error::ordinal:
    return "ordinal";
  case Error::time:
    return "time";
  case Error::kind:
    return "kind";
  case Error::phase:
    return "phase";
  case Error::footer:
    return "footer";
  case Error::trailing:
    return "trailing";
  case Error::config:
    return "config";
  case Error::packet:
    return "packet";
  case Error::command:
    return "command";
  case Error::cursor:
    return "cursor";
  case Error::mismatch:
    return "mismatch";
  }
  return "recording?";
}
Writer::Writer(int fd, std::filesystem::path partial,
               std::filesystem::path destination, std::uint64_t origin,
               Mode mode)
    : fd_(fd), partial_(std::move(partial)),
      destination_(std::move(destination)), origin_(origin), mode_(mode) {
  crypto_hash_sha256_init(&hash_);
}
Writer::~Writer() {
  if (fd_ >= 0)
    ::close(fd_);
}
bool Writer::write(std::span<const std::uint8_t> bytes) {
  if (error_)
    return false;
  if (bytes.size() > max_bytes - bytes_) {
    error_ = Error::length;
    return false;
  }
  const auto result = ::write(fd_, bytes.data(), bytes.size());
  if (result != static_cast<ssize_t>(bytes.size())) {
    error_ = Error::io;
    return false;
  }
  crypto_hash_sha256_update(&hash_, bytes.data(), bytes.size());
  bytes_ += bytes.size();
  return true;
}
std::expected<std::unique_ptr<Writer>, Error>
Writer::create(const std::filesystem::path &path, Mode mode,
               std::uint64_t schema, std::uint64_t origin) {
  if (mode != Mode::client_receive && mode != Mode::server_send)
    return std::unexpected(Error::kind);
  if (origin >
      std::uint64_t(std::numeric_limits<std::int64_t>::max()) - max_duration)
    return std::unexpected(Error::time);
  if (path.filename().string().find(".partial.") != std::string::npos)
    return std::unexpected(Error::phase);
  std::error_code ec;
  const bool exists = std::filesystem::exists(path, ec);
  if (ec)
    return std::unexpected(Error::io);
  if (exists)
    return std::unexpected(Error::exists);
  auto partial = path;
  partial += ".partial.XXXXXX";
  auto name = partial.string();
  std::vector<char> buffer(name.begin(), name.end());
  buffer.push_back(0);
  const int fd = mkstemp(buffer.data());
  if (fd < 0)
    return std::unexpected(Error::io);
  auto writer = std::unique_ptr<Writer>(
      new Writer(fd, buffer.data(), path, origin, mode));
  std::vector<std::uint8_t> header(magic.begin(), magic.end());
  wire::codec::Writer w(header);
  w.u32(1);
  w.u8(static_cast<std::uint8_t>(mode));
  w.u8(0);
  w.u16(0);
  w.u64(schema);
  w.u64(origin);
  (void)w.finish();
  if (!writer->write(header))
    return std::unexpected(*writer->error_);
  return writer;
}
bool Writer::append(Kind kind, std::uint64_t time,
                    std::span<const std::uint8_t> payload) {
  if (kind == Kind::end) {
    error_ = Error::phase;
    return false;
  }
  return append_record(kind, time, payload);
}

bool Writer::append_record(Kind kind, std::uint64_t time,
                           std::span<const std::uint8_t> payload) {
  if (error_)
    return false;
  if (kind < Kind::begin || kind > Kind::end ||
      ((count_ == 0) != (kind == Kind::begin)) ||
      (mode_ == Mode::server_send && kind != Kind::begin &&
       kind != Kind::outbound && kind != Kind::end) ||
      (mode_ == Mode::client_receive && kind == Kind::outbound)) {
    error_ = Error::phase;
    return false;
  }
  if (fd_ < 0) {
    error_ = Error::phase;
    return false;
  }
  if (time < origin_ || time - origin_ > max_duration) {
    error_ = Error::time;
    return false;
  }
  if (count_ >= max_records || payload.size() > 1024 * 1024 - 8 ||
      payload.size() + 32 > max_bytes - bytes_) {
    error_ = Error::length;
    return false;
  }
  const auto relative = time - origin_;
  offset_ = std::max(offset_, relative);
  std::vector<std::uint8_t> core_time;
  wire::codec::Writer w(core_time);
  w.u64(relative);
  (void)w.finish();
  if (!write(envelope(kind, count_, offset_, payload.size() + 8)) ||
      !write(core_time) || !write(payload))
    return false;
  ++count_;
  return true;
}
bool Writer::finish(std::uint64_t time, std::uint8_t terminal) {
  if (error_ || fd_ < 0)
    return false;
  if (terminal > 8) {
    error_ = Error::footer;
    return false;
  }
  std::array<std::uint8_t, 32> digest;
  auto hash = hash_;
  crypto_hash_sha256_final(&hash, digest.data());
  std::vector<std::uint8_t> footer;
  wire::codec::Writer w(footer);
  w.u8(terminal);
  w.u64(count_);
  w.u64(bytes_);
  (void)w.finish();
  footer.insert(footer.end(), digest.begin(), digest.end());
  if (!append_record(Kind::end, time, footer))
    return false;
  if (fsync(fd_) != 0) {
    error_ = Error::io;
    return false;
  }
  const int closed = ::close(fd_);
  fd_ = -1;
  if (closed != 0) {
    error_ = Error::io;
    return false;
  }
  if (::renameat2(AT_FDCWD, partial_.c_str(), AT_FDCWD, destination_.c_str(),
                  RENAME_NOREPLACE) != 0) {
    error_ = Error::io;
    return false;
  }
  return true;
}
std::expected<File, Error> read(const std::filesystem::path &path,
                                std::uint64_t schema) {
  if (path.filename().string().find(".partial.") != std::string::npos)
    return std::unexpected(Error::phase);
  std::error_code ec;
  const auto size = std::filesystem::file_size(path, ec);
  if (ec)
    return std::unexpected(Error::io);
  if (size < 32 || size > max_bytes)
    return std::unexpected(Error::length);
  std::ifstream input(path, std::ios::binary);
  std::vector<std::uint8_t> bytes(size);
  if (!input.read(reinterpret_cast<char *>(bytes.data()), bytes.size()))
    return std::unexpected(Error::io);
  const auto all = std::span<const std::uint8_t>(bytes);
  if (!std::equal(magic.begin(), magic.end(), bytes.begin()) ||
      load(all.subspan(8, 4)) != 1 || load(all.subspan(13, 3)) != 0)
    return std::unexpected(Error::version);
  if (load(all.subspan(16, 8)) != schema)
    return std::unexpected(Error::schema);
  const auto mode = static_cast<Mode>(bytes[12]);
  if (mode != Mode::client_receive && mode != Mode::server_send)
    return std::unexpected(Error::kind);
  const auto origin = load(all.subspan(24, 8));
  if (origin >
      std::uint64_t(std::numeric_limits<std::int64_t>::max()) - max_duration)
    return std::unexpected(Error::time);
  File out{mode, origin, {}};
  std::size_t at = 32;
  std::uint64_t offset = 0;
  bool ended = false;
  while (at < bytes.size()) {
    if (ended)
      return std::unexpected(Error::trailing);
    if (out.records.size() >= max_records || bytes.size() - at < 24)
      return std::unexpected(Error::length);
    auto header = all.subspan(at, 24);
    const auto kind = static_cast<Kind>(header[0]);
    if (kind < Kind::begin || kind > Kind::end ||
        load(header.subspan(1, 3)) != 0)
      return std::unexpected(Error::kind);
    if ((out.records.empty() && kind != Kind::begin) ||
        (!out.records.empty() && kind == Kind::begin) ||
        (mode == Mode::server_send && kind != Kind::begin &&
         kind != Kind::outbound && kind != Kind::end) ||
        (mode == Mode::client_receive && kind == Kind::outbound))
      return std::unexpected(Error::phase);
    const auto length = load(header.subspan(4, 4)),
               ordinal = load(header.subspan(8, 8)),
               next = load(header.subspan(16, 8));
    if (ordinal != out.records.size())
      return std::unexpected(Error::ordinal);
    if (next < offset || next > max_duration)
      return std::unexpected(Error::time);
    offset = next;
    if (length < 8 || length > 1024 * 1024 || length > bytes.size() - at - 24)
      return std::unexpected(Error::length);
    const auto payload = all.subspan(at + 24, length);
    const auto core = load(payload.first(8));
    if (core > next || core > max_duration)
      return std::unexpected(Error::time);
    if (kind == Kind::end) {
      if (length != 57 || payload[8] > 8 ||
          load(payload.subspan(9, 8)) != out.records.size() ||
          load(payload.subspan(17, 8)) != at)
        return std::unexpected(Error::footer);
      std::array<std::uint8_t, 32> digest;
      crypto_hash_sha256(digest.data(), bytes.data(), at);
      if (!std::equal(digest.begin(), digest.end(), payload.begin() + 25))
        return std::unexpected(Error::footer);
      ended = true;
    }
    out.records.push_back(
        {kind, origin + core, {payload.begin() + 8, payload.end()}});
    at += 24 + length;
  }
  if (!ended || out.records.size() < 2)
    return std::unexpected(Error::footer);
  if (out.mode == Mode::server_send) {
    if (out.records.front().payload.size() != 40)
      return std::unexpected(Error::config);
    wire::codec::Reader config(out.records.front().payload);
    transport::Config c;
    c.schema_hash = config.u64();
    c.tick_budget = config.u64();
    c.backlog_limit = config.u64();
    c.backlog_bytes = config.u64();
    c.resend_after = config.u64();
    if (c.schema_hash != schema || !c.validate() ||
        c.tick_budget > 1024 * 1024 || c.backlog_bytes > max_bytes ||
        config.finish())
      return std::unexpected(Error::config);
    for (const auto &record : out.records)
      if (record.kind == Kind::outbound) {
        if (record.payload.size() < transport::kHeaderSize ||
            record.payload.size() > transport::kMaxDatagram - 24)
          return std::unexpected(Error::packet);
        const auto header = transport::format::read_header(record.payload);
        if (header.protocol != transport::kProtocolId || header.hash != schema)
          return std::unexpected(Error::packet);
      }
  }
  return out;
}
}
