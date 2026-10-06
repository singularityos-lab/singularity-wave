#define _GNU_SOURCE
#include "waveplug.h"
#include "wp_internal.h"
#include "abi_lv2.h"
#include "ttl.h"

#include <dirent.h>
#include <glob.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define MAX_LIST 512

typedef struct {
    const char *uri;
    WpStr out;
    int count;
    char **seen;
    int n_seen;
} PresetScan;

static void scan_bundle(PresetScan *ps, const char *bundle)
{
    for (int i = 0; i < ps->n_seen; i++) {
        if (strcmp(ps->seen[i], bundle) == 0) return;
    }
    ps->seen = realloc(ps->seen, sizeof(char *) * (ps->n_seen + 1));
    ps->seen[ps->n_seen++] = strdup(bundle);
    char *manifest = wp_dup_printf("%s/manifest.ttl", bundle);
    struct stat st;
    if (stat(manifest, &st) != 0) {
        free(manifest);
        return;
    }
    TtlModel *m = ttl_model_new();
    ttl_parse_file(m, manifest);
    free(manifest);
    const char *presets[MAX_LIST];
    int n = ttl_subjects(m, WAVE_RDF "type", WAVE_LV2_PSET "Preset", presets, MAX_LIST);
    int relevant = 0;
    for (int i = 0; i < n; i++) {
        if (!ttl_has(m, presets[i], WAVE_LV2_CORE "appliesTo", ps->uri)) continue;
        relevant = 1;
        const char *also[16];
        int na = ttl_get_all(m, presets[i], WAVE_RDFS "seeAlso", also, 16);
        for (int a = 0; a < na; a++) {
            char *path = ttl_uri_to_path(also[a]);
            if (path) {
                ttl_parse_file(m, path);
                free(path);
            }
        }
    }
    if (relevant) {
        n = ttl_subjects(m, WAVE_RDF "type", WAVE_LV2_PSET "Preset", presets, MAX_LIST);
        for (int i = 0; i < n; i++) {
            if (!ttl_has(m, presets[i], WAVE_LV2_CORE "appliesTo", ps->uri)) continue;
            const char *label = ttl_get(m, presets[i], WAVE_RDFS "label");
            if (ps->count++) wp_str_add(&ps->out, ",");
            wp_str_add(&ps->out, "{\"uri\":");
            wp_str_add_json(&ps->out, presets[i]);
            wp_str_add(&ps->out, ",\"label\":");
            wp_str_add_json(&ps->out, label ? label : presets[i]);
            wp_str_add(&ps->out, ",\"bundle\":");
            wp_str_add_json(&ps->out, bundle);
            wp_str_add(&ps->out, ",\"values\":{");
            const char *ports[MAX_LIST];
            int np = ttl_get_all(m, presets[i], WAVE_LV2_CORE "port", ports, MAX_LIST);
            int first = 1;
            for (int p = 0; p < np; p++) {
                const char *sym = ttl_get(m, ports[p], WAVE_LV2_CORE "symbol");
                const char *val = ttl_get(m, ports[p], WAVE_LV2_PSET "value");
                if (!sym || !val) continue;
                if (!first) wp_str_add(&ps->out, ",");
                first = 0;
                wp_str_add_json(&ps->out, sym);
                wp_str_add(&ps->out, ":");
                wp_str_add_double(&ps->out, wp_strtod(val));
            }
            wp_str_add(&ps->out, "}}");
        }
    }
    ttl_model_free(m);
}

static void scan_dir(PresetScan *ps, const char *dir)
{
    DIR *d = opendir(dir);
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char *full = wp_dup_printf("%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(full, &st) == 0 && S_ISDIR(st.st_mode)) scan_bundle(ps, full);
        free(full);
    }
    closedir(d);
}

static void scan_list(PresetScan *ps, const char *list)
{
    char *copy = strdup(list);
    char *save = NULL;
    for (char *t = strtok_r(copy, ":", &save); t; t = strtok_r(NULL, ":", &save)) {
        if (*t) scan_dir(ps, t);
    }
    free(copy);
}

char *wp_lv2_presets_json(const char *uri)
{
    PresetScan ps = {0};
    ps.uri = uri;
    wp_str_add(&ps.out, "[");
    const char *home = getenv("HOME");
    if (home) {
        char *p = wp_dup_printf("%s/.lv2", home);
        scan_dir(&ps, p);
        free(p);
    }
    const char *extra = getenv("SINGULARITY_WAVE_PLUGIN_PATH");
    if (extra) scan_list(&ps, extra);
    const char *env = getenv("LV2_PATH");
    if (env) {
        scan_list(&ps, env);
    } else {
        scan_list(&ps, "/usr/local/lib/lv2:/usr/lib/lv2:/usr/lib64/lv2");
        glob_t g;
        if (glob("/usr/lib/*-linux-*/lv2", 0, NULL, &g) == 0) {
            for (size_t i = 0; i < g.gl_pathc; i++) scan_dir(&ps, g.gl_pathv[i]);
            globfree(&g);
        }
    }
    wp_str_add(&ps.out, "]");
    for (int i = 0; i < ps.n_seen; i++) free(ps.seen[i]);
    free(ps.seen);
    return ps.out.data;
}
