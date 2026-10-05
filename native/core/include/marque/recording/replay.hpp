#pragma once

#include "marque/client/session.hpp"

namespace marque::recording {

std::vector<std::uint8_t> canonical(const client::Publication &publication);
struct ReplayResult {
  std::size_t publications = 0;
  client::LocalError terminal;
  transport::Stats stats;
  std::shared_ptr<const client::Tick> latest;
  std::shared_ptr<const motion::PredictedPose> prediction;
};
class Replay {
  File file_;
  transport::Config config_;
  client::RuntimeLimits limits_;
  std::vector<motion::PredictionMap> maps_;
  Replay(File file, transport::Config config, client::RuntimeLimits limits,
         std::vector<motion::PredictionMap> maps)
      : file_(std::move(file)), config_(config), limits_(limits),
        maps_(std::move(maps)) {}

public:
  static std::expected<Replay, Error> load(const std::filesystem::path &path);
  std::expected<ReplayResult, Error>
  run(const std::function<void(const client::Publication &)> &observer = {})
      const;
};

}
