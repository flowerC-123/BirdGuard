#ifndef _WIN32
#include "platform.hpp"
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/wait.h>
#include <signal.h>
#include <spawn.h>
#include <cerrno>
#include <sstream>
#include <stdexcept>
#include <iostream>
#include <algorithm>
#include <thread>
#include <chrono>
extern char **environ;
namespace roi {
struct PersistentWorker::Impl {
    std::string exe, model, scratch, buffer;
    pid_t pid = -1;
    int input = -1, output = -1;
    uint64_t sequence = 0;
    Impl(std::string e, std::string m, std::string s)
        : exe(std::move(e)), model(std::move(m)), scratch(std::move(s)) {}
    ~Impl() { reset(); }
    void reset() {
        if (input >= 0) {
            ::close(input);
            input = -1;
        }
        if (output >= 0) {
            ::close(output);
            output = -1;
        }
        if (pid > 0) {
            ::kill(pid, SIGKILL);
            const uint64_t deadline = monotonic_ms() + 250;
            while (monotonic_ms() < deadline) {
                pid_t rc = waitpid(pid, nullptr, WNOHANG);
                if (rc == pid || (rc < 0 && errno == ECHILD)) {
                    pid = -1;
                    break;
                }
                if (rc < 0 && errno != EINTR)
                    break;
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
            if (pid > 0)
                std::cerr << "RESIDENT_QUARANTINED unreaped_pid=" << pid
                          << " after_SIGKILL_ms=250\n";
        }
        buffer.clear();
    }
    bool line(std::string &value, uint64_t deadline) {
        while (monotonic_ms() < deadline) {
            auto at = buffer.find('\n');
            if (at != std::string::npos) {
                value = buffer.substr(0, at);
                buffer.erase(0, at + 1);
                return true;
            }
            pollfd p{output, POLLIN, 0};
            int r = poll(&p, 1, 5);
            if (r < 0 && errno == EINTR)
                continue;
            if (r < 0)
                throw std::runtime_error("resident worker poll failed");
            if (!r)
                continue;
            char data[4096];
            ssize_t n = ::read(output, data, sizeof(data));
            if (n == 0)
                throw std::runtime_error("resident worker exited");
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
                continue;
            if (n < 0)
                throw std::runtime_error("resident worker read failed");
            buffer.append(data, size_t(n));
            if (buffer.size() > 65536)
                throw std::runtime_error("resident worker line too long");
        }
        return false;
    }
    void start(uint64_t deadline) {
        if (pid > 0) {
            if (input < 0 || output < 0)
                throw std::runtime_error(
                    "previous resident worker is still unreaped; refusing process accumulation");
            return;
        }
        int to[2] = {-1, -1}, from[2] = {-1, -1};
        if (pipe(to) < 0)
            throw std::runtime_error("resident worker input pipe failed");
        if (pipe(from) < 0) {
            ::close(to[0]);
            ::close(to[1]);
            throw std::runtime_error("resident worker output pipe failed");
        }
        auto close_all = [&] {
            for (int f : to)
                if (f >= 0)
                    ::close(f);
            for (int f : from)
                if (f >= 0)
                    ::close(f);
        };
        for (int f : {to[0], to[1], from[0], from[1]})
            if (fcntl(f, F_SETFD, FD_CLOEXEC) < 0) {
                close_all();
                throw std::runtime_error("resident CLOEXEC failed");
            }
        if (fcntl(to[1], F_SETFL, O_NONBLOCK) < 0 || fcntl(from[0], F_SETFL, O_NONBLOCK) < 0) {
            close_all();
            throw std::runtime_error("resident nonblocking pipes failed");
        }
        posix_spawn_file_actions_t a;
        if (posix_spawn_file_actions_init(&a) != 0) {
            close_all();
            throw std::runtime_error("resident spawn actions failed");
        }
        int rc = posix_spawn_file_actions_adddup2(&a, to[0], STDIN_FILENO);
        rc |= posix_spawn_file_actions_adddup2(&a, from[1], STDOUT_FILENO);
        rc |= posix_spawn_file_actions_adddup2(&a, from[1], STDERR_FILENO);
        for (int f : {to[0], to[1], from[0], from[1]})
            rc |= posix_spawn_file_actions_addclose(&a, f);
        char *argv[] = {const_cast<char *>(exe.c_str()), const_cast<char *>(model.c_str()),
                        const_cast<char *>("--stream"), nullptr};
        if (!rc)
            rc = posix_spawn(&pid, exe.c_str(), &a, nullptr, argv, environ);
        posix_spawn_file_actions_destroy(&a);
        if (rc) {
            pid = -1;
            close_all();
            throw std::runtime_error("resident spawn failed");
        }
        ::close(to[0]);
        ::close(from[1]);
        input = to[1];
        output = from[0];
        std::string s;
        size_t total = 0;
        while (line(s, deadline)) {
            if (s == "BIRD_READY 1") {
                std::cerr << "WORKER_READY resident=1\n";
                return;
            }
            total += s.size() + 1;
            if (total > 65536)
                throw std::runtime_error("resident init output exceeds 64 KiB");
        }
        throw std::runtime_error("resident initialization deadline");
    }
    bool send(const std::string &command, uint64_t deadline) {
        size_t at = 0;
        while (at < command.size() && monotonic_ms() < deadline) {
            ssize_t n = ::write(input, command.data() + at, command.size() - at);
            if (n > 0) {
                at += size_t(n);
                continue;
            }
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
                pollfd p{input, POLLOUT, 0};
                poll(&p, 1, 5);
                continue;
            }
            throw std::runtime_error("resident command write failed");
        }
        return at == command.size();
    }
};
PersistentWorker::PersistentWorker(const std::string &e, const std::string &m, const std::string &s)
    : impl_(new Impl(e, m, s)) {}
PersistentWorker::~PersistentWorker() = default;
void PersistentWorker::warm(uint32_t ms) {
    try {
        impl_->start(monotonic_ms() + ms);
    } catch (...) {
        impl_->reset();
        throw;
    }
}
Result PersistentWorker::run(const Crop &c, uint32_t timeout_ms) {
    const uint64_t start = monotonic_ms(), deadline = start + timeout_ms;
    Result result;
    std::string path;
    struct Cleanup {
        std::string &path;
        ~Cleanup() {
            if (!path.empty())
                ::unlink(path.c_str());
        }
    } cleanup{path};
    try {
        impl_->start(deadline);
        std::string pattern = impl_->scratch + "/resident_XXXXXX.ppm";
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back(0);
        int f = mkstemps(name.data(), 4);
        if (f < 0)
            throw std::runtime_error("resident scratch creation failed");
        path = name.data();
        const auto data = ppm_bytes(c);
        size_t at = 0;
        while (at < data.size()) {
            ssize_t n = ::write(f, data.data() + at, data.size() - at);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0) {
                ::close(f);
                throw std::runtime_error("resident image write failed");
            }
            at += size_t(n);
        }
        ::close(f);
        const uint64_t seq = ++impl_->sequence;
        std::ostringstream command;
        command << "BIRD_RUN " << seq << ' ' << path.size() << '\n' << path << '\n';
        if (!impl_->send(command.str(), deadline)) {
            result.status = InferenceTimeout;
            impl_->reset();
        } else {
            std::string line, log;
            bool complete = false;
            while (impl_->line(line, deadline)) {
                if (line.compare(0, 10, "BIRD_DONE ") == 0) {
                    std::istringstream fields(line);
                    std::string marker, tail;
                    uint64_t got = 0;
                    int code = -1;
                    if (!(fields >> marker >> got >> code) || got != seq || (fields >> tail))
                        throw std::runtime_error("resident completion identity mismatch");
                    result = worker_result(code, log);
                    complete = true;
                    break;
                }
                log += line + '\n';
                if (log.size() > 65536)
                    throw std::runtime_error("resident output exceeds 64 KiB");
            }
            if (!complete) {
                result.status = InferenceTimeout;
                impl_->reset();
            }
        }
    } catch (const std::exception &e) {
        result = Result{};
        if (monotonic_ms() >= deadline)
            result.status = InferenceTimeout;
        std::cerr << "RESIDENT_ERROR " << e.what() << '\n';
        impl_->reset();
    }
    result.processing_ms = uint32_t(monotonic_ms() - start);
    return result;
}
} // namespace roi
#endif
