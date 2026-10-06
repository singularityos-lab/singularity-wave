#define _GNU_SOURCE
#include "wp_internal.h"
#include "wp_proto.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

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

static int read_all(int fd, void *buf, size_t len)
{
    char *p = buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        p += n;
        len -= (size_t) n;
    }
    return 0;
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static int flags_of(WpPlugin *p)
{
    return (wp_plugin_has_ui(p) ? WP_FLAG_HAS_UI : 0) | (wp_plugin_ui_visible(p) ? WP_FLAG_UI_VISIBLE : 0);
}

static int reply(int fd, WpPlugin *p, int status, int ivalue, double value, const void *payload, size_t len)
{
    WpReply r;
    memset(&r, 0, sizeof r);
    r.status = status;
    r.ivalue = ivalue;
    r.value = value;
    r.len = len;
    r.flags = p ? flags_of(p) : 0;
    if (write_all(fd, &r, sizeof r) < 0) return -1;
    if (payload && len) return write_all(fd, payload, len);
    return 0;
}

static int run_host(const char *kind, const char *path, int rate, int channels, int max_block)
{
    int fd = WP_SOCKET_FD;
    size_t shm_size = sizeof(float) * (size_t) channels * (size_t) max_block;
    float *shm = mmap(NULL, shm_size, PROT_READ | PROT_WRITE, MAP_SHARED, WP_SHM_FD, 0);
    if (shm == MAP_FAILED) {
        const char *msg = "The plugin host could not map the audio buffer";
        reply(fd, NULL, -1, 0, 0, msg, strlen(msg));
        return 1;
    }
    char err[512] = {0};
    WpPlugin *p = wp_plugin_open(kind, path, rate, channels, max_block, err, sizeof err);
    if (!p) {
        if (!err[0]) snprintf(err, sizeof err, "The plugin could not be loaded");
        reply(fd, NULL, -1, 0, 0, err, strlen(err));
        return 1;
    }
    int n = wp_plugin_desc(p)->n_params;
    if (reply(fd, p, 0, n, wp_plugin_latency(p), NULL, 0) < 0) return 1;
    double *values = calloc(n ? n : 1, sizeof(double));
    double last_idle = now_ms();
    for (;;) {
        int visible = wp_plugin_ui_visible(p);
        struct pollfd pfd = { fd, POLLIN, 0 };
        int r = poll(&pfd, 1, visible ? 30 : -1);
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) break;
        if (visible && now_ms() - last_idle >= 30) {
            wp_plugin_ui_idle(p);
            last_idle = now_ms();
        }
        if (r == 0) continue;
        WpMsg m;
        if (read_all(fd, &m, sizeof m) < 0) break;
        int quit = 0;
        switch (m.op) {
        case WP_OP_PROCESS: {
            int frames = m.frames < 0 ? 0 : (m.frames > max_block ? max_block : m.frames);
            wp_plugin_run_interleaved(p, shm, frames);
            if (reply(fd, p, 0, wp_plugin_latency(p), 0, NULL, 0) < 0) quit = 1;
            break;
        }
        case WP_OP_SET_PARAM:
            wp_plugin_set_param(p, m.index, m.value);
            break;
        case WP_OP_GET_PARAMS:
            for (int i = 0; i < n; i++) values[i] = wp_plugin_get_param(p, i);
            if (reply(fd, p, 0, n, 0, values, sizeof(double) * (size_t) n) < 0) quit = 1;
            break;
        case WP_OP_SAVE_STATE: {
            uint8_t *data = NULL;
            size_t len = 0;
            int s = wp_plugin_save_state(p, &data, &len);
            if (reply(fd, p, s, 0, 0, data, s == 0 ? len : 0) < 0) quit = 1;
            free(data);
            break;
        }
        case WP_OP_LOAD_STATE: {
            if (m.len > 256u * 1024 * 1024) {
                quit = 1;
                break;
            }
            uint8_t *data = malloc(m.len ? m.len : 1);
            if (read_all(fd, data, m.len) < 0) {
                free(data);
                quit = 1;
                break;
            }
            int s = wp_plugin_load_state(p, data, m.len);
            free(data);
            if (reply(fd, p, s, 0, 0, NULL, 0) < 0) quit = 1;
            break;
        }
        case WP_OP_SHOW_UI: {
            char uerr[512] = {0};
            int s = wp_plugin_show_ui(p, m.index, uerr, sizeof uerr);
            if (s == 0 && m.index) {
                wp_plugin_ui_idle(p);
                last_idle = now_ms();
            }
            if (reply(fd, p, s, 0, 0, s == 0 ? NULL : uerr, s == 0 ? 0 : strlen(uerr)) < 0) quit = 1;
            break;
        }
        case WP_OP_QUIT:
        default:
            quit = 1;
            break;
        }
        if (quit) break;
    }
    free(values);
    wp_plugin_free(p);
    return 0;
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN);
    struct rlimit core = { 0, 0 };
    setrlimit(RLIMIT_CORE, &core);
    if (argc >= 4 && strcmp(argv[1], "--scan") == 0) {
        char *json = wp_scan_json(argv[2], argv[3]);
        fputs(json ? json : "[]", stdout);
        fflush(stdout);
        free(json);
        return 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--candidates") == 0) {
        char *json = wp_candidates_json();
        fputs(json, stdout);
        free(json);
        return 0;
    }
    if (argc >= 7 && strcmp(argv[1], "--run") == 0) {
        int rate = atoi(argv[4]);
        int channels = atoi(argv[5]);
        int block = atoi(argv[6]);
        if (rate <= 0 || channels <= 0 || block <= 0) return 2;
        return run_host(argv[2], argv[3], rate, channels, block);
    }
    fprintf(stderr, "usage: %s --scan FORMAT PATH | --candidates | --run KIND PATH RATE CHANNELS BLOCK\n", argv[0]);
    return 2;
}
