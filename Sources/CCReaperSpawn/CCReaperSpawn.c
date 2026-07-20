#include "CCReaperSpawn.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

int ccr_spawn_process(
    const char *path,
    char *const argv[],
    char *const envp[],
    int stdout_fd,
    int stderr_fd,
    pid_t *pid_out
) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        return result;
    }

    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return result;
    }

    result = posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO);
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO);
    }
    if (result == 0 && stdout_fd != STDOUT_FILENO && stdout_fd != STDERR_FILENO) {
        result = posix_spawn_file_actions_addclose(&actions, stdout_fd);
    }
    if (result == 0 && stderr_fd != STDOUT_FILENO && stderr_fd != STDERR_FILENO && stderr_fd != stdout_fd) {
        result = posix_spawn_file_actions_addclose(&actions, stderr_fd);
    }
    if (result == 0) {
        result = posix_spawnattr_setpgroup(&attributes, 0);
    }
    if (result == 0) {
        result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
    }
    if (result == 0) {
        result = posix_spawn(pid_out, path, &actions, &attributes, argv, envp);
    }

    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    return result;
}

int ccr_poll_process(pid_t pid, int *exit_code_out) {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) {
        return 0;
    }
    if (result < 0) {
        return -errno;
    }

    if (WIFEXITED(status)) {
        *exit_code_out = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        *exit_code_out = 128 + WTERMSIG(status);
    } else {
        *exit_code_out = status;
    }
    return 1;
}

int ccr_signal_process_group(pid_t group_id, int signal_number) {
    if (kill(-group_id, signal_number) == 0 || errno == ESRCH) {
        return 0;
    }
    return errno;
}

int ccr_process_group_exists(pid_t group_id) {
    if (kill(-group_id, 0) == 0 || errno == EPERM) {
        return 1;
    }
    if (errno == ESRCH) {
        return 0;
    }
    return -1;
}
