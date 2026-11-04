#ifndef _WIN32
#include "platform.hpp"
#include <unistd.h>
#include <fcntl.h>
#include <termios.h>
#include <poll.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <signal.h>
#include <spawn.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <iostream>
extern char **environ;
namespace roi {
struct Fd {
    int fd = -1;
    explicit Fd(int n = -1) : fd(n) {}
    ~Fd() {
        if (fd >= 0)
            ::close(fd);
    }
    Fd(const Fd &) = delete;
};
class Serial : public Transport {
    Fd port_;
    termios saved_{};
    bool configured_ = false;

  public:
    Serial(const std::string &path, unsigned baud)
        : port_(::open(path.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)) {
        if (port_.fd < 0)
            throw std::runtime_error("open explicit serial device failed");
        if (tcgetattr(port_.fd, &saved_) < 0)
            throw std::runtime_error("not a supported TTY");
#ifdef TIOCEXCL
        if (ioctl(port_.fd, TIOCEXCL) < 0)
            throw std::runtime_error("cannot exclusively acquire TTY");
#endif
        termios t = saved_;
        cfmakeraw(&t);
        t.c_cflag &= ~(CSIZE | PARENB | CSTOPB);
        t.c_cflag |= CS8 | CLOCAL | CREAD;
#ifdef CRTSCTS
        t.c_cflag &= ~CRTSCTS;
#endif
        t.c_iflag &= ~(IXON | IXOFF | IXANY);
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;

        speed_t speed = B0;
        if (baud == 115200)
            speed = B115200;
#ifdef B921600
        else if (baud == 921600)
            speed = B921600;
#endif
        bool baud_set = false;
        if (speed != B0) {
            if (cfsetispeed(&t, speed) >= 0 && cfsetospeed(&t, speed) >= 0 &&
                tcsetattr(port_.fd, TCSANOW, &t) >= 0)
                baud_set = true;
        } else {

            if (tcsetattr(port_.fd, TCSANOW, &t) >= 0)
                baud_set = true;
            std::fprintf(stderr,
                         "[warn] baud %u is not a standard termios rate; "
                         "keeping the hardware baud of %s\n",
                         baud, path.c_str());
        }
        if (!baud_set) {

            std::fprintf(stderr,
                         "[warn] serial setup partially failed on %s; "
                         "using device defaults (hardware baud)\n",
                         path.c_str());
        }
        configured_ = true;
        termios actual{};
        if (tcgetattr(port_.fd, &actual) >= 0 && speed != B0 &&
            (cfgetispeed(&actual) != speed || cfgetospeed(&actual) != speed)) {

            std::fprintf(stderr, "[warn] baud readback mismatch on %s (requested %u)\n",
                         path.c_str(), baud);
        }
    }
    ~Serial() {
        if (configured_)
            tcsetattr(port_.fd, TCSANOW, &saved_);
    }
    int read_some(uint8_t *p, size_t n, int wait_ms) override {
        pollfd f{port_.fd, POLLIN, 0};
        int ready = poll(&f, 1, wait_ms);
        if (ready < 0 && errno == EINTR)
            return 0;
        if (ready < 0)
            throw std::runtime_error("serial poll error");
        if (!ready)
            return 0;
        if (f.revents & (POLLERR | POLLHUP | POLLNVAL))
            throw std::runtime_error("serial disconnected");
        int r = int(::read(port_.fd, p, n));
        if (r < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        if (r < 0)
            throw std::runtime_error("serial read error");
        return r;
    }
    int write_some(const uint8_t *p, size_t n) override {
        pollfd f{port_.fd, POLLOUT, 0};
        int ready = poll(&f, 1, 20);
        if (ready < 0 && errno == EINTR)
            return 0;
        if (ready < 0)
            return -1;
        if (!ready)
            return 0;
        if (f.revents & (POLLERR | POLLHUP | POLLNVAL))
            return -1;
        int r = int(::write(port_.fd, p, n));
        if (r < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        return r;
    }
};
std::unique_ptr<Transport> serial_transport(const std::string &path, unsigned baud) {
    return std::unique_ptr<Transport>(new Serial(path, baud));
}

class MmapSerial : public Transport {

    static const uint32_t kBase = 0x20810000UL;
    static const uint32_t kPage = 4096UL;
    static const uint32_t kRBR = 0x00;
    static const uint32_t kIER = 0x04;
    static const uint32_t kFCR = 0x08;
    static const uint32_t kLCR = 0x0C;
    static const uint32_t kMCR = 0x10;
    static const uint32_t kMSR = 0x18;
    static const uint32_t kLSR = 0x14;
    static const uint32_t kUSR = 0x7C;
    static const uint8_t kUsrTfnf = 1u << 1;
    static const uint8_t kUsrRfne = 1u << 3;

    int mem_ = -1;
    volatile uint8_t *g_ = nullptr;
    int pin_fd_ = -1;
    bool termios_ok_ = false;
    bool use_tty_tx_ = false;
    static void nap() {
        timespec t{0, 50000L};
        ::nanosleep(&t, nullptr);
    }

    void open_tx_pad(const std::string &dev) {
        if (dev.empty())
            return;
        int fd = ::open(dev.c_str(), O_RDWR | O_NOCTTY | O_CLOEXEC);
        if (fd >= 0) {
            ::fcntl(fd, F_SETFL, O_NONBLOCK);
            pin_fd_ = fd;

            struct termios want;
            std::memset(&want, 0, sizeof want);
            if (::tcgetattr(fd, &want) == 0) {
                struct termios cur = want;
                ::cfmakeraw(&want);
                want.c_cflag = (want.c_cflag & ~CSIZE) | CS8 | CLOCAL | CREAD;
                want.c_cflag &= ~(PARENB | CSTOPB);
                want.c_cflag = (want.c_cflag & ~CBAUD) | (cur.c_cflag & CBAUD);
                termios_ok_ = (::tcsetattr(fd, TCSANOW, &want) == 0);
            } else
                termios_ok_ = false;
            if (!termios_ok_)
                std::fprintf(stderr, "[warn] uart0: tcsetattr 失败(%s)\n", std::strerror(errno));
        } else {
            pin_fd_ = -1;
            std::fprintf(stderr,
                         "[warn] uart0: open %s 失败(%s)，TX pad 可能仍是 GPIO ⇒ 只能收不能发\n",
                         dev.c_str(), std::strerror(errno));
        }
    }

    uint32_t rd32(uint32_t o) const { return *(volatile uint32_t *)(g_ + o); }
    void wr32(uint32_t o, uint32_t v) { *(volatile uint32_t *)(g_ + o) = v; }
    uint16_t read_divisor() {
        uint32_t lcr = rd32(kLCR);
        wr32(kLCR, (lcr | 0x80u) & 0xFFu);
        uint16_t d = uint16_t((rd32(kIER) & 0xFFu) << 8) | uint16_t(rd32(kRBR) & 0xFFu);
        wr32(kLCR, lcr & 0xFFu);
        return d;
    }
    void write_divisor(uint16_t d) {
        uint32_t lcr = rd32(kLCR);
        wr32(kLCR, (lcr | 0x80u) & 0xFFu);
        wr32(kRBR, d & 0xFFu);
        wr32(kIER, (d >> 8) & 0xFFu);
        wr32(kLCR, lcr & 0xFFu);
    }

  public:
    explicit MmapSerial(const std::string &pinmux_dev) {

        open_tx_pad(pinmux_dev);
        if (pin_fd_ >= 0)
            ::usleep(30000);

        mem_ = ::open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
        if (mem_ < 0)
            throw std::runtime_error("mmap uart: cannot open /dev/mem (need root)");
        void *m = ::mmap(nullptr, kPage, PROT_READ | PROT_WRITE, MAP_SHARED, mem_, (off_t)kBase);
        if (m == MAP_FAILED) {
            ::close(mem_);
            mem_ = -1;
            throw std::runtime_error("mmap uart: mmap 0x20810000 failed (IO_STRICT_DEVMEM?)");
        }
        g_ = (volatile uint8_t *)m;

        *(volatile uint32_t *)(g_ + kIER) = 0u;
        *(volatile uint32_t *)(g_ + kFCR) = 0xC7u;

        if (pin_fd_ >= 0) {
            *(volatile uint32_t *)(g_ + kIER) = 0u;
            *(volatile uint32_t *)(g_ + kFCR) = 0xC7u;
            ::tcflush(pin_fd_, TCIOFLUSH);
            const char *e = ::getenv("MMAP_UART_TTY_TX");
            use_tty_tx_ = (e && *e && *e != '0');
        }
        char div_note[96];
        std::snprintf(div_note, sizeof div_note, "  baud-divisor=%u (沿用硬件值，未改)",
                      read_divisor());

        const uint32_t mcr_before = rd32(kMCR) & 0xFFu;
        const uint32_t mcr_after = (mcr_before & ~0x20u) | 0x03u;
        wr32(kMCR, mcr_after);
        const uint32_t msr = rd32(kMSR) & 0xFFu;
        std::fprintf(stderr,
                     "[info] uart0 MCR 0x%02X -> 0x%02X (AFE %s->%s, DTR|RTS=1)  MSR=0x%02X CTS=%d "
                     " LSR=0x%02X\n",
                     mcr_before, mcr_after, (mcr_before & 0x20u) ? "ON" : "off",
                     (mcr_after & 0x20u) ? "ON" : "off", msr, (msr >> 4) & 1, rd32(kLSR) & 0xFFu);

        std::fprintf(stderr,
                     "[info] uart0 direct-register mode @0x20810000 (no tty data path, no IRQ)"
                     "  tx-pad=%s%s\n",
                     pin_fd_ >= 0 ? "configured" : "NOT CONFIGURED", div_note);
    }
    ~MmapSerial() override {

        if (g_) {
            *(volatile uint32_t *)(g_ + kIER) = 0u;
            ::munmap((void *)g_, kPage);
            g_ = nullptr;
        }
        if (mem_ >= 0) {
            ::close(mem_);
            mem_ = -1;
        }

        if (pin_fd_ >= 0) {
            ::close(pin_fd_);
            pin_fd_ = -1;
        }
    }
    int read_some(uint8_t *p, size_t n, int wait_ms) override {
        if (!g_)
            throw std::runtime_error("mmap uart: closed");
        if (n == 0)
            return 0;
        if (wait_ms > 0) {
            const uint64_t deadline = roi::monotonic_ms() + uint64_t(wait_ms);
            while (!(g_[kUSR] & kUsrRfne)) {
                if (roi::monotonic_ms() >= deadline)
                    return 0;
                nap();
            }
        } else if (!(g_[kUSR] & kUsrRfne))
            return 0;

        size_t got = 0;
        const size_t budget = n < 1024 ? n : 1024;
        while (got < budget && (g_[kUSR] & kUsrRfne))
            p[got++] = g_[kRBR];
        return int(got);
    }
    int write_some(const uint8_t *p, size_t n) override {
        if (!g_)
            throw std::runtime_error("mmap uart: closed");

        if (pin_fd_ >= 0 && use_tty_tx_) {

            wr32(kIER, 0x02u);
            ssize_t w = ::write(pin_fd_, p, n);
            return int(w > 0 ? w : 0);
        }
        size_t sent = 0;
        const uint64_t deadline = roi::monotonic_ms() + 1000;
        while (sent < n) {
            if (g_[kUSR] & kUsrTfnf) {
                g_[kRBR] = p[sent++];
                continue;
            }
            if (roi::monotonic_ms() >= deadline)
                break;
            nap();
        }
        return int(sent);
    }
};
std::unique_ptr<Transport> mmap_serial_transport(const std::string &pinmux_dev) {
    return std::unique_ptr<Transport>(new MmapSerial(pinmux_dev));
}
struct Temporary {
    std::string path;
    ~Temporary() {
        if (!path.empty())
            ::unlink(path.c_str());
    }
};
struct Child {
    pid_t pid = -1;
    ~Child() {
        if (pid > 0) {
            ::kill(pid, SIGKILL);
            while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {
            }
        }
    }
};
Result run_worker(const Crop &crop, const std::string &exe, const std::string &model,
                  const std::string &scratch, uint32_t timeout_ms) {
    const uint64_t start = monotonic_ms();
    Result result;
    Temporary image;
    std::string pattern = scratch + "/roi_XXXXXX.ppm";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back(0);
    {
        Fd out(mkstemps(name.data(), 4));
        if (out.fd < 0)
            throw std::runtime_error("scratch file creation failed");
        image.path = name.data();
        std::string data = ppm_bytes(crop);
        size_t at = 0;
        while (at < data.size()) {
            ssize_t n = ::write(out.fd, data.data() + at, data.size() - at);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                throw std::runtime_error("scratch image write failed");
            at += size_t(n);
        }
    }
    int ends[2];
    if (pipe(ends) < 0)
        throw std::runtime_error("worker pipe failed");
    Fd read_end(ends[0]), write_end(ends[1]);
    if (fcntl(read_end.fd, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(write_end.fd, F_SETFD, FD_CLOEXEC) < 0 || fcntl(read_end.fd, F_SETFL, O_NONBLOCK) < 0)
        throw std::runtime_error("worker pipe configuration failed");
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions) != 0)
        throw std::runtime_error("spawn actions failed");
    struct Actions {
        posix_spawn_file_actions_t *p;
        ~Actions() { posix_spawn_file_actions_destroy(p); }
    } cleanup{&actions};
    if (posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, write_end.fd, STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, write_end.fd, STDERR_FILENO) != 0 ||
        posix_spawn_file_actions_addclose(&actions, read_end.fd) != 0 ||
        posix_spawn_file_actions_addclose(&actions, write_end.fd) != 0)
        throw std::runtime_error("spawn redirect failed");
    char *argv[] = {const_cast<char *>(exe.c_str()), const_cast<char *>(model.c_str()),
                    const_cast<char *>(image.path.c_str()), nullptr};
    Child child;
    int rc = posix_spawn(&child.pid, exe.c_str(), &actions, nullptr, argv, environ);
    if (rc != 0) {
        child.pid = -1;
        throw std::runtime_error("worker executable spawn failed");
    }
    ::close(write_end.fd);
    write_end.fd = -1;
    std::string log;
    int status = 0;
    bool finished = false, eof = false;
    while (!finished || !eof) {
        if (monotonic_ms() - start >= timeout_ms) {
            result.status = InferenceTimeout;
            break;
        }
        pollfd f{read_end.fd, POLLIN, 0};
        int ready = poll(&f, 1, 20);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready < 0)
            throw std::runtime_error("worker output poll failed");
        char buffer[2048];
        for (;;) {
            ssize_t n = ::read(read_end.fd, buffer, sizeof(buffer));
            if (n > 0) {
                log.append(buffer, size_t(n));
                if (log.size() > 65536)
                    throw std::runtime_error("worker output exceeds 64 KiB");
            } else if (n == 0) {
                eof = true;
                break;
            } else if (errno == EINTR)
                continue;
            else if (errno == EAGAIN || errno == EWOULDBLOCK)
                break;
            else
                throw std::runtime_error("worker output read failed");
        }
        if (!finished) {
            pid_t reaped = waitpid(child.pid, &status, WNOHANG);
            if (reaped == child.pid) {
                finished = true;
                child.pid = -1;
            } else if (reaped < 0 && errno != EINTR)
                throw std::runtime_error("worker wait failed");
        }
        if (finished && eof) {
            result = worker_result(WIFEXITED(status) ? WEXITSTATUS(status) : -1, log);
            break;
        }
    }
    result.processing_ms = uint32_t(monotonic_ms() - start);
    std::cerr << "WORKER_LOG_BEGIN\n"
              << log << "WORKER_LOG_END status=" << unsigned(result.status)
              << " ms=" << result.processing_ms << '\n';
    return result;
}
} // namespace roi
#endif
