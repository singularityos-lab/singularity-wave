#define _GNU_SOURCE
#include "wp_internal.h"
#include "abi_clap.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_EVENTS 512

typedef struct ClapLib {
    char *path;
    void *lib;
    const clap_plugin_entry_t *entry;
    int refs;
    struct ClapLib *next;
} ClapLib;

static pthread_mutex_t libs_lock = PTHREAD_MUTEX_INITIALIZER;
static ClapLib *libs;

static ClapLib *lib_acquire(const char *path, char *err, size_t errlen)
{
    pthread_mutex_lock(&libs_lock);
    for (ClapLib *l = libs; l; l = l->next) {
        if (strcmp(l->path, path) == 0) {
            l->refs++;
            pthread_mutex_unlock(&libs_lock);
            return l;
        }
    }
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        snprintf(err, errlen, "%s", dlerror());
        pthread_mutex_unlock(&libs_lock);
        return NULL;
    }
    const clap_plugin_entry_t *entry = dlsym(lib, "clap_entry");
    if (!entry || entry->clap_version.major < 1 || !entry->init || !entry->get_factory) {
        snprintf(err, errlen, "The library is not a CLAP 1.x plugin");
        dlclose(lib);
        pthread_mutex_unlock(&libs_lock);
        return NULL;
    }
    if (!entry->init(path)) {
        snprintf(err, errlen, "The CLAP library refused to start");
        dlclose(lib);
        pthread_mutex_unlock(&libs_lock);
        return NULL;
    }
    ClapLib *l = calloc(1, sizeof(ClapLib));
    l->path = strdup(path);
    l->lib = lib;
    l->entry = entry;
    l->refs = 1;
    l->next = libs;
    libs = l;
    pthread_mutex_unlock(&libs_lock);
    return l;
}

static void lib_release(ClapLib *lib)
{
    pthread_mutex_lock(&libs_lock);
    if (--lib->refs == 0) {
        ClapLib **pp = &libs;
        while (*pp && *pp != lib) pp = &(*pp)->next;
        if (*pp) *pp = lib->next;
        if (lib->entry->deinit) lib->entry->deinit();
        dlclose(lib->lib);
        free(lib->path);
        free(lib);
    }
    pthread_mutex_unlock(&libs_lock);
}

static const void *host_get_extension(const clap_host_t *host, const char *id)
{
    (void) host;
    (void) id;
    return NULL;
}

static void host_request(const clap_host_t *host)
{
    (void) host;
}

static void host_init(clap_host_t *h, void *data)
{
    memset(h, 0, sizeof(*h));
    h->clap_version = (clap_version_t) { 1, 2, 0 };
    h->host_data = data;
    h->name = "Wave";
    h->vendor = "Singularity";
    h->url = "";
    h->version = "0.1.0";
    h->get_extension = host_get_extension;
    h->request_restart = host_request;
    h->request_process = host_request;
    h->request_callback = host_request;
}

static int port_channels(const clap_plugin_t *p, const clap_plugin_audio_ports_t *ports, int input)
{
    if (!ports || ports->count(p, input) == 0) return 0;
    clap_audio_port_info_t info;
    memset(&info, 0, sizeof info);
    if (!ports->get(p, 0, input, &info)) return 0;
    return (int) info.channel_count;
}

static void fill_desc(WpDesc *d, const clap_plugin_t *p)
{
    const clap_plugin_audio_ports_t *ports = p->get_extension(p, CLAP_EXT_AUDIO_PORTS);
    d->n_in = port_channels(p, ports, 1);
    d->n_out = port_channels(p, ports, 0);
    const clap_plugin_params_t *params = p->get_extension(p, CLAP_EXT_PARAMS);
    if (!params) return;
    uint32_t n = params->count(p);
    for (uint32_t i = 0; i < n; i++) {
        clap_param_info_t info;
        memset(&info, 0, sizeof info);
        if (!params->get_info(p, i, &info)) continue;
        if (info.flags & (CLAP_PARAM_IS_HIDDEN | CLAP_PARAM_IS_READONLY)) continue;
        WpParam *wp = wp_desc_add_param(d);
        wp->clap_id = info.id;
        wp->id = wp_dup_printf("%u", info.id);
        info.name[CLAP_NAME_SIZE - 1] = 0;
        wp->label = strdup(info.name[0] ? info.name : wp->id);
        wp->min = info.min_value;
        wp->max = info.max_value;
        wp->def = info.default_value;
        if (wp->max < wp->min) wp->max = wp->min;
        int stepped = (info.flags & CLAP_PARAM_IS_STEPPED) != 0;
        wp->integer = stepped;
        wp->toggle = stepped && wp->min == 0 && wp->max == 1 && !(info.flags & CLAP_PARAM_IS_ENUM);
        if (stepped && (info.flags & CLAP_PARAM_IS_ENUM) && wp->max - wp->min <= 64 && params->value_to_text) {
            for (double v = wp->min; v <= wp->max + 0.5; v += 1) {
                char text[256] = {0};
                if (!params->value_to_text(p, info.id, v, text, sizeof text)) snprintf(text, sizeof text, "%g", v);
                wp_param_add_choice(wp, text, v);
            }
        }
    }
}

static void split_kind(const char *path, const char *id, char **out_path, char **out_id)
{
    *out_path = strdup(path);
    *out_id = strdup(id);
}

WpDesc **wp_clap_describe(const char *path, int *count)
{
    *count = 0;
    char err[256];
    ClapLib *lib = lib_acquire(path, err, sizeof err);
    if (!lib) return NULL;
    const clap_plugin_factory_t *f = lib->entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    WpDesc **out = NULL;
    if (f) {
        uint32_t n = f->get_plugin_count(f);
        for (uint32_t i = 0; i < n; i++) {
            const clap_plugin_descriptor_t *pd = f->get_plugin_descriptor(f, i);
            if (!pd || !pd->id) continue;
            WpDesc *d = wp_desc_new(WP_FORMAT_CLAP);
            char *p, *id;
            split_kind(path, pd->id, &p, &id);
            d->path = p;
            d->uri = id;
            d->binary = strdup(path);
            d->kind = wp_dup_printf("clap:%s#%s", path, pd->id);
            d->name = strdup(pd->name ? pd->name : pd->id);
            d->vendor = strdup(pd->vendor ? pd->vendor : "");
            clap_host_t host;
            host_init(&host, NULL);
            const clap_plugin_t *plug = f->create_plugin(f, &host, pd->id);
            if (plug) {
                if (plug->init(plug)) fill_desc(d, plug);
                plug->destroy(plug);
            }
            out = realloc(out, sizeof(WpDesc *) * (*count + 1));
            out[(*count)++] = d;
        }
    }
    lib_release(lib);
    return out;
}

typedef struct {
    WpDesc *desc;
    ClapLib *lib;
    const clap_plugin_t *p;
    const clap_plugin_params_t *params;
    const clap_plugin_latency_t *lat;
    const clap_plugin_state_t *state;
    clap_host_t host;
    int processing;
    int activated;
    int64_t steady;
    pthread_mutex_t lock;
    clap_event_param_value_t pending[MAX_EVENTS];
    int n_pending;
    clap_event_param_value_t events[MAX_EVENTS];
    int n_events;
    double *values;
    int *dirty;
    clap_input_events_t in_events;
    clap_output_events_t out_events;
} ClapUnit;

static uint32_t events_size(const clap_input_events_t *list)
{
    return (uint32_t) ((ClapUnit *) list->ctx)->n_events;
}

static const clap_event_header_t *events_get(const clap_input_events_t *list, uint32_t index)
{
    ClapUnit *u = list->ctx;
    if (index >= (uint32_t) u->n_events) return NULL;
    return &u->events[index].header;
}

static bool events_push(const clap_output_events_t *list, const clap_event_header_t *event)
{
    (void) list;
    (void) event;
    return true;
}

static void unit_free(ClapUnit *u)
{
    if (!u) return;
    if (u->p) {
        if (u->processing && u->p->stop_processing) u->p->stop_processing(u->p);
        if (u->activated && u->p->deactivate) u->p->deactivate(u->p);
        u->p->destroy(u->p);
    }
    if (u->lib) lib_release(u->lib);
    pthread_mutex_destroy(&u->lock);
    free(u->values);
    free(u->dirty);
    free(u);
}

static WpUnit *clap_create(WpDesc *desc, int rate, int max_block, char *err, size_t errlen)
{
    ClapUnit *u = calloc(1, sizeof(ClapUnit));
    pthread_mutex_init(&u->lock, NULL);
    u->desc = desc;
    u->lib = lib_acquire(desc->binary, err, errlen);
    if (!u->lib) {
        unit_free(u);
        return NULL;
    }
    const clap_plugin_factory_t *f = u->lib->entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
    if (!f) {
        snprintf(err, errlen, "The CLAP library has no plugin factory");
        unit_free(u);
        return NULL;
    }
    host_init(&u->host, u);
    u->p = f->create_plugin(f, &u->host, desc->uri);
    if (!u->p) {
        snprintf(err, errlen, "The library does not provide %s", desc->uri);
        unit_free(u);
        return NULL;
    }
    if (!u->p->init(u->p)) {
        snprintf(err, errlen, "The plugin refused to start");
        u->p->destroy(u->p);
        u->p = NULL;
        unit_free(u);
        return NULL;
    }
    u->params = u->p->get_extension(u->p, CLAP_EXT_PARAMS);
    u->lat = u->p->get_extension(u->p, CLAP_EXT_LATENCY);
    u->state = u->p->get_extension(u->p, CLAP_EXT_STATE);
    if (!u->p->activate(u->p, rate, 1, (uint32_t) max_block)) {
        snprintf(err, errlen, "The plugin could not be activated");
        unit_free(u);
        return NULL;
    }
    u->activated = 1;
    u->values = calloc(desc->n_params ? desc->n_params : 1, sizeof(double));
    u->dirty = calloc(desc->n_params ? desc->n_params : 1, sizeof(int));
    for (int i = 0; i < desc->n_params; i++) {
        double v = desc->params[i].def;
        if (u->params && u->params->get_value) u->params->get_value(u->p, desc->params[i].clap_id, &v);
        u->values[i] = v;
    }
    u->in_events.ctx = u;
    u->in_events.size = events_size;
    u->in_events.get = events_get;
    u->out_events.ctx = u;
    u->out_events.try_push = events_push;
    return (WpUnit *) u;
}

static void clap_destroy(WpUnit *unit)
{
    unit_free((ClapUnit *) unit);
}

static void clap_set_param(WpUnit *unit, int index, double value)
{
    ClapUnit *u = (ClapUnit *) unit;
    if (index < 0 || index >= u->desc->n_params) return;
    pthread_mutex_lock(&u->lock);
    u->values[index] = value;
    u->dirty[index] = 1;
    clap_id id = u->desc->params[index].clap_id;
    int slot = -1;
    for (int i = 0; i < u->n_pending; i++) {
        if (u->pending[i].param_id == id) slot = i;
    }
    if (slot < 0 && u->n_pending < MAX_EVENTS) slot = u->n_pending++;
    if (slot >= 0) {
        clap_event_param_value_t *e = &u->pending[slot];
        memset(e, 0, sizeof(*e));
        e->header.size = sizeof(*e);
        e->header.time = 0;
        e->header.space_id = CLAP_CORE_EVENT_SPACE_ID;
        e->header.type = CLAP_EVENT_PARAM_VALUE;
        e->param_id = id;
        e->note_id = -1;
        e->port_index = -1;
        e->channel = -1;
        e->key = -1;
        e->value = value;
    }
    pthread_mutex_unlock(&u->lock);
}

static double clap_get_param(WpUnit *unit, int index)
{
    ClapUnit *u = (ClapUnit *) unit;
    if (index < 0 || index >= u->desc->n_params) return 0;
    pthread_mutex_lock(&u->lock);
    double v = u->values[index];
    int dirty = u->dirty[index];
    pthread_mutex_unlock(&u->lock);
    if (!dirty && u->params && u->params->get_value) {
        double q;
        if (u->params->get_value(u->p, u->desc->params[index].clap_id, &q)) v = q;
    }
    return v;
}

static void clap_run(WpUnit *unit, float **in, float **out, int frames)
{
    ClapUnit *u = (ClapUnit *) unit;
    pthread_mutex_lock(&u->lock);
    memcpy(u->events, u->pending, sizeof(clap_event_param_value_t) * u->n_pending);
    u->n_events = u->n_pending;
    u->n_pending = 0;
    for (int i = 0; i < u->desc->n_params; i++) u->dirty[i] = 0;
    pthread_mutex_unlock(&u->lock);
    if (!u->processing && u->p->start_processing) {
        if (!u->p->start_processing(u->p)) {
            for (int i = 0; i < u->desc->n_out; i++) memset(out[i], 0, sizeof(float) * frames);
            return;
        }
    }
    u->processing = 1;
    clap_audio_buffer_t ib, ob;
    memset(&ib, 0, sizeof ib);
    memset(&ob, 0, sizeof ob);
    ib.data32 = in;
    ib.channel_count = (uint32_t) u->desc->n_in;
    ob.data32 = out;
    ob.channel_count = (uint32_t) u->desc->n_out;
    clap_process_t pr;
    memset(&pr, 0, sizeof pr);
    pr.steady_time = u->steady;
    pr.frames_count = (uint32_t) frames;
    pr.audio_inputs = u->desc->n_in ? &ib : NULL;
    pr.audio_inputs_count = u->desc->n_in ? 1 : 0;
    pr.audio_outputs = u->desc->n_out ? &ob : NULL;
    pr.audio_outputs_count = u->desc->n_out ? 1 : 0;
    pr.in_events = &u->in_events;
    pr.out_events = &u->out_events;
    u->p->process(u->p, &pr);
    u->steady += frames;
    u->n_events = 0;
}

static int clap_latency(WpUnit *unit)
{
    ClapUnit *u = (ClapUnit *) unit;
    return u->lat && u->lat->get ? (int) u->lat->get(u->p) : 0;
}

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
    size_t pos;
} Stream;

static int64_t stream_write(const clap_ostream_t *s, const void *buffer, uint64_t size)
{
    Stream *st = s->ctx;
    if (st->len + size > st->cap) {
        size_t cap = st->cap ? st->cap : 1024;
        while (cap < st->len + size) cap *= 2;
        st->data = realloc(st->data, cap);
        st->cap = cap;
    }
    memcpy(st->data + st->len, buffer, size);
    st->len += size;
    return (int64_t) size;
}

static int64_t stream_read(const clap_istream_t *s, void *buffer, uint64_t size)
{
    Stream *st = s->ctx;
    size_t left = st->len - st->pos;
    size_t n = size < left ? size : left;
    memcpy(buffer, st->data + st->pos, n);
    st->pos += n;
    return (int64_t) n;
}

static int clap_save_state(WpUnit *unit, uint8_t **data, size_t *len)
{
    ClapUnit *u = (ClapUnit *) unit;
    *data = NULL;
    *len = 0;
    if (!u->state || !u->state->save) return -1;
    Stream st = {0};
    clap_ostream_t os = { &st, stream_write };
    if (!u->state->save(u->p, &os)) {
        free(st.data);
        return -1;
    }
    *data = st.data;
    *len = st.len;
    return 0;
}

static int clap_load_state(WpUnit *unit, const uint8_t *data, size_t len)
{
    ClapUnit *u = (ClapUnit *) unit;
    if (!u->state || !u->state->load) return -1;
    Stream st = { (uint8_t *) data, len, len, 0 };
    clap_istream_t is = { &st, stream_read };
    if (!u->state->load(u->p, &is)) return -1;
    pthread_mutex_lock(&u->lock);
    for (int i = 0; i < u->desc->n_params; i++) {
        double v;
        if (u->params && u->params->get_value && u->params->get_value(u->p, u->desc->params[i].clap_id, &v)) u->values[i] = v;
        u->dirty[i] = 0;
    }
    u->n_pending = 0;
    pthread_mutex_unlock(&u->lock);
    return 0;
}

const WpBackend wp_clap_backend = {
    clap_create,
    clap_destroy,
    clap_set_param,
    clap_get_param,
    clap_run,
    clap_latency,
    clap_save_state,
    clap_load_state
};
