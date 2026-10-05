#pragma once

#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

#include "marque/client/session.hpp"
#include "marque/transport/handshake.hpp"

namespace marque::client {

class Runtime {
    struct Command { Action action; std::size_t bytes; };
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::thread worker_;
    bool stop_=false;
    Connection connection_=Connection::disconnected;
    LocalError error_=LocalError::none;
    std::deque<Command> commands_;
    std::optional<motion::Input> input_;
    std::unique_ptr<Session> session_;
    std::optional<std::filesystem::path> recording_path_;
    std::optional<recording::Error> recording_error_;
    const std::vector<motion::PredictionMap> maps_;
    const RuntimeLimits limits_;
    std::size_t queued_bytes_=0;
    void run(transport::ConnectToken token);
    void fail(LocalError error);
public:
    explicit Runtime(std::vector<motion::PredictionMap> maps={},RuntimeLimits limits={})
        : maps_(std::move(maps)),limits_(limits) {}
    Runtime(const Runtime&)=delete;
    Runtime& operator=(const Runtime&)=delete;
    ~Runtime();
    bool record_to(const std::filesystem::path& path);
    std::optional<recording::Error> recording_error() const;
    bool connect(std::span<const std::uint8_t> token);
    void disconnect();
    bool queue(Action action);
    bool move(double dx,double dz,bool jump);
    std::optional<Publication> take();
    std::shared_ptr<const motion::PredictedPose> prediction() const;
    Connection connection() const;
    LocalError error() const;
};

}
