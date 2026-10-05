#pragma once

#include <array>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <memory>
#include <optional>
#include <sodium.h>
#include <span>
#include <vector>

namespace marque::recording {

inline constexpr std::uint64_t max_bytes = 256ULL * 1024 * 1024;
inline constexpr std::uint64_t max_records = 4'000'000;
inline constexpr std::uint64_t max_duration = 86'400'000'000;
enum class Mode : std::uint8_t { client_receive = 1, server_send = 2 };
enum class Kind : std::uint8_t {
  begin = 1,
  authenticated = 2,
  command = 3,
  input = 4,
  turn = 5,
  drain = 6,
  outbound = 7,
  end = 8
};
enum class Error {
  io,
  exists,
  version,
  schema,
  length,
  ordinal,
  time,
  kind,
  phase,
  footer,
  trailing,
  config,
  packet,
  command,
  cursor,
  mismatch
};
const char *to_string(Error error);
struct Record {
  Kind kind;
  std::uint64_t time;
  std::vector<std::uint8_t> payload;
};
struct File {
  Mode mode;
  std::uint64_t origin;
  std::vector<Record> records;
};
std::expected<File, Error> read(const std::filesystem::path &path,
                                std::uint64_t schema);
class Writer {
  int fd_ = -1;
  std::filesystem::path partial_, destination_;
  std::uint64_t origin_, offset_ = 0, count_ = 0, bytes_ = 0;
  Mode mode_;
  crypto_hash_sha256_state hash_{};
  std::optional<Error> error_;
  bool write(std::span<const std::uint8_t> bytes);
  bool append_record(Kind kind, std::uint64_t time,
                     std::span<const std::uint8_t> payload);
  Writer(int fd, std::filesystem::path partial,
         std::filesystem::path destination, std::uint64_t origin, Mode mode);

public:
  static std::expected<std::unique_ptr<Writer>, Error>
  create(const std::filesystem::path &path, Mode mode, std::uint64_t schema,
         std::uint64_t origin);
  ~Writer();
  bool append(Kind kind, std::uint64_t time,
              std::span<const std::uint8_t> payload);
  bool finish(std::uint64_t time, std::uint8_t terminal);
  std::optional<Error> error() const { return error_; }
};

}
