#include "CoreNative.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

static double monotonic_seconds(void *context) {
    (void)context;
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static int system_poll(void *context, struct pollfd *fds, nfds_t count, int milliseconds) {
    (void)context;
    return poll(fds, count, milliseconds);
}

static ssize_t system_write(void *context, int descriptor, const void *bytes, size_t count) {
    (void)context;
    return write(descriptor, bytes, count);
}

int diskit_smb_process(const char *executable, const char *const *arguments,
                      const char *password, char *output, size_t capacity,
                      int *exit_status, double timeout) {
    const diskit_smb_process_io io = {NULL, monotonic_seconds, system_poll, system_write};
    return diskit_smb_process_with_io(executable, arguments, password, output, capacity,
                                     exit_status, timeout, &io);
}

// 同一个期限覆盖终端读写和进程退出；退出后继续读完终端尾部。
int diskit_smb_process_with_io(const char *executable, const char *const *arguments,
                      const char *password, char *output, size_t capacity,
                      int *exit_status, double timeout, const diskit_smb_process_io *io) {
    if (!executable || !arguments || !password || !output || !exit_status ||
        !io || !io->now || !io->poll || !io->write || capacity == 0 || !isfinite(timeout) || timeout <= 0) return EINVAL;
    output[0] = 0;
    *exit_status = 128;
    double deadline = io->now(io->context) + timeout;
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0) return errno;
    struct termios settings;
    if (tcgetattr(slave, &settings) < 0) { int e = errno; close(master); close(slave); return e; }
    settings.c_lflag &= ~(ECHO | ECHONL);
    if (tcsetattr(slave, TCSANOW, &settings) < 0) { int e = errno; close(master); close(slave); return e; }
    int flags = fcntl(master, F_GETFL);
    if (flags < 0 || fcntl(master, F_SETFL, flags | O_NONBLOCK) < 0) {
        int e = errno; close(master); close(slave); return e;
    }
    char *env[] = {"LC_ALL=C", "PATH=/usr/bin:/bin", NULL};
    pid_t child = fork();
    int fork_error = errno;
    if (child == 0) {
        close(master);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) _exit(126);
        if (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) _exit(126);
        if (slave > 2) close(slave);
        execve(executable, (char *const *)arguments, env);
        _exit(127);
    }
    close(slave);
    if (child < 0) { close(master); return fork_error; }
    int result = 0, status = 0, prompt = 0, eof = 0, exited = 0;
    size_t used = 0, written = 0, password_length = strlen(password);
    while (!exited || !eof) {
        double remaining = deadline - io->now(io->context);
        if (remaining <= 0) { result = ETIMEDOUT; break; }
        int writing = prompt && written <= password_length && !exited;
        struct pollfd fd = {eof ? -1 : master, POLLIN | (writing ? POLLOUT : 0), 0};
        int milliseconds = remaining >= 0.1 ? 100 : (int)ceil(remaining * 1000);
        int ready = io->poll(io->context, &fd, 1, milliseconds);
        if (ready < 0) {
            if (errno == EINTR) continue;
            result = errno; break;
        }
        if (ready > 0 && (fd.revents & POLLNVAL)) { result = EBADF; break; }
        if (ready > 0 && (fd.revents & (POLLIN | POLLHUP | POLLERR))) {
            char bytes[8192];
            ssize_t count = read(master, bytes, sizeof(bytes));
            if (count > 0) {
                if ((size_t)count > capacity - used - 1) { result = ENOBUFS; break; }
                memcpy(output + used, bytes, (size_t)count);
                used += (size_t)count;
                output[used] = 0;
                const char *password_prompt = strstr(output, "Password");
                if (!prompt && password_prompt && strchr(password_prompt, ':')) prompt = 1;
            } else if (count == 0 || errno == EIO) {
                eof = 1;
            } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                result = errno; break;
            }
        }
        if (ready > 0 && (fd.revents & POLLOUT) && writing && !eof) {
            const char *bytes = written < password_length ? password + written : "\n";
            size_t count = written < password_length ? password_length - written : 1;
            ssize_t sent = io->write(io->context, master, bytes, count);
            if (sent > 0) written += (size_t)sent;
            else if (sent == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
                result = sent == 0 ? EIO : errno; break;
            }
        }
        if (!exited) {
            pid_t done = waitpid(child, &status, WNOHANG);
            if (done == child) exited = 1;
            else if (done < 0 && errno != EINTR) { result = errno; break; }
        }
    }
    close(master);
    if (!exited) {
        // 只结束本次创建的进程及其终端会话，避免留下密码提示。
        kill(-child, SIGKILL);
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    return result;
}

// 密码只写入子进程的终端，不放进参数或环境。
int diskit_smb_shares(const char *server, const char *password, char *output,
                     size_t capacity, int *exit_status, double timeout) {
    const char *args[] = {"/usr/bin/smbutil", "view", "-f", server, NULL};
    return diskit_smb_process(args[0], args, password, output, capacity, exit_status, timeout);
}
