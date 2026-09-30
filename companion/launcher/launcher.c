// Gravity Lens.app's executable: runs gravity_lens.py with the system Python
// as a child process. macOS then files folder permissions under
// "Gravity Lens" instead of under Python, so they can be granted by name.
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, real) == NULL) {
        fprintf(stderr, "gravity-lens: cannot find my own path\n");
        return 1;
    }
    // …/Gravity Lens.app/Contents/MacOS/GravityLens → the folder holding the app.
    for (int i = 0; i < 4; i++) {
        char *slash = strrchr(real, '/');
        if (slash == NULL) return 1;
        *slash = '\0';
    }
    char script[PATH_MAX];
    snprintf(script, sizeof script, "%s/gravity_lens.py", real);

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    args[0] = "/usr/bin/python3";
    args[1] = script;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);
    int error = posix_spawn(&child, args[0], NULL, NULL, args, environ);
    if (error != 0) {
        fprintf(stderr, "gravity-lens: cannot start python3: %s\n", strerror(error));
        return 1;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
