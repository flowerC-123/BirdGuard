#pragma once
#include "roi_protocol.hpp"
#include <functional>
namespace roi {
using Infer = std::function<Result(const Crop &)>;
class Service {
    Infer infer_;
    uint32_t session_ = 0, request_ = 0;
    Bytes last_body_, last_reply_;
    bool simulated_;

  public:
    uint64_t inference_calls = 0, cache_hits = 0, rejected = 0;
    Service(Infer infer, bool simulated) : infer_(std::move(infer)), simulated_(simulated) {}
    Bytes handle(const Packet &);
};

Result worker_result(int exit_code, const std::string &log);
} // namespace roi
