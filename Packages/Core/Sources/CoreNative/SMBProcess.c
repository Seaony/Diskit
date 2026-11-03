#include "CoreNative.h"
#include <errno.h>
#include <fcntl.h>
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

// 密码只写入子进程的终端，不放进参数或环境。
int kayoi_smb_shares(const char *server, const char *password, char *output, size_t capacity, int *exit_status) {
    int master, slave;
    if (openpty(&master, &slave, NULL, NULL, NULL) < 0) return errno;
    struct termios settings;
    if (tcgetattr(slave, &settings) < 0) { int e = errno; close(master); close(slave); return e; }
    settings.c_lflag &= ~(ECHO | ECHONL);
    if (tcsetattr(slave, TCSANOW, &settings) < 0) { int e = errno; close(master); close(slave); return e; }
    char *args[] = {"/usr/bin/smbutil", "view", "-f", (char *)server, NULL};
    char *env[] = {"LC_ALL=C", "PATH=/usr/bin:/bin", NULL};
    pid_t child = fork();
    if (child == 0) {
        close(master);
        if (setsid() < 0 || ioctl(slave, TIOCSCTTY, 0) < 0) _exit(126);
        if (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0) _exit(126);
        if (slave > 2) close(slave);
        execve(args[0], args, env);
        _exit(127);
    }
    close(slave);
    if (child < 0) { int e = errno; close(master); return e; }
    int result = 0, status = 0, sent = 0, eof = 0;
    size_t used = 0;
    output[0] = 0;
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    while (1) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (now.tv_sec - start.tv_sec >= 15) { result = ETIMEDOUT; break; }
        struct pollfd fd = {eof ? -1 : master, POLLIN, 0};
        int ready = poll(&fd, 1, 100);
        if (ready < 0 && errno != EINTR) { result = errno; break; }
        if (ready > 0 && (fd.revents & (POLLIN | POLLHUP))) {
            if (used + 1 >= capacity) { result = ENOBUFS; break; }
            ssize_t n = read(master, output + used, capacity - used - 1);
            if (n <= 0) {
                if (n < 0 && errno != EIO && errno != EINTR) result = errno;
                if (n < 0 && errno == EINTR) continue;
                if (result) break;
                eof = 1;
                continue;
            }
            used += n; output[used] = 0;
            if (!sent && strstr(output, "Password") && strchr(strstr(output, "Password"), ':')) {
                size_t length = strlen(password), written = 0;
                while (written < length) {
                    ssize_t nwrite = write(master, password + written, length - written);
                    if (nwrite < 0 && errno == EINTR) continue;
                    if (nwrite <= 0) { result = EIO; break; }
                    written += nwrite;
                }
                if (result || write(master, "\n", 1) != 1) { result = EIO; break; }
                sent = 1;
            }
        }
        pid_t done = waitpid(child, &status, WNOHANG);
        if (done == child) { child = -1; break; }
    }
    close(master);
    if (child > 0) {
        // 超时后必须结束子进程，避免后台留下密码提示。
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    *exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    return result;
}
