#include "platform.hpp"
#include <chrono>
#include <sstream>
#include <stdexcept>
#include <cerrno>
#include <thread>
#include <algorithm>
#ifdef _WIN32
#include <io.h>
#include <fcntl.h>
#define NOMINMAX
#include <windows.h>
#else
#include <unistd.h>
#include <poll.h>
#include <fcntl.h>
#endif
namespace roi {
uint64_t monotonic_ms() {
    return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(
                        std::chrono::steady_clock::now().time_since_epoch())
                        .count());
}
bool write_all(const Bytes &b, const Writer &write, const Clock &now, uint64_t deadline) {
    size_t offset = 0;
    while (offset < b.size()) {
        if (now() >= deadline)
            return false;
        int n = write(b.data() + offset, b.size() - offset);
        if (n < 0 || size_t(n) > b.size() - offset)
            return false;
        offset += size_t(n);
    }
    return true;
}
std::string ppm_bytes(const Crop &c) {
    std::ostringstream h;
    h << "P6\n" << c.w << ' ' << c.h << "\n255\n";
    auto b = rgb_pixels(c);
    return h.str() + std::string(reinterpret_cast<const char *>(b.data()), b.size());
}
class Stdio : public Transport {
#ifndef _WIN32
    int saved_out_ = -1;
#endif
  public:
    Stdio() {
#ifdef _WIN32
        if (_setmode(0, _O_BINARY) < 0 || _setmode(1, _O_BINARY) < 0)
            throw std::runtime_error("binary stdio mode failed");
#else
        saved_out_ = fcntl(1, F_GETFL, 0);
        if (saved_out_ < 0 || fcntl(1, F_SETFL, saved_out_ | O_NONBLOCK) < 0)
            throw std::runtime_error("nonblocking stdout failed");
#endif
    }
    ~Stdio() {
#ifndef _WIN32
        if (saved_out_ >= 0)
            fcntl(1, F_SETFL, saved_out_);
#endif
    }
    int read_some(uint8_t *p, size_t n, int wait_ms) override {
#ifdef _WIN32
        HANDLE input = reinterpret_cast<HANDLE>(_get_osfhandle(0));
        if (GetFileType(input) == FILE_TYPE_PIPE) {
            DWORD available = 0;
            if (!PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
                if (GetLastError() == ERROR_BROKEN_PIPE)
                    return -1;
                throw std::runtime_error("stdin pipe query failed");
            }
            if (!available) {
                if (wait_ms > 0)
                    std::this_thread::sleep_for(std::chrono::milliseconds(wait_ms));
                return 0;
            }
            n = std::min(n, size_t(available));
        }
        int r = _read(0, p, unsigned(n));
#else
        pollfd f{0, POLLIN, 0};
        int ready = poll(&f, 1, wait_ms);
        if (ready < 0 && errno == EINTR)
            return 0;
        if (ready < 0)
            throw std::runtime_error("stdin poll failed");
        if (ready == 0)
            return 0;
        int r = int(::read(0, p, n));
#endif
        if (r < 0 && errno == EINTR)
            return 0;
        if (r < 0)
            throw std::runtime_error("stdin read failed");
        return r == 0 ? -1 : r;
    }
    int write_some(const uint8_t *p, size_t n) override {
#ifdef _WIN32
        int r = _write(1, p, unsigned(n));
#else
        int r = int(::write(1, p, n));
#endif
        if (r < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        return r;
    }
};
std::unique_ptr<Transport> stdio_transport() { return std::unique_ptr<Transport>(new Stdio); }
} // namespace roi
