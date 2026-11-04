#pragma once
#include "roi_service.hpp"
#include <memory>
#include <functional>
namespace roi {
uint64_t monotonic_ms();
using Writer = std::function<int(const uint8_t *, size_t)>;
using Clock = std::function<uint64_t()>;
bool write_all(const Bytes &, const Writer &, const Clock &, uint64_t deadline_ms);
class Transport {
  public:
    virtual ~Transport() = default;
    virtual int read_some(uint8_t *, size_t, int wait_ms) = 0;
    virtual int write_some(const uint8_t *, size_t) = 0;
};
std::unique_ptr<Transport> stdio_transport();
#ifndef _WIN32
std::unique_ptr<Transport> serial_transport(const std::string &, unsigned baud);

std::unique_ptr<Transport> mmap_serial_transport(const std::string &pinmux_dev);
Result run_worker(const Crop &, const std::string &executable, const std::string &model,
                  const std::string &scratch, uint32_t timeout_ms);

std::unique_ptr<Transport> serial_transport_fixed(const std::string &, unsigned fixed_baud);

class PersistentWorker {
    struct Impl;
    std::unique_ptr<Impl> impl_;

  public:
    PersistentWorker(const std::string &executable, const std::string &model,
                     const std::string &scratch);
    ~PersistentWorker();
    void warm(uint32_t startup_ms = 30000);
    Result run(const Crop &, uint32_t timeout_ms);
    PersistentWorker(const PersistentWorker &) = delete;
};
#endif
std::string ppm_bytes(const Crop &);
} // namespace roi
