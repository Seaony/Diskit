#include <poll.h>
#include <sys/types.h>
#include <stddef.h>
int kayoi_smb_shares(const char *server, const char *password, char *output,
                     size_t capacity, int *exit_status, double timeout);
int kayoi_smb_process(const char *executable, const char *const *arguments,
                      const char *password, char *output, size_t capacity,
                      int *exit_status, double timeout);

typedef struct {
    void *context;
    double (*now)(void *context);
    int (*poll)(void *context, struct pollfd *fds, nfds_t count, int milliseconds);
    ssize_t (*write)(void *context, int descriptor, const void *bytes, size_t count);
} kayoi_smb_process_io;
int kayoi_smb_process_with_io(const char *executable, const char *const *arguments,
                              const char *password, char *output, size_t capacity,
                              int *exit_status, double timeout, const kayoi_smb_process_io *io);
