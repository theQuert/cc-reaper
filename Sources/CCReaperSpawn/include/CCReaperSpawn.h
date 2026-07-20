#ifndef CC_REAPER_SPAWN_H
#define CC_REAPER_SPAWN_H

#include <sys/types.h>

int ccr_spawn_process(
    const char *path,
    char *const argv[],
    char *const envp[],
    int stdout_fd,
    int stderr_fd,
    pid_t *pid_out
);

// Returns 1 after reaping an exited process, 0 while it is running, and a
// negative errno value on failure.
int ccr_poll_process(pid_t pid, int *exit_code_out);

// Signals every process in the process group created by ccr_spawn_process.
// Returns 0 on success or when the group is already gone, otherwise errno.
int ccr_signal_process_group(pid_t group_id, int signal_number);

// Returns 1 while the process group exists, 0 when it is gone, and -1 on an
// unexpected error.
int ccr_process_group_exists(pid_t group_id);

#endif
