#define _GNU_SOURCE
#include "wp_internal.h"

#include <dirent.h>
#include <glob.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

struct WpPlugin {
    WpDesc *desc;
    const WpBackend *be;
    WpUnit **units;
    int n_units;
    int channels;
    int rate;
    int max_block;
    float **inb;
    float **outb;
    pthread_mutex_t lock;
};

static const WpBackend *backend_for(int format)
{
    switch (format) {
    case WP_FORMAT_LV2: return &wp_lv2_backend;
    case WP_FORMAT_LADSPA: return &wp_ladspa_backend;
    default: return &wp_clap_backend;
    }
}

WpDesc **wp_describe(int format, const char *path, int *count)
{
    switch (format) {
    case WP_FORMAT_LV2: return wp_lv2_describe(path, count);
    case WP_FORMAT_LADSPA: return wp_ladspa_describe(path, count);
    default: return wp_clap_describe(path, count);
    }
}

static int format_of(const char *kind, const char **rest)
{
    if (strncmp(kind, "lv2:", 4) == 0) {
        *rest = kind + 4;
        return WP_FORMAT_LV2;
    }
    if (strncmp(kind, "ladspa:", 7) == 0) {
        *rest = kind + 7;
        return WP_FORMAT_LADSPA;
    }
    if (strncmp(kind, "clap:", 5) == 0) {
        *rest = kind + 5;
        return WP_FORMAT_CLAP;
    }
    return -1;
}

WpDesc *wp_find_desc(const char *kind, const char *path, char *err, size_t errlen)
{
    const char *rest;
    int format = format_of(kind, &rest);
    if (format < 0) {
        snprintf(err, errlen, "Unknown plugin kind %s", kind);
        return NULL;
    }
    char *file = NULL;
    if (format == WP_FORMAT_LV2) {
        if (!path || !*path) {
            snprintf(err, errlen, "The LV2 bundle of %s is unknown", rest);
            return NULL;
        }
        file = strdup(path);
    } else {
        const char *hash = strrchr(rest, '#');
        if (!hash) {
            snprintf(err, errlen, "Malformed plugin kind %s", kind);
            return NULL;
        }
        file = strndup(rest, hash - rest);
    }
    int count = 0;
    WpDesc **list = wp_describe(format, file, &count);
    free(file);
    WpDesc *found = NULL;
    for (int i = 0; i < count; i++) {
        if (!found && strcmp(list[i]->kind, kind) == 0) {
            found = list[i];
            list[i] = NULL;
        }
    }
    wp_desc_list_free(list, count);
    if (!found) snprintf(err, errlen, "The plugin %s was not found", kind);
    return found;
}

WpPlugin *wp_plugin_open(const char *kind, const char *path, int rate, int channels, int max_block, char *err, size_t errlen)
{
    WpDesc *desc = wp_find_desc(kind, path, err, errlen);
    if (!desc) return NULL;
    WpPlugin *p = calloc(1, sizeof(WpPlugin));
    pthread_mutex_init(&p->lock, NULL);
    p->desc = desc;
    p->be = backend_for(desc->format);
    p->channels = channels > 0 ? channels : 1;
    p->rate = rate;
    p->max_block = max_block > 0 ? max_block : 1024;
    p->n_units = desc->n_in == 1 && desc->n_out == 1 && p->channels > 1 ? p->channels : 1;
    p->units = calloc(p->n_units, sizeof(WpUnit *));
    for (int i = 0; i < p->n_units; i++) {
        p->units[i] = p->be->create(desc, rate, p->max_block, err, errlen);
        if (!p->units[i]) {
            wp_plugin_free(p);
            return NULL;
        }
    }
    int nin = desc->n_in > 0 ? desc->n_in : 1;
    int nout = desc->n_out > 0 ? desc->n_out : 1;
    p->inb = calloc((size_t) p->n_units * nin, sizeof(float *));
    p->outb = calloc((size_t) p->n_units * nout, sizeof(float *));
    for (int i = 0; i < p->n_units * nin; i++) p->inb[i] = calloc(p->max_block, sizeof(float));
    for (int i = 0; i < p->n_units * nout; i++) p->outb[i] = calloc(p->max_block, sizeof(float));
    for (int i = 0; i < desc->n_params; i++) {
        for (int u = 0; u < p->n_units; u++) p->be->set_param(p->units[u], i, desc->params[i].def);
    }
    return p;
}

void wp_plugin_free(WpPlugin *p)
{
    if (!p) return;
    if (p->units) {
        for (int i = 0; i < p->n_units; i++) {
            if (p->units[i]) p->be->destroy(p->units[i]);
        }
    }
    int nin = p->desc->n_in > 0 ? p->desc->n_in : 1;
    int nout = p->desc->n_out > 0 ? p->desc->n_out : 1;
    if (p->inb) {
        for (int i = 0; i < p->n_units * nin; i++) free(p->inb[i]);
    }
    if (p->outb) {
        for (int i = 0; i < p->n_units * nout; i++) free(p->outb[i]);
    }
    free(p->inb);
    free(p->outb);
    free(p->units);
    wp_desc_free(p->desc);
    pthread_mutex_destroy(&p->lock);
    free(p);
}

WpDesc *wp_plugin_desc(WpPlugin *p)
{
    return p->desc;
}

static void set_all(WpPlugin *p, int index, double value)
{
    pthread_mutex_lock(&p->lock);
    for (int u = 0; u < p->n_units; u++) p->be->set_param(p->units[u], index, value);
    pthread_mutex_unlock(&p->lock);
}

void wp_plugin_set_param(WpPlugin *p, int index, double value)
{
    set_all(p, index, value);
    if (p->desc->format == WP_FORMAT_LV2 && p->desc->ui_binary) wp_lv2_ui_port_event(p->units[0], index, value);
}

double wp_plugin_get_param(WpPlugin *p, int index)
{
    pthread_mutex_lock(&p->lock);
    double v = p->be->get_param(p->units[0], index);
    pthread_mutex_unlock(&p->lock);
    return v;
}

int wp_plugin_latency(WpPlugin *p)
{
    return p->be->latency(p->units[0]);
}

void wp_plugin_run_interleaved(WpPlugin *p, float *buf, int frames)
{
    WpDesc *d = p->desc;
    int ch = p->channels;
    int dual = p->n_units > 1;
    int nin = d->n_in > 0 ? d->n_in : 1;
    int nout = d->n_out > 0 ? d->n_out : 1;
    pthread_mutex_lock(&p->lock);
    for (int off = 0; off < frames; off += p->max_block) {
        int n = frames - off < p->max_block ? frames - off : p->max_block;
        float *base = buf + (size_t) off * ch;
        for (int u = 0; u < p->n_units; u++) {
            float **in = p->inb + (size_t) u * nin;
            float **out = p->outb + (size_t) u * nout;
            for (int i = 0; i < d->n_in; i++) {
                int c = dual ? u : i % ch;
                float *dst = in[i];
                for (int f = 0; f < n; f++) dst[f] = base[(size_t) f * ch + c];
            }
            p->be->run(p->units[u], in, out, n);
        }
        if (d->n_out == 0) continue;
        for (int c = 0; c < ch; c++) {
            float *src = dual ? p->outb[(size_t) c * nout] : p->outb[c % d->n_out];
            for (int f = 0; f < n; f++) base[(size_t) f * ch + c] = src[f];
        }
    }
    pthread_mutex_unlock(&p->lock);
}

int wp_plugin_save_state(WpPlugin *p, uint8_t **data, size_t *len)
{
    pthread_mutex_lock(&p->lock);
    int r = p->be->save_state(p->units[0], data, len);
    pthread_mutex_unlock(&p->lock);
    return r;
}

int wp_plugin_load_state(WpPlugin *p, const uint8_t *data, size_t len)
{
    int r = 0;
    pthread_mutex_lock(&p->lock);
    for (int u = 0; u < p->n_units; u++) {
        if (p->be->load_state(p->units[u], data, len) < 0) r = -1;
    }
    pthread_mutex_unlock(&p->lock);
    return r;
}

int wp_plugin_has_ui(WpPlugin *p)
{
    return p->desc->format == WP_FORMAT_LV2 && p->desc->ui_binary != NULL;
}

static void ui_write(void *ctx, int index, double value)
{
    set_all(ctx, index, value);
}

int wp_plugin_show_ui(WpPlugin *p, int show, char *err, size_t errlen)
{
    if (!wp_plugin_has_ui(p)) {
        snprintf(err, errlen, "The plugin has no window of its own");
        return -1;
    }
    return wp_lv2_ui_show(p->units[0], show, ui_write, p, err, errlen);
}

int wp_plugin_ui_visible(WpPlugin *p)
{
    return wp_plugin_has_ui(p) && wp_lv2_ui_visible(p->units[0]);
}

void wp_plugin_ui_idle(WpPlugin *p)
{
    if (wp_plugin_has_ui(p)) wp_lv2_ui_idle(p->units[0]);
}

typedef struct {
    char **seen;
    int n_seen;
    WpStr out;
    int count;
} Candidates;

static void add_candidate(Candidates *c, const char *format, const char *path)
{
    char real[PATH_MAX];
    const char *key = realpath(path, real) ? real : path;
    char *tagged = wp_dup_printf("%s|%s", format, key);
    for (int i = 0; i < c->n_seen; i++) {
        if (strcmp(c->seen[i], tagged) == 0) {
            free(tagged);
            return;
        }
    }
    c->seen = realloc(c->seen, sizeof(char *) * (c->n_seen + 1));
    c->seen[c->n_seen++] = tagged;
    if (c->count++) wp_str_add(&c->out, ",");
    wp_str_add(&c->out, "{\"format\":");
    wp_str_add_json(&c->out, format);
    wp_str_add(&c->out, ",\"path\":");
    wp_str_add_json(&c->out, key);
    wp_str_add(&c->out, "}");
}

static int is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

static int is_file(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

enum {
    SCAN_LV2 = 1,
    SCAN_LADSPA = 2,
    SCAN_CLAP = 4
};

static void scan_dir(Candidates *c, const char *dir, int formats, int depth)
{
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    char **names = NULL;
    int n = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        names = realloc(names, sizeof(char *) * (n + 1));
        names[n++] = strdup(e->d_name);
    }
    closedir(d);
    for (int i = 0; i < n; i++) {
        char *full = wp_dup_printf("%s/%s", dir, names[i]);
        if (is_dir(full)) {
            char *manifest = wp_dup_printf("%s/manifest.ttl", full);
            if ((formats & SCAN_LV2) && is_file(manifest)) {
                add_candidate(c, "lv2", full);
            } else if (wp_has_suffix(names[i], ".clap") && (formats & SCAN_CLAP)) {
                char *inner = wp_dup_printf("%s/%s", full, names[i]);
                if (is_file(inner)) add_candidate(c, "clap", inner);
                free(inner);
            } else if (depth > 0 && (formats & SCAN_CLAP)) {
                scan_dir(c, full, formats & SCAN_CLAP, depth - 1);
            }
            free(manifest);
        } else if (is_file(full)) {
            if ((formats & SCAN_CLAP) && wp_has_suffix(names[i], ".clap")) add_candidate(c, "clap", full);
            else if ((formats & SCAN_LADSPA) && wp_has_suffix(names[i], ".so")) add_candidate(c, "ladspa", full);
        }
        free(full);
        free(names[i]);
    }
    free(names);
}

static void scan_list(Candidates *c, const char *list, int formats, int depth)
{
    char *copy = strdup(list);
    char *save = NULL;
    for (char *t = strtok_r(copy, ":", &save); t; t = strtok_r(NULL, ":", &save)) {
        if (*t) scan_dir(c, t, formats, depth);
    }
    free(copy);
}

static void scan_defaults(Candidates *c, const char *env, const char *home_sub, const char *name, int formats, int depth)
{
    const char *v = getenv(env);
    if (v) {
        scan_list(c, v, formats, depth);
        return;
    }
    const char *home = getenv("HOME");
    if (home && home_sub) {
        char *p = wp_dup_printf("%s/%s", home, home_sub);
        scan_dir(c, p, formats, depth);
        free(p);
    }
    const char *prefixes[] = { "/usr/local/lib", "/usr/lib", "/usr/lib64", NULL };
    for (int i = 0; prefixes[i]; i++) {
        char *p = wp_dup_printf("%s/%s", prefixes[i], name);
        scan_dir(c, p, formats, depth);
        free(p);
    }
    char *pattern = wp_dup_printf("/usr/lib/*-linux-*/%s", name);
    glob_t g;
    if (glob(pattern, 0, NULL, &g) == 0) {
        for (size_t i = 0; i < g.gl_pathc; i++) scan_dir(c, g.gl_pathv[i], formats, depth);
        globfree(&g);
    }
    free(pattern);
}

char *wp_candidates_json(void)
{
    Candidates c = {0};
    wp_str_add(&c.out, "[");
    const char *extra = getenv("SINGULARITY_WAVE_PLUGIN_PATH");
    if (extra) scan_list(&c, extra, SCAN_LV2 | SCAN_LADSPA | SCAN_CLAP, 1);
    scan_defaults(&c, "LV2_PATH", ".lv2", "lv2", SCAN_LV2, 0);
    scan_defaults(&c, "LADSPA_PATH", NULL, "ladspa", SCAN_LADSPA, 0);
    scan_defaults(&c, "CLAP_PATH", ".clap", "clap", SCAN_CLAP, 3);
    wp_str_add(&c.out, "]");
    for (int i = 0; i < c.n_seen; i++) free(c.seen[i]);
    free(c.seen);
    return c.out.data;
}

char *wp_scan_json(const char *format, const char *path)
{
    int f = strcmp(format, "lv2") == 0 ? WP_FORMAT_LV2 : strcmp(format, "ladspa") == 0 ? WP_FORMAT_LADSPA : WP_FORMAT_CLAP;
    int count = 0;
    WpDesc **list = wp_describe(f, path, &count);
    WpStr s = {0};
    wp_str_add(&s, "[");
    for (int i = 0; i < count; i++) {
        if (i) wp_str_add(&s, ",");
        wp_desc_to_json(list[i], &s);
    }
    wp_str_add(&s, "]");
    wp_desc_list_free(list, count);
    return s.data;
}
