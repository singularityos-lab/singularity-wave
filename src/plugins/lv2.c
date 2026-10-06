#define _GNU_SOURCE
#include "wp_internal.h"
#include "abi_lv2.h"
#include "ttl.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define URID "http://lv2plug.in/ns/ext/urid#"
#define OPTIONS "http://lv2plug.in/ns/ext/options#"
#define BUFSZ "http://lv2plug.in/ns/ext/buf-size#"
#define LOG "http://lv2plug.in/ns/ext/log#"
#define PPROPS "http://lv2plug.in/ns/ext/port-props#"
#define STATE "http://lv2plug.in/ns/ext/state#"
#define ATOM_CAPACITY 8192
#define MAX_LIST 512

static pthread_mutex_t urid_lock = PTHREAD_MUTEX_INITIALIZER;
static char **urids;
static uint32_t n_urids;

static LV2_URID urid_map(void *handle, const char *uri)
{
    (void) handle;
    pthread_mutex_lock(&urid_lock);
    for (uint32_t i = 0; i < n_urids; i++) {
        if (strcmp(urids[i], uri) == 0) {
            pthread_mutex_unlock(&urid_lock);
            return i + 1;
        }
    }
    urids = realloc(urids, sizeof(char *) * (n_urids + 1));
    urids[n_urids] = strdup(uri);
    LV2_URID id = ++n_urids;
    pthread_mutex_unlock(&urid_lock);
    return id;
}

static const char *urid_unmap(void *handle, LV2_URID urid)
{
    (void) handle;
    pthread_mutex_lock(&urid_lock);
    const char *r = urid > 0 && urid <= n_urids ? urids[urid - 1] : NULL;
    pthread_mutex_unlock(&urid_lock);
    return r;
}

static int log_vprintf(void *handle, LV2_URID type, const char *fmt, va_list ap)
{
    (void) handle;
    (void) type;
    fputs("lv2: ", stderr);
    return vfprintf(stderr, fmt, ap);
}

static int log_printf(void *handle, LV2_URID type, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = log_vprintf(handle, type, fmt, ap);
    va_end(ap);
    return r;
}

static const char *supported_features[] = {
    URID "map",
    URID "unmap",
    OPTIONS "options",
    BUFSZ "boundedBlockLength",
    LOG "log",
    WAVE_LV2_CORE "isLive",
    WAVE_LV2_CORE "inPlaceBroken",
    WAVE_LV2_CORE "hardRTCapable",
    STATE "loadDefaultState",
    NULL
};

static int feature_supported(const char *uri)
{
    for (int i = 0; supported_features[i]; i++) {
        if (strcmp(supported_features[i], uri) == 0) return 1;
    }
    return 0;
}

static int has_type(TtlModel *m, const char *s, const char *type)
{
    return ttl_has(m, s, WAVE_RDF "type", type);
}

static double num(TtlModel *m, const char *s, const char *p, double fallback, int *found)
{
    const char *v = ttl_get(m, s, p);
    if (found) *found = v != NULL;
    return v ? wp_strtod(v) : fallback;
}

static char *bundle_file(const char *bundle, const char *name)
{
    size_t n = strlen(bundle);
    return wp_dup_printf("%s%s%s", bundle, n && bundle[n - 1] == '/' ? "" : "/", name);
}

static int cmp_choice(const void *a, const void *b)
{
    const double *x = a, *y = b;
    return (*x > *y) - (*x < *y);
}

static void load_see_also(TtlModel *m)
{
    for (int round = 0; round < 4; round++) {
        int before = m->n_loaded;
        int count = m->count;
        for (int i = 0; i < count; i++) {
            if (strcmp(m->triples[i].p, WAVE_RDFS "seeAlso") != 0) continue;
            char *path = ttl_uri_to_path(m->triples[i].o);
            if (path) {
                ttl_parse_file(m, path);
                free(path);
            }
        }
        if (m->n_loaded == before) break;
    }
}

static WpDesc *describe_plugin(TtlModel *m, const char *uri, const char *bundle)
{
    WpDesc *d = wp_desc_new(WP_FORMAT_LV2);
    d->uri = strdup(uri);
    d->kind = wp_dup_printf("lv2:%s", uri);
    d->bundle = strdup(bundle);
    d->path = strdup(bundle);
    const char *name = ttl_get(m, uri, WAVE_DOAP "name");
    d->name = strdup(name ? name : uri);
    const char *maint = ttl_get(m, uri, WAVE_DOAP "maintainer");
    if (!maint) maint = ttl_get(m, uri, WAVE_DOAP "developer");
    const char *vendor = maint ? ttl_get(m, maint, WAVE_FOAF "name") : NULL;
    d->vendor = strdup(vendor ? vendor : "");
    const char *binary = ttl_get(m, uri, WAVE_LV2_CORE "binary");
    if (binary) d->binary = ttl_uri_to_path(binary);
    const char *list[MAX_LIST];
    int nf = ttl_get_all(m, uri, WAVE_LV2_CORE "requiredFeature", list, MAX_LIST);
    for (int i = 0; i < nf; i++) {
        if (!feature_supported(list[i]) && !d->unsupported) d->unsupported = strdup(list[i]);
    }
    const char *ports[MAX_LIST];
    int np = ttl_get_all(m, uri, WAVE_LV2_CORE "port", ports, MAX_LIST);
    int max_index = -1;
    for (int i = 0; i < np; i++) {
        int idx = (int) num(m, ports[i], WAVE_LV2_CORE "index", -1, NULL);
        if (idx > max_index) max_index = idx;
    }
    d->n_ports = max_index + 1;
    d->port_kind = calloc(d->n_ports > 0 ? d->n_ports : 1, sizeof(int));
    d->port_default = calloc(d->n_ports > 0 ? d->n_ports : 1, sizeof(float));
    const char **by_index = calloc(d->n_ports > 0 ? d->n_ports : 1, sizeof(char *));
    for (int i = 0; i < d->n_ports; i++) d->port_kind[i] = WP_PORT_OTHER;
    for (int i = 0; i < np; i++) {
        int idx = (int) num(m, ports[i], WAVE_LV2_CORE "index", -1, NULL);
        if (idx < 0) continue;
        by_index[idx] = ports[i];
        int input = has_type(m, ports[i], WAVE_LV2_CORE "InputPort");
        int kind = WP_PORT_OTHER;
        if (has_type(m, ports[i], WAVE_LV2_CORE "AudioPort")) kind = input ? WP_PORT_AUDIO_IN : WP_PORT_AUDIO_OUT;
        else if (has_type(m, ports[i], WAVE_LV2_CORE "ControlPort")) kind = input ? WP_PORT_CONTROL_IN : WP_PORT_CONTROL_OUT;
        else if (has_type(m, ports[i], WAVE_LV2_ATOM "AtomPort")) kind = input ? WP_PORT_ATOM_IN : WP_PORT_ATOM_OUT;
        else if (has_type(m, ports[i], WAVE_LV2_CORE "CVPort")) kind = input ? WP_PORT_CV_IN : WP_PORT_CV_OUT;
        d->port_kind[idx] = kind;
        d->port_default[idx] = (float) num(m, ports[i], WAVE_LV2_CORE "default", 0, NULL);
    }
    for (int idx = 0; idx < d->n_ports; idx++) {
        const char *port = by_index[idx];
        if (!port) continue;
        int kind = d->port_kind[idx];
        if (kind == WP_PORT_AUDIO_IN) {
            d->in_ports = realloc(d->in_ports, sizeof(int) * (d->n_in + 1));
            d->in_ports[d->n_in++] = idx;
        } else if (kind == WP_PORT_AUDIO_OUT) {
            d->out_ports = realloc(d->out_ports, sizeof(int) * (d->n_out + 1));
            d->out_ports[d->n_out++] = idx;
        } else if (kind == WP_PORT_CONTROL_OUT) {
            if (ttl_has(m, port, WAVE_LV2_CORE "portProperty", WAVE_LV2_CORE "reportsLatency") || ttl_has(m, port, WAVE_LV2_CORE "designation", WAVE_LV2_CORE "latency")) d->latency_port = idx;
        } else if (kind == WP_PORT_CONTROL_IN) {
            WpParam *p = wp_desc_add_param(d);
            p->port = idx;
            const char *sym = ttl_get(m, port, WAVE_LV2_CORE "symbol");
            const char *label = ttl_get(m, port, WAVE_LV2_CORE "name");
            p->id = strdup(sym ? sym : "");
            if (!sym) {
                free(p->id);
                p->id = wp_dup_printf("port%d", idx);
            }
            p->label = strdup(label ? label : p->id);
            int has_min, has_max, has_def;
            p->min = num(m, port, WAVE_LV2_CORE "minimum", 0, &has_min);
            p->max = num(m, port, WAVE_LV2_CORE "maximum", 1, &has_max);
            p->def = num(m, port, WAVE_LV2_CORE "default", p->min, &has_def);
            if (p->max < p->min) {
                double t = p->max;
                p->max = p->min;
                p->min = t;
            }
            if (p->def < p->min) p->def = p->min;
            if (p->def > p->max) p->def = p->max;
            d->port_default[idx] = (float) p->def;
            p->toggle = ttl_has(m, port, WAVE_LV2_CORE "portProperty", WAVE_LV2_CORE "toggled");
            p->integer = ttl_has(m, port, WAVE_LV2_CORE "portProperty", WAVE_LV2_CORE "integer");
            p->logarithmic = ttl_has(m, port, WAVE_LV2_CORE "portProperty", PPROPS "logarithmic");
            if (ttl_has(m, port, WAVE_LV2_CORE "portProperty", WAVE_LV2_CORE "enumeration")) {
                const char *points[MAX_LIST];
                int ns = ttl_get_all(m, port, WAVE_LV2_CORE "scalePoint", points, MAX_LIST);
                double *values = malloc(sizeof(double) * 2 * (ns ? ns : 1));
                for (int s = 0; s < ns; s++) {
                    values[s * 2] = num(m, points[s], WAVE_RDF "value", 0, NULL);
                    values[s * 2 + 1] = s;
                }
                qsort(values, ns, sizeof(double) * 2, cmp_choice);
                for (int s = 0; s < ns; s++) {
                    const char *pl = ttl_get(m, points[(int) values[s * 2 + 1]], WAVE_RDFS "label");
                    char buf[64];
                    if (!pl) {
                        snprintf(buf, sizeof buf, "%g", values[s * 2]);
                        pl = buf;
                    }
                    wp_param_add_choice(p, pl, values[s * 2]);
                }
                free(values);
            }
        }
    }
    free(by_index);
    const char *uis[MAX_LIST];
    int nu = ttl_get_all(m, uri, WAVE_LV2_UI "ui", uis, MAX_LIST);
    for (int i = 0; i < nu; i++) {
        if (has_type(m, uis[i], WAVE_LV2_KX_UI "Widget") || has_type(m, uis[i], WAVE_LV2_UI "external")) {
            const char *ub = ttl_get(m, uis[i], WAVE_LV2_UI "binary");
            char *path = ub ? ttl_uri_to_path(ub) : NULL;
            if (path) {
                d->ui_uri = strdup(uis[i]);
                d->ui_binary = path;
                d->ui_bundle = strdup(bundle);
                break;
            }
        }
    }
    return d;
}

WpDesc **wp_lv2_describe(const char *bundle, int *count)
{
    *count = 0;
    char *manifest = bundle_file(bundle, "manifest.ttl");
    TtlModel *m = ttl_model_new();
    if (ttl_parse_file(m, manifest) < 0 && m->count == 0) {
        free(manifest);
        ttl_model_free(m);
        return NULL;
    }
    free(manifest);
    load_see_also(m);
    const char *plugins[MAX_LIST];
    int n = ttl_subjects(m, WAVE_RDF "type", WAVE_LV2_CORE "Plugin", plugins, MAX_LIST);
    WpDesc **out = calloc(n ? n : 1, sizeof(WpDesc *));
    for (int i = 0; i < n; i++) out[(*count)++] = describe_plugin(m, plugins[i], bundle);
    ttl_model_free(m);
    return out;
}

typedef struct {
    WpDesc *desc;
    void *lib;
    const LV2_Descriptor *d;
    LV2_Handle h;
    float *controls;
    float **audio;
    LV2_Atom_Sequence **atoms;
    int max_block;
    int rate;
    int32_t maxb;
    int32_t minb;
    int32_t nomb;
    float srate;
    LV2_URID_Map map;
    LV2_URID_Unmap unmap;
    LV2_Options_Option opts[5];
    LV2_Log_Log log;
    LV2_Feature f_map;
    LV2_Feature f_unmap;
    LV2_Feature f_opts;
    LV2_Feature f_bounded;
    LV2_Feature f_log;
    LV2_Feature f_live;
    const LV2_Feature *features[7];
    void *ui_lib;
    const LV2UI_Descriptor *uid;
    LV2UI_Handle uih;
    LV2_External_UI_Widget *widget;
    LV2_External_UI_Host ehost;
    LV2_Feature uf_map;
    LV2_Feature uf_unmap;
    LV2_Feature uf_instance;
    LV2_Feature uf_kx;
    LV2_Feature uf_ext;
    const LV2_Feature *ui_features[6];
    WpUiWrite write;
    void *write_ctx;
    int ui_visible;
    uint32_t seq_type;
    uint32_t chunk_type;
} Lv2Unit;

static void unit_free(Lv2Unit *u)
{
    if (!u) return;
    if (u->uih && u->uid && u->uid->cleanup) u->uid->cleanup(u->uih);
    if (u->ui_lib) dlclose(u->ui_lib);
    if (u->h) {
        if (u->d->deactivate) u->d->deactivate(u->h);
        u->d->cleanup(u->h);
    }
    if (u->lib) dlclose(u->lib);
    if (u->audio) {
        for (int i = 0; i < u->desc->n_ports; i++) free(u->audio[i]);
    }
    if (u->atoms) {
        for (int i = 0; i < u->desc->n_ports; i++) free(u->atoms[i]);
    }
    free(u->audio);
    free(u->atoms);
    free(u->controls);
    free(u);
}

static WpUnit *lv2_create(WpDesc *desc, int rate, int max_block, char *err, size_t errlen)
{
    if (desc->unsupported) {
        snprintf(err, errlen, "The plugin needs a host feature Wave does not offer: %s", desc->unsupported);
        return NULL;
    }
    if (!desc->binary) {
        snprintf(err, errlen, "The plugin bundle names no binary");
        return NULL;
    }
    Lv2Unit *u = calloc(1, sizeof(Lv2Unit));
    u->desc = desc;
    u->rate = rate;
    u->max_block = max_block;
    u->lib = dlopen(desc->binary, RTLD_NOW | RTLD_LOCAL);
    if (!u->lib) {
        snprintf(err, errlen, "%s", dlerror());
        unit_free(u);
        return NULL;
    }
    LV2_Descriptor_Function fn = (LV2_Descriptor_Function) dlsym(u->lib, "lv2_descriptor");
    if (!fn) {
        snprintf(err, errlen, "The library has no lv2_descriptor");
        unit_free(u);
        return NULL;
    }
    for (uint32_t i = 0;; i++) {
        const LV2_Descriptor *d = fn(i);
        if (!d) break;
        if (strcmp(d->URI, desc->uri) == 0) {
            u->d = d;
            break;
        }
    }
    if (!u->d) {
        snprintf(err, errlen, "The library does not provide %s", desc->uri);
        unit_free(u);
        return NULL;
    }
    u->map.map = urid_map;
    u->unmap.unmap = urid_unmap;
    u->maxb = max_block;
    u->minb = 1;
    u->nomb = max_block;
    u->srate = (float) rate;
    uint32_t int_type = urid_map(NULL, WAVE_LV2_ATOM "Int");
    uint32_t float_type = urid_map(NULL, WAVE_LV2_ATOM "Float");
    u->opts[0] = (LV2_Options_Option) { 0, 0, urid_map(NULL, BUFSZ "maxBlockLength"), sizeof(int32_t), int_type, &u->maxb };
    u->opts[1] = (LV2_Options_Option) { 0, 0, urid_map(NULL, BUFSZ "minBlockLength"), sizeof(int32_t), int_type, &u->minb };
    u->opts[2] = (LV2_Options_Option) { 0, 0, urid_map(NULL, BUFSZ "nominalBlockLength"), sizeof(int32_t), int_type, &u->nomb };
    u->opts[3] = (LV2_Options_Option) { 0, 0, urid_map(NULL, "http://lv2plug.in/ns/ext/parameters#sampleRate"), sizeof(float), float_type, &u->srate };
    u->opts[4] = (LV2_Options_Option) { 0, 0, 0, 0, 0, NULL };
    u->log.printf = log_printf;
    u->log.vprintf = log_vprintf;
    u->f_map = (LV2_Feature) { URID "map", &u->map };
    u->f_unmap = (LV2_Feature) { URID "unmap", &u->unmap };
    u->f_opts = (LV2_Feature) { OPTIONS "options", u->opts };
    u->f_bounded = (LV2_Feature) { BUFSZ "boundedBlockLength", NULL };
    u->f_log = (LV2_Feature) { LOG "log", &u->log };
    u->f_live = (LV2_Feature) { WAVE_LV2_CORE "isLive", NULL };
    u->features[0] = &u->f_map;
    u->features[1] = &u->f_unmap;
    u->features[2] = &u->f_opts;
    u->features[3] = &u->f_bounded;
    u->features[4] = &u->f_log;
    u->features[5] = &u->f_live;
    u->features[6] = NULL;
    u->seq_type = urid_map(NULL, WAVE_LV2_ATOM "Sequence");
    u->chunk_type = urid_map(NULL, WAVE_LV2_ATOM "Chunk");
    char *bundle = wp_dup_printf("%s%s", desc->bundle, wp_has_suffix(desc->bundle, "/") ? "" : "/");
    u->h = u->d->instantiate(u->d, rate, bundle, u->features);
    free(bundle);
    if (!u->h) {
        snprintf(err, errlen, "The plugin refused to start");
        unit_free(u);
        return NULL;
    }
    int n = desc->n_ports;
    u->controls = calloc(n ? n : 1, sizeof(float));
    u->audio = calloc(n ? n : 1, sizeof(float *));
    u->atoms = calloc(n ? n : 1, sizeof(LV2_Atom_Sequence *));
    for (int i = 0; i < n; i++) {
        int k = desc->port_kind[i];
        u->controls[i] = desc->port_default[i];
        if (k == WP_PORT_AUDIO_IN || k == WP_PORT_AUDIO_OUT || k == WP_PORT_CV_IN || k == WP_PORT_CV_OUT) {
            u->audio[i] = calloc(max_block, sizeof(float));
            u->d->connect_port(u->h, i, u->audio[i]);
        } else if (k == WP_PORT_CONTROL_IN || k == WP_PORT_CONTROL_OUT) {
            u->d->connect_port(u->h, i, &u->controls[i]);
        } else if (k == WP_PORT_ATOM_IN || k == WP_PORT_ATOM_OUT) {
            u->atoms[i] = calloc(1, ATOM_CAPACITY);
            u->d->connect_port(u->h, i, u->atoms[i]);
        } else {
            u->d->connect_port(u->h, i, NULL);
        }
    }
    if (u->d->activate) u->d->activate(u->h);
    return (WpUnit *) u;
}

static void lv2_destroy(WpUnit *unit)
{
    unit_free((Lv2Unit *) unit);
}

static void lv2_set_param(WpUnit *unit, int index, double value)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (index < 0 || index >= u->desc->n_params) return;
    u->controls[u->desc->params[index].port] = (float) value;
}

static double lv2_get_param(WpUnit *unit, int index)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (index < 0 || index >= u->desc->n_params) return 0;
    return u->controls[u->desc->params[index].port];
}

static void lv2_run(WpUnit *unit, float **in, float **out, int frames)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    WpDesc *d = u->desc;
    for (int i = 0; i < d->n_in; i++) memcpy(u->audio[d->in_ports[i]], in[i], sizeof(float) * frames);
    for (int i = 0; i < d->n_ports; i++) {
        if (d->port_kind[i] == WP_PORT_ATOM_IN) {
            u->atoms[i]->atom.size = sizeof(LV2_Atom_Sequence_Body);
            u->atoms[i]->atom.type = u->seq_type;
            u->atoms[i]->body.unit = 0;
            u->atoms[i]->body.pad = 0;
        } else if (d->port_kind[i] == WP_PORT_ATOM_OUT) {
            u->atoms[i]->atom.size = ATOM_CAPACITY - sizeof(LV2_Atom);
            u->atoms[i]->atom.type = u->chunk_type;
        }
    }
    u->d->run(u->h, (uint32_t) frames);
    for (int i = 0; i < d->n_out; i++) memcpy(out[i], u->audio[d->out_ports[i]], sizeof(float) * frames);
}

static int lv2_latency(WpUnit *unit)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (u->desc->latency_port < 0) return 0;
    float v = u->controls[u->desc->latency_port];
    return v > 0 ? (int) (v + 0.5f) : 0;
}

static int lv2_save_state(WpUnit *unit, uint8_t **data, size_t *len)
{
    (void) unit;
    *data = NULL;
    *len = 0;
    return -1;
}

static int lv2_load_state(WpUnit *unit, const uint8_t *data, size_t len)
{
    (void) unit;
    (void) data;
    (void) len;
    return -1;
}

const WpBackend wp_lv2_backend = {
    lv2_create,
    lv2_destroy,
    lv2_set_param,
    lv2_get_param,
    lv2_run,
    lv2_latency,
    lv2_save_state,
    lv2_load_state
};

static void ui_write(LV2UI_Controller controller, uint32_t port, uint32_t size, uint32_t protocol, const void *buffer)
{
    Lv2Unit *u = controller;
    if (protocol != 0 || size != sizeof(float) || !buffer) return;
    float v = *(const float *) buffer;
    for (int i = 0; i < u->desc->n_params; i++) {
        if (u->desc->params[i].port == (int) port) {
            if (u->write) u->write(u->write_ctx, i, v);
            else u->controls[port] = v;
            return;
        }
    }
}

static void ui_closed(LV2UI_Controller controller)
{
    Lv2Unit *u = controller;
    u->ui_visible = 0;
}

int wp_lv2_ui_show(WpUnit *unit, int show, WpUiWrite write, void *ctx, char *err, size_t errlen)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (!u->desc->ui_binary) {
        snprintf(err, errlen, "The plugin has no window of its own");
        return -1;
    }
    u->write = write;
    u->write_ctx = ctx;
    if (!show) {
        if (u->widget && u->ui_visible) u->widget->hide(u->widget);
        u->ui_visible = 0;
        return 0;
    }
    if (!u->uih) {
        u->ui_lib = dlopen(u->desc->ui_binary, RTLD_NOW | RTLD_LOCAL);
        if (!u->ui_lib) {
            snprintf(err, errlen, "%s", dlerror());
            return -1;
        }
        LV2UI_DescriptorFunction fn = (LV2UI_DescriptorFunction) dlsym(u->ui_lib, "lv2ui_descriptor");
        if (!fn) {
            snprintf(err, errlen, "The interface library has no lv2ui_descriptor");
            return -1;
        }
        for (uint32_t i = 0;; i++) {
            const LV2UI_Descriptor *d = fn(i);
            if (!d) break;
            if (strcmp(d->URI, u->desc->ui_uri) == 0) {
                u->uid = d;
                break;
            }
        }
        if (!u->uid) {
            snprintf(err, errlen, "The interface library does not provide %s", u->desc->ui_uri);
            return -1;
        }
        u->ehost.ui_closed = ui_closed;
        u->ehost.plugin_human_id = u->desc->name;
        u->uf_map = (LV2_Feature) { URID "map", &u->map };
        u->uf_unmap = (LV2_Feature) { URID "unmap", &u->unmap };
        u->uf_instance = (LV2_Feature) { "http://lv2plug.in/ns/ext/instance-access", u->h };
        u->uf_kx = (LV2_Feature) { WAVE_LV2_KX_UI "Host", &u->ehost };
        u->uf_ext = (LV2_Feature) { WAVE_LV2_UI "external", &u->ehost };
        u->ui_features[0] = &u->uf_map;
        u->ui_features[1] = &u->uf_unmap;
        u->ui_features[2] = &u->uf_instance;
        u->ui_features[3] = &u->uf_kx;
        u->ui_features[4] = &u->uf_ext;
        u->ui_features[5] = NULL;
        LV2UI_Widget widget = NULL;
        char *bundle = wp_dup_printf("%s%s", u->desc->ui_bundle, wp_has_suffix(u->desc->ui_bundle, "/") ? "" : "/");
        u->uih = u->uid->instantiate(u->uid, u->desc->uri, bundle, ui_write, u, &widget, u->ui_features);
        free(bundle);
        if (!u->uih || !widget) {
            snprintf(err, errlen, "The plugin window could not be created");
            return -1;
        }
        u->widget = widget;
        for (int i = 0; i < u->desc->n_params; i++) {
            if (u->uid->port_event) u->uid->port_event(u->uih, u->desc->params[i].port, sizeof(float), 0, &u->controls[u->desc->params[i].port]);
        }
    }
    u->widget->show(u->widget);
    u->ui_visible = 1;
    return 0;
}

void wp_lv2_ui_idle(WpUnit *unit)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (u->widget && u->ui_visible) u->widget->run(u->widget);
}

void wp_lv2_ui_port_event(WpUnit *unit, int index, double value)
{
    Lv2Unit *u = (Lv2Unit *) unit;
    if (!u->uih || !u->uid->port_event || index < 0 || index >= u->desc->n_params) return;
    float v = (float) value;
    u->uid->port_event(u->uih, u->desc->params[index].port, sizeof(float), 0, &v);
}

int wp_lv2_ui_visible(WpUnit *unit)
{
    return ((Lv2Unit *) unit)->ui_visible;
}
