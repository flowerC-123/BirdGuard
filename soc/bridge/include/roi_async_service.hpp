#pragma once
#include "roi_service.hpp"
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <thread>
#include <memory>
#include <atomic>
namespace roi {

using TimedInfer = std::function<Result(const Crop &, uint32_t budget_ms, unsigned worker)>;
struct AsyncConfig {
    unsigned workers = 1, capacity = 4, cache_entries = 16;
    uint32_t worker_ms = 5000, request_ms = 5500;
    bool simulated = false;
};
struct Completion {
    Packet packet;
    Bytes reply;
    uint64_t received_ms = 0, queue_ms = 0, worker_ms = 0, total_ms = 0;
    const char *reason = "complete";
};
struct AsyncStats {
    uint64_t accepted = 0, completed = 0, inference_calls = 0, cache_hits = 0;
    uint64_t duplicate_pending = 0, conflicts = 0, overload = 0, expired = 0, cancelled = 0;
    unsigned peak_pending = 0, peak_running = 0;
};
class AsyncService {
    using Key = std::pair<uint32_t, uint32_t>;
    struct Job {
        Packet packet;
        uint64_t received = 0, epoch = 0;
    };
    struct Cached {
        Packet packet;
        Bytes reply;
    };
    AsyncConfig config_;
    TimedInfer infer_;
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<std::shared_ptr<Job>> queue_;
    std::map<Key, std::shared_ptr<Job>> pending_;
    std::deque<Cached> cache_;
    std::deque<Completion> done_;
    std::deque<uint32_t> retired_sessions_;
    std::vector<std::thread> workers_;
    AsyncStats stats_;
    uint32_t session_ = 0;
    uint64_t epoch_ = 0;
    unsigned running_ = 0;
    bool stopping_ = false;
    void work(unsigned);
    Bytes error_reply(const Packet &, Status) const;

  public:
    AsyncService(AsyncConfig, TimedInfer);
    ~AsyncService();
    AsyncService(const AsyncService &) = delete;

    Bytes submit(const Packet &, uint64_t received_ms);
    bool pop(Completion &);
    bool busy() const;
    AsyncStats stats() const;
    void stop();
};
} // namespace roi
