#include "roi_async_service.hpp"
#include "platform.hpp"
#include <algorithm>
#include <stdexcept>
namespace roi {
AsyncService::AsyncService(AsyncConfig c, TimedInfer infer) : config_(c), infer_(std::move(infer)) {
    if (c.workers < 1 || c.workers > 4 || c.capacity < c.workers || c.capacity > 16 ||
        c.cache_entries > 64 || c.worker_ms < 1 || c.worker_ms > 5000 || c.request_ms < 1 ||
        c.request_ms > 5500)
        throw std::invalid_argument("invalid bounded asynchronous service configuration");
    try {
        for (unsigned i = 0; i < c.workers; ++i)
            workers_.emplace_back(&AsyncService::work, this, i);
    } catch (...) {
        stop();
        throw;
    }
}
AsyncService::~AsyncService() { stop(); }
Bytes AsyncService::error_reply(const Packet &p, Status status) const {
    Result r;
    r.status = status;
    if (config_.simulated)
        r.flags = kSimulated;
    return encode(Packet{kResult, p.session, p.request, result_body(r)});
}
Bytes AsyncService::submit(const Packet &p, uint64_t received) {
    if (p.type != kImage || !p.session || !p.request)
        return {};
    std::lock_guard<std::mutex> lock(mutex_);
    if (stopping_)
        return error_reply(p, InferenceError);
    if (session_ != p.session) {
        if (std::find(retired_sessions_.begin(), retired_sessions_.end(), p.session) !=
            retired_sessions_.end())
            return error_reply(p, StaleRequest);
        if (session_)
            retired_sessions_.push_back(session_);
        if (retired_sessions_.size() > 64)
            retired_sessions_.pop_front();
        stats_.cancelled += pending_.size();
        ++epoch_;
        session_ = p.session;
        queue_.clear();
        pending_.clear();
        cache_.clear();
        done_.clear();
    }
    const Key key{p.session, p.request};
    auto it = pending_.find(key);
    if (it != pending_.end()) {
        if (it->second->packet.body != p.body) {
            ++stats_.conflicts;
            return error_reply(p, BadRequest);
        }
        ++stats_.duplicate_pending;
        return {};
    }
    for (const auto &item : cache_)
        if (item.packet.session == p.session && item.packet.request == p.request) {
            if (item.packet.body != p.body) {
                ++stats_.conflicts;
                return error_reply(p, BadRequest);
            }
            ++stats_.cache_hits;
            return item.reply;
        }

    if (pending_.size() + done_.size() >= config_.capacity) {
        ++stats_.overload;
        return error_reply(p, InferenceError);
    }
    Crop crop;
    std::string why;
    if (!decode_crop(p.body, crop, why))
        return error_reply(p, why == "unsupported_format" ? Unsupported : BadRequest);
    auto job = std::make_shared<Job>();
    job->packet = p;
    job->received = received;
    job->epoch = epoch_;
    pending_.emplace(key, job);
    queue_.push_back(job);
    ++stats_.accepted;
    stats_.peak_pending = std::max(stats_.peak_pending, unsigned(pending_.size()));
    wake_.notify_one();
    return {};
}
void AsyncService::work(unsigned index) {
    for (;;) {
        std::shared_ptr<Job> job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
            if (stopping_)
                return;
            job = queue_.front();
            queue_.pop_front();
            ++running_;
            stats_.peak_running = std::max(stats_.peak_running, running_);
        }
        const uint64_t start = monotonic_ms();
        const uint64_t queued = start >= job->received ? start - job->received : config_.request_ms;
        Bytes reply;
        bool called = false, expired = false;
        if (queued >= config_.request_ms) {
            reply = error_reply(job->packet, InferenceTimeout);
            expired = true;
        } else {
            const uint32_t remaining = uint32_t(config_.request_ms - queued);
            const uint32_t budget = std::min(config_.worker_ms, remaining);

            Service service(
                [&](const Crop &crop) {
                    called = true;
                    return infer_(crop, budget, index);
                },
                config_.simulated);
            try {
                reply = service.handle(job->packet);
            } catch (...) {
                reply = error_reply(job->packet, InferenceError);
            }
            if (monotonic_ms() - job->received >= config_.request_ms) {
                reply = error_reply(job->packet, InferenceTimeout);
                expired = true;
            }
        }
        const uint64_t finish = monotonic_ms();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            --running_;
            if (called)
                ++stats_.inference_calls;
            if (expired)
                ++stats_.expired;
            const Key key{job->packet.session, job->packet.request};
            auto it = pending_.find(key);
            if (stopping_ || job->epoch != epoch_ || it == pending_.end() || it->second != job)
                continue;
            pending_.erase(it);
            Completion c;
            c.packet = job->packet;
            c.reply = reply;
            c.received_ms = job->received;
            c.queue_ms = queued;
            c.worker_ms = finish - start;
            c.total_ms = finish - job->received;
            c.reason = expired ? "deadline" : "complete";
            done_.push_back(std::move(c));
            ++stats_.completed;
            if (config_.cache_entries) {
                cache_.push_back(Cached{job->packet, reply});
                if (cache_.size() > config_.cache_entries)
                    cache_.pop_front();
            }
        }
    }
}
bool AsyncService::pop(Completion &c) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (done_.empty())
        return false;
    c = std::move(done_.front());
    done_.pop_front();
    return true;
}
bool AsyncService::busy() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !pending_.empty() || !done_.empty() || running_ != 0;
}
AsyncStats AsyncService::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}
void AsyncService::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        queue_.clear();
        pending_.clear();
    }
    wake_.notify_all();
    for (auto &t : workers_)
        if (t.joinable())
            t.join();
    workers_.clear();
}
} // namespace roi
