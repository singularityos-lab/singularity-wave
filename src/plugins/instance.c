#define _GNU_SOURCE
#include "waveplug.h"
#include "wp_internal.h"
#include "wp_proto.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef WAVE_PLUGIN_HOST_PATH
#define WAVE_PLUGIN_HOST_PATH "/usr/libexec/singularity-wave-plugin-host"
#endif

#define HOST_NAME "singularity-wave-plugin-host"
#define BLOCK_TIMEOUT_MS 2000
#define START_TIMEOUT_MS 15000

struct _WpInstance {
    int isolated;
    char *kind;
    char *path;
    int rate;
    int channels;
    int max_block;
    WpPlugin *plugin;
    pid_t pid;
    int sock;
    int memfd;
    float *shm;
    size_t shm_size;
    int alive;
    int n_params;
    double *values;
    int latency;
    int flags;
    char *crash;
    uint8_t *state;
    size_t state_len;
    int crashes;
    double last_crash;
    pthread_mutex_t lock;
};

static char helper_path[PATH_MAX];

static int executable(const char *p)
{
    return access(p, X_OK) == 0;
}

const char *wp_helper_path(void)
{
    if (helper_path[0]) return helper_path;
    const char *env = getenv("SINGULARITY_WAVE_PLUGIN_HOST");
    if (env && *env) {
        snprintf(helper_path, sizeof helper_path, "%s", env);
        return helper_path;
    }
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n > 0) {
        exe[n] = 0;
        char *slash = strrchr(exe, '/');
        if (slash) {
            *slash = 0;
            const char *rel[] = { HOST_NAME, "src/plugins/" HOST_NAME, "../src/plugins/" HOST_NAME, "../../src/plugins/" HOST_NAME, NULL };
            for (int i = 0; rel[i]; i++) {
                char cand[PATH_MAX];
                snprintf(cand, sizeof cand, "%s/%s", exe, rel[i]);
                if (executable(cand)) {
                    snprintf(helper_path, sizeof helper_path, "%s", cand);
                    return helper_path;
                }
            }
        }
    }
    snprintf(helper_path, sizeof helper_path, "%s", WAVE_PLUGIN_HOST_PATH);
    return helper_path;
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t) n;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len, int timeout_ms)
{
    char *p = buf;
    double deadline = now_s() + timeout_ms / 1000.0;
    while (len > 0) {
        int left = (int) ((deadline - now_s()) * 1000);
        if (left < 0) return -2;
        struct pollfd pfd = { fd, POLLIN, 0 };
        int r = poll(&pfd, 1, left);
        if (r < 0 && errno == EINTR) continue;
        if (r == 0) return -2;
        if (r < 0) return -1;
        ssize_t n = read(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t) n;
    }
    return 0;
}

static void set_error(char **error, const char *msg)
{
    if (error) *error = strdup(msg);
}

static void reap(WpInstance *i, int timed_out)
{
    if (i->pid <= 0) return;
    int status = 0;
    pid_t r = waitpid(i->pid, &status, WNOHANG);
    if (r == 0) {
        kill(i->pid, SIGKILL);
        waitpid(i->pid, &status, 0);
    }
    char msg[256];
    if (timed_out) snprintf(msg, sizeof msg, "The plugin stopped responding and was restarted");
    else if (WIFSIGNALED(status)) snprintf(msg, sizeof msg, "The plugin crashed (%s) and was restarted", strsignal(WTERMSIG(status)));
    else snprintf(msg, sizeof msg, "The plugin closed unexpectedly and was restarted");
    free(i->crash);
    i->crash = strdup(msg);
    i->pid = 0;
}

static void close_host(WpInstance *i)
{
    if (i->sock >= 0) close(i->sock);
    i->sock = -1;
    if (i->shm) munmap(i->shm, i->shm_size);
    i->shm = NULL;
    if (i->memfd >= 0) close(i->memfd);
    i->memfd = -1;
    i->alive = 0;
}

static void mark_dead(WpInstance *i, int timed_out)
{
    reap(i, timed_out);
    close_host(i);
    i->crashes++;
    i->last_crash = now_s();
}

static int transact(WpInstance *i, WpMsg *msg, const void *payload, WpReply *reply, void **reply_payload, int timeout_ms)
{
    if (!i->alive) return -1;
    if (write_all(i->sock, msg, sizeof *msg) < 0 || (payload && msg->len && write_all(i->sock, payload, msg->len) < 0)) {
        mark_dead(i, 0);
        return -1;
    }
    if (!reply) return 0;
    int r = read_all(i->sock, reply, sizeof *reply, timeout_ms);
    if (r < 0) {
        mark_dead(i, r == -2);
        return -1;
    }
    void *data = NULL;
    if (reply->len > 0) {
        if (reply->len > 256u * 1024 * 1024) {
            mark_dead(i, 0);
            return -1;
        }
        data = malloc(reply->len + 1);
        if (read_all(i->sock, data, reply->len, timeout_ms) < 0) {
            free(data);
            mark_dead(i, 0);
            return -1;
        }
        ((char *) data)[reply->len] = 0;
    }
    i->flags = reply->flags;
    if (reply_payload) *reply_payload = data;
    else free(data);
    return 0;
}

static int spawn_host(WpInstance *i, char **error)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sv) < 0) {
        set_error(error, strerror(errno));
        return -1;
    }
    i->shm_size = sizeof(float) * (size_t) i->channels * (size_t) i->max_block;
    i->memfd = memfd_create("wave-plugin-audio", MFD_CLOEXEC);
    if (i->memfd < 0 || ftruncate(i->memfd, (off_t) i->shm_size) < 0) {
        set_error(error, strerror(errno));
        close(sv[0]);
        close(sv[1]);
        if (i->memfd >= 0) close(i->memfd);
        i->memfd = -1;
        return -1;
    }
    i->shm = mmap(NULL, i->shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, i->memfd, 0);
    if (i->shm == MAP_FAILED) {
        i->shm = NULL;
        set_error(error, strerror(errno));
        close(sv[0]);
        close(sv[1]);
        close(i->memfd);
        i->memfd = -1;
        return -1;
    }
    const char *helper = wp_helper_path();
    char rate[32], channels[32], block[32];
    snprintf(rate, sizeof rate, "%d", i->rate);
    snprintf(channels, sizeof channels, "%d", i->channels);
    snprintf(block, sizeof block, "%d", i->max_block);
    char *argv[] = { (char *) helper, "--run", i->kind, i->path ? i->path : "", rate, channels, block, NULL };
    int child_sock = sv[1];
    int child_mem = i->memfd;
    pid_t pid = fork();
    if (pid < 0) {
        set_error(error, strerror(errno));
        close(sv[0]);
        close(sv[1]);
        close_host(i);
        return -1;
    }
    if (pid == 0) {
        int a = fcntl(child_sock, F_DUPFD, 10);
        int b = fcntl(child_mem, F_DUPFD, 10);
        if (a < 0 || b < 0) _exit(127);
        dup2(a, WP_SOCKET_FD);
        dup2(b, WP_SHM_FD);
        long maxfd = sysconf(_SC_OPEN_MAX);
        if (maxfd < 0 || maxfd > 65536) maxfd = 65536;
        for (int fd = WP_SHM_FD + 1; fd < maxfd; fd++) close(fd);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        execv(helper, argv);
        _exit(127);
    }
    close(sv[1]);
    i->sock = sv[0];
    i->pid = pid;
    i->alive = 1;
    WpReply reply;
    int r = read_all(i->sock, &reply, sizeof reply, START_TIMEOUT_MS);
    if (r < 0) {
        mark_dead(i, r == -2);
        i->crashes--;
        set_error(error, i->crash ? i->crash : "The plugin host did not start");
        free(i->crash);
        i->crash = NULL;
        return -1;
    }
    char *payload = NULL;
    if (reply.len > 0 && reply.len < 65536) {
        payload = calloc(1, reply.len + 1);
        read_all(i->sock, payload, reply.len, START_TIMEOUT_MS);
    }
    if (reply.status != 0) {
        set_error(error, payload ? payload : "The plugin could not be loaded");
        free(payload);
        WpMsg q = { WP_OP_QUIT, 0, 0, 0, 0, 0 };
        write_all(i->sock, &q, sizeof q);
        int status;
        waitpid(i->pid, &status, 0);
        i->pid = 0;
        close_host(i);
        return -1;
    }
    free(payload);
    i->n_params = reply.ivalue;
    i->latency = (int) reply.value;
    i->flags = reply.flags;
    return 0;
}

static void apply_cached(WpInstance *i)
{
    for (int p = 0; p < i->n_params; p++) {
        WpMsg m = { WP_OP_SET_PARAM, p, 0, 0, i->values[p], 0 };
        transact(i, &m, NULL, NULL, NULL, BLOCK_TIMEOUT_MS);
    }
    if (i->state && i->state_len) {
        WpMsg m = { WP_OP_LOAD_STATE, 0, 0, 0, 0, i->state_len };
        WpReply r;
        transact(i, &m, i->state, &r, NULL, BLOCK_TIMEOUT_MS);
        for (int p = 0; p < i->n_params; p++) {
            WpMsg s = { WP_OP_SET_PARAM, p, 0, 0, i->values[p], 0 };
            transact(i, &s, NULL, NULL, NULL, BLOCK_TIMEOUT_MS);
        }
    }
}

WpInstance *wp_instance_open(const char *kind, const char *path, int rate, int channels, int max_block, int isolated, char **error)
{
    if (error) *error = NULL;
    WpInstance *i = calloc(1, sizeof(WpInstance));
    pthread_mutex_init(&i->lock, NULL);
    i->isolated = isolated;
    i->kind = strdup(kind);
    i->path = strdup(path ? path : "");
    i->rate = rate;
    i->channels = channels > 0 ? channels : 1;
    i->max_block = max_block > 0 ? max_block : 1024;
    i->sock = -1;
    i->memfd = -1;
    if (isolated) {
        if (spawn_host(i, error) < 0) {
            wp_instance_free(i);
            return NULL;
        }
        i->values = calloc(i->n_params ? i->n_params : 1, sizeof(double));
        WpMsg m = { WP_OP_GET_PARAMS, 0, 0, 0, 0, 0 };
        WpReply r;
        void *data = NULL;
        if (transact(i, &m, NULL, &r, &data, BLOCK_TIMEOUT_MS) == 0 && data && r.len == sizeof(double) * (size_t) i->n_params) memcpy(i->values, data, r.len);
        free(data);
    } else {
        char err[512] = {0};
        i->plugin = wp_plugin_open(kind, path, rate, i->channels, i->max_block, err, sizeof err);
        if (!i->plugin) {
            set_error(error, err[0] ? err : "The plugin could not be loaded");
            wp_instance_free(i);
            return NULL;
        }
        i->alive = 1;
        i->n_params = wp_plugin_desc(i->plugin)->n_params;
        i->values = calloc(i->n_params ? i->n_params : 1, sizeof(double));
        for (int p = 0; p < i->n_params; p++) i->values[p] = wp_plugin_get_param(i->plugin, p);
        i->latency = wp_plugin_latency(i->plugin);
    }
    return i;
}

void wp_instance_free(WpInstance *i)
{
    if (!i) return;
    if (i->plugin) wp_plugin_free(i->plugin);
    if (i->isolated && i->alive) {
        WpMsg q = { WP_OP_QUIT, 0, 0, 0, 0, 0 };
        write_all(i->sock, &q, sizeof q);
        double deadline = now_s() + 1.0;
        int status;
        while (now_s() < deadline) {
            if (waitpid(i->pid, &status, WNOHANG) != 0) {
                i->pid = 0;
                break;
            }
            usleep(5000);
        }
        if (i->pid > 0) {
            kill(i->pid, SIGKILL);
            waitpid(i->pid, &status, 0);
        }
        close_host(i);
    } else if (i->pid > 0) {
        int status;
        kill(i->pid, SIGKILL);
        waitpid(i->pid, &status, 0);
    }
    pthread_mutex_destroy(&i->lock);
    free(i->kind);
    free(i->path);
    free(i->values);
    free(i->crash);
    free(i->state);
    free(i);
}

int wp_instance_restart(WpInstance *i, char **error)
{
    if (error) *error = NULL;
    if (!i->isolated) return i->plugin ? 0 : -1;
    pthread_mutex_lock(&i->lock);
    if (i->alive) {
        pthread_mutex_unlock(&i->lock);
        return 0;
    }
    int r = spawn_host(i, error);
    if (r == 0) apply_cached(i);
    pthread_mutex_unlock(&i->lock);
    return r;
}

int wp_instance_process(WpInstance *i, float *buf, int frames)
{
    if (frames <= 0) return 0;
    if (!i->isolated) {
        wp_plugin_run_interleaved(i->plugin, buf, frames);
        i->latency = wp_plugin_latency(i->plugin);
        return 0;
    }
    pthread_mutex_lock(&i->lock);
    if (!i->alive) {
        if (i->crashes >= 3 && now_s() - i->last_crash < 1.0) {
            pthread_mutex_unlock(&i->lock);
            return -1;
        }
        char *err = NULL;
        if (spawn_host(i, &err) < 0) {
            free(err);
            i->crashes++;
            i->last_crash = now_s();
            pthread_mutex_unlock(&i->lock);
            return -1;
        }
        apply_cached(i);
        if (!i->alive) {
            pthread_mutex_unlock(&i->lock);
            return -1;
        }
    }
    for (int off = 0; off < frames; off += i->max_block) {
        int n = frames - off < i->max_block ? frames - off : i->max_block;
        size_t bytes = sizeof(float) * (size_t) n * (size_t) i->channels;
        memcpy(i->shm, buf + (size_t) off * i->channels, bytes);
        WpMsg m = { WP_OP_PROCESS, 0, n, 0, 0, 0 };
        WpReply r;
        if (transact(i, &m, NULL, &r, NULL, BLOCK_TIMEOUT_MS) < 0) {
            pthread_mutex_unlock(&i->lock);
            return -1;
        }
        i->latency = r.ivalue;
        memcpy(buf + (size_t) off * i->channels, i->shm, bytes);
    }
    i->crashes = 0;
    pthread_mutex_unlock(&i->lock);
    return 0;
}

int wp_instance_param_count(WpInstance *i)
{
    return i->n_params;
}

void wp_instance_set_param(WpInstance *i, int index, double value)
{
    if (index < 0 || index >= i->n_params) return;
    pthread_mutex_lock(&i->lock);
    i->values[index] = value;
    if (!i->isolated) {
        wp_plugin_set_param(i->plugin, index, value);
    } else if (i->alive) {
        WpMsg m = { WP_OP_SET_PARAM, index, 0, 0, value, 0 };
        transact(i, &m, NULL, NULL, NULL, BLOCK_TIMEOUT_MS);
    }
    pthread_mutex_unlock(&i->lock);
}

double wp_instance_get_param(WpInstance *i, int index)
{
    if (index < 0 || index >= i->n_params) return 0;
    if (!i->isolated) return wp_plugin_get_param(i->plugin, index);
    return i->values[index];
}

int wp_instance_sync_params(WpInstance *i, double *values, int n)
{
    pthread_mutex_lock(&i->lock);
    if (!i->isolated) {
        for (int p = 0; p < i->n_params; p++) i->values[p] = wp_plugin_get_param(i->plugin, p);
    } else if (i->alive) {
        WpMsg m = { WP_OP_GET_PARAMS, 0, 0, 0, 0, 0 };
        WpReply r;
        void *data = NULL;
        if (transact(i, &m, NULL, &r, &data, BLOCK_TIMEOUT_MS) == 0 && data && r.len == sizeof(double) * (size_t) i->n_params) memcpy(i->values, data, r.len);
        free(data);
    }
    int c = n < i->n_params ? n : i->n_params;
    memcpy(values, i->values, sizeof(double) * (size_t) c);
    pthread_mutex_unlock(&i->lock);
    return c;
}

int wp_instance_latency(WpInstance *i)
{
    return i->latency;
}

int wp_instance_alive(WpInstance *i)
{
    return i->alive;
}

int wp_instance_is_isolated(WpInstance *i)
{
    return i->isolated;
}

char *wp_instance_take_crash(WpInstance *i)
{
    pthread_mutex_lock(&i->lock);
    char *c = i->crash;
    i->crash = NULL;
    pthread_mutex_unlock(&i->lock);
    return c;
}

int wp_instance_save_state(WpInstance *i, uint8_t **data, size_t *len)
{
    *data = NULL;
    *len = 0;
    if (!i->isolated) return wp_plugin_save_state(i->plugin, data, len);
    pthread_mutex_lock(&i->lock);
    WpMsg m = { WP_OP_SAVE_STATE, 0, 0, 0, 0, 0 };
    WpReply r;
    void *payload = NULL;
    int ok = transact(i, &m, NULL, &r, &payload, BLOCK_TIMEOUT_MS) == 0 && r.status == 0;
    pthread_mutex_unlock(&i->lock);
    if (!ok) {
        free(payload);
        return -1;
    }
    *data = payload;
    *len = r.len;
    return 0;
}

int wp_instance_load_state(WpInstance *i, const uint8_t *data, size_t len)
{
    if (!i->isolated) {
        int r = wp_plugin_load_state(i->plugin, data, len);
        if (r == 0) {
            for (int p = 0; p < i->n_params; p++) i->values[p] = wp_plugin_get_param(i->plugin, p);
        }
        return r;
    }
    pthread_mutex_lock(&i->lock);
    free(i->state);
    i->state = malloc(len ? len : 1);
    memcpy(i->state, data, len);
    i->state_len = len;
    WpMsg m = { WP_OP_LOAD_STATE, 0, 0, 0, 0, len };
    WpReply r;
    int ok = transact(i, &m, data, &r, NULL, BLOCK_TIMEOUT_MS) == 0 && r.status == 0;
    if (ok) {
        WpMsg g = { WP_OP_GET_PARAMS, 0, 0, 0, 0, 0 };
        void *vals = NULL;
        if (transact(i, &g, NULL, &r, &vals, BLOCK_TIMEOUT_MS) == 0 && vals && r.len == sizeof(double) * (size_t) i->n_params) memcpy(i->values, vals, r.len);
        free(vals);
    }
    pthread_mutex_unlock(&i->lock);
    return ok ? 0 : -1;
}

int wp_instance_has_native_ui(WpInstance *i)
{
    if (!i->isolated) return wp_plugin_has_ui(i->plugin);
    return (i->flags & WP_FLAG_HAS_UI) != 0;
}

int wp_instance_show_native_ui(WpInstance *i, int show, char **error)
{
    if (error) *error = NULL;
    if (!i->isolated) {
        char err[512] = {0};
        int r = wp_plugin_show_ui(i->plugin, show, err, sizeof err);
        if (r < 0) set_error(error, err);
        return r;
    }
    pthread_mutex_lock(&i->lock);
    WpMsg m = { WP_OP_SHOW_UI, show, 0, 0, 0, 0 };
    WpReply r;
    void *payload = NULL;
    int t = transact(i, &m, NULL, &r, &payload, BLOCK_TIMEOUT_MS);
    pthread_mutex_unlock(&i->lock);
    int status = t == 0 ? r.status : -1;
    if (status != 0) set_error(error, payload ? payload : "The plugin window could not be shown");
    free(payload);
    return status;
}

int wp_instance_native_ui_visible(WpInstance *i)
{
    if (!i->isolated) return wp_plugin_ui_visible(i->plugin);
    return (i->flags & WP_FLAG_UI_VISIBLE) != 0;
}

void wp_instance_idle(WpInstance *i)
{
    if (!i->isolated && i->plugin) wp_plugin_ui_idle(i->plugin);
}

int wp_instance_pid(WpInstance *i)
{
    return (int) i->pid;
}

char *wp_candidates(void)
{
    return wp_candidates_json();
}

char *wp_scan_isolated(const char *format, const char *path, int timeout_ms, char **error)
{
    if (error) *error = NULL;
    int pipefd[2];
    if (pipe2(pipefd, O_CLOEXEC) < 0) {
        set_error(error, strerror(errno));
        return NULL;
    }
    const char *helper = wp_helper_path();
    char *argv[] = { (char *) helper, "--scan", (char *) format, (char *) path, NULL };
    int wfd = pipefd[1];
    pid_t pid = fork();
    if (pid < 0) {
        set_error(error, strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        return NULL;
    }
    if (pid == 0) {
        dup2(wfd, 1);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        execv(helper, argv);
        _exit(127);
    }
    close(pipefd[1]);
    WpStr out = {0};
    double deadline = now_s() + timeout_ms / 1000.0;
    int timed_out = 0;
    char buf[8192];
    for (;;) {
        int left = (int) ((deadline - now_s()) * 1000);
        if (left <= 0) {
            timed_out = 1;
            break;
        }
        struct pollfd pfd = { pipefd[0], POLLIN, 0 };
        int r = poll(&pfd, 1, left);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            timed_out = r == 0;
            break;
        }
        ssize_t n = read(pipefd[0], buf, sizeof buf - 1);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        buf[n] = 0;
        wp_str_add(&out, buf);
    }
    close(pipefd[0]);
    int status = 0;
    if (timed_out) kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    if (timed_out || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        char msg[512];
        if (timed_out) snprintf(msg, sizeof msg, "Scanning %s took too long", path);
        else if (WIFSIGNALED(status)) snprintf(msg, sizeof msg, "Scanning %s crashed (%s)", path, strsignal(WTERMSIG(status)));
        else snprintf(msg, sizeof msg, "Scanning %s failed", path);
        set_error(error, msg);
        free(out.data);
        return NULL;
    }
    if (!out.data) return strdup("[]");
    return out.data;
}
