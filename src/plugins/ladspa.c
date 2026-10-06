#define _GNU_SOURCE
#include "wp_internal.h"
#include "abi_ladspa.h"

#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double hint_default(const LADSPA_PortRangeHint *h, int rate)
{
    int d = h->HintDescriptor;
    double lo = h->LowerBound, hi = h->UpperBound;
    if (d & LADSPA_HINT_SAMPLE_RATE) {
        lo *= rate;
        hi *= rate;
    }
    int lg = (d & LADSPA_HINT_LOGARITHMIC) && lo > 0 && hi > 0;
    switch (d & LADSPA_HINT_DEFAULT_MASK) {
    case LADSPA_HINT_DEFAULT_MINIMUM: return lo;
    case LADSPA_HINT_DEFAULT_LOW: return lg ? exp(log(lo) * 0.75 + log(hi) * 0.25) : lo * 0.75 + hi * 0.25;
    case LADSPA_HINT_DEFAULT_MIDDLE: return lg ? exp(log(lo) * 0.5 + log(hi) * 0.5) : lo * 0.5 + hi * 0.5;
    case LADSPA_HINT_DEFAULT_HIGH: return lg ? exp(log(lo) * 0.25 + log(hi) * 0.75) : lo * 0.25 + hi * 0.75;
    case LADSPA_HINT_DEFAULT_MAXIMUM: return hi;
    case LADSPA_HINT_DEFAULT_0: return 0;
    case LADSPA_HINT_DEFAULT_1: return 1;
    case LADSPA_HINT_DEFAULT_100: return 100;
    case LADSPA_HINT_DEFAULT_440: return 440;
    default: break;
    }
    if (d & LADSPA_HINT_BOUNDED_BELOW) return lo;
    if (d & LADSPA_HINT_BOUNDED_ABOVE) return hi < 0 ? hi : 0;
    return 0;
}

static WpDesc *describe(const LADSPA_Descriptor *ld, const char *path)
{
    WpDesc *d = wp_desc_new(WP_FORMAT_LADSPA);
    d->ladspa_id = ld->UniqueID;
    d->kind = wp_dup_printf("ladspa:%s#%lu", path, ld->UniqueID);
    d->name = strdup(ld->Name ? ld->Name : (ld->Label ? ld->Label : "LADSPA"));
    d->vendor = strdup(ld->Maker ? ld->Maker : "");
    d->path = strdup(path);
    d->binary = strdup(path);
    d->n_ports = (int) ld->PortCount;
    d->port_kind = calloc(d->n_ports ? d->n_ports : 1, sizeof(int));
    d->port_default = calloc(d->n_ports ? d->n_ports : 1, sizeof(float));
    for (int i = 0; i < d->n_ports; i++) {
        int pd = ld->PortDescriptors[i];
        int input = (pd & LADSPA_PORT_INPUT) != 0;
        const char *pname = ld->PortNames && ld->PortNames[i] ? ld->PortNames[i] : "";
        if (pd & LADSPA_PORT_AUDIO) {
            d->port_kind[i] = input ? WP_PORT_AUDIO_IN : WP_PORT_AUDIO_OUT;
            if (input) {
                d->in_ports = realloc(d->in_ports, sizeof(int) * (d->n_in + 1));
                d->in_ports[d->n_in++] = i;
            } else {
                d->out_ports = realloc(d->out_ports, sizeof(int) * (d->n_out + 1));
                d->out_ports[d->n_out++] = i;
            }
        } else if (pd & LADSPA_PORT_CONTROL) {
            d->port_kind[i] = input ? WP_PORT_CONTROL_IN : WP_PORT_CONTROL_OUT;
            if (!input) {
                if (strcasecmp(pname, "latency") == 0 || strcasecmp(pname, "_latency") == 0) d->latency_port = i;
                continue;
            }
            const LADSPA_PortRangeHint *h = &ld->PortRangeHints[i];
            WpParam *p = wp_desc_add_param(d);
            p->port = i;
            p->id = wp_dup_printf("%d", i);
            p->label = strdup(pname);
            int hd = h->HintDescriptor;
            p->toggle = (hd & LADSPA_HINT_TOGGLED) != 0;
            p->integer = (hd & LADSPA_HINT_INTEGER) != 0;
            p->logarithmic = (hd & LADSPA_HINT_LOGARITHMIC) != 0;
            double lo = (hd & LADSPA_HINT_BOUNDED_BELOW) ? h->LowerBound : 0;
            double hi = (hd & LADSPA_HINT_BOUNDED_ABOVE) ? h->UpperBound : (lo + 1);
            if (hd & LADSPA_HINT_SAMPLE_RATE) {
                lo *= 48000;
                hi *= 48000;
            }
            if (p->toggle) {
                lo = 0;
                hi = 1;
            }
            if (hi < lo) {
                double t = hi;
                hi = lo;
                lo = t;
            }
            p->min = lo;
            p->max = hi;
            p->def = hint_default(h, 48000);
            if (p->def < lo) p->def = lo;
            if (p->def > hi) p->def = hi;
            d->port_default[i] = (float) p->def;
        } else {
            d->port_kind[i] = WP_PORT_OTHER;
        }
    }
    return d;
}

WpDesc **wp_ladspa_describe(const char *path, int *count)
{
    *count = 0;
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) return NULL;
    LADSPA_Descriptor_Function fn = (LADSPA_Descriptor_Function) dlsym(lib, "ladspa_descriptor");
    if (!fn) {
        dlclose(lib);
        return NULL;
    }
    WpDesc **out = NULL;
    for (unsigned long i = 0;; i++) {
        const LADSPA_Descriptor *ld = fn(i);
        if (!ld) break;
        out = realloc(out, sizeof(WpDesc *) * (*count + 1));
        out[(*count)++] = describe(ld, path);
    }
    dlclose(lib);
    return out;
}

typedef struct {
    WpDesc *desc;
    void *lib;
    const LADSPA_Descriptor *d;
    LADSPA_Handle h;
    float *controls;
    float **audio;
    float dummy;
} LadspaUnit;

static void unit_free(LadspaUnit *u)
{
    if (!u) return;
    if (u->h) {
        if (u->d->deactivate) u->d->deactivate(u->h);
        if (u->d->cleanup) u->d->cleanup(u->h);
    }
    if (u->lib) dlclose(u->lib);
    if (u->audio) {
        for (int i = 0; i < u->desc->n_ports; i++) free(u->audio[i]);
    }
    free(u->audio);
    free(u->controls);
    free(u);
}

static WpUnit *ladspa_create(WpDesc *desc, int rate, int max_block, char *err, size_t errlen)
{
    LadspaUnit *u = calloc(1, sizeof(LadspaUnit));
    u->desc = desc;
    u->lib = dlopen(desc->binary, RTLD_NOW | RTLD_LOCAL);
    if (!u->lib) {
        snprintf(err, errlen, "%s", dlerror());
        unit_free(u);
        return NULL;
    }
    LADSPA_Descriptor_Function fn = (LADSPA_Descriptor_Function) dlsym(u->lib, "ladspa_descriptor");
    if (!fn) {
        snprintf(err, errlen, "The library has no ladspa_descriptor");
        unit_free(u);
        return NULL;
    }
    for (unsigned long i = 0;; i++) {
        const LADSPA_Descriptor *ld = fn(i);
        if (!ld) break;
        if (ld->UniqueID == desc->ladspa_id) {
            u->d = ld;
            break;
        }
    }
    if (!u->d) {
        snprintf(err, errlen, "The library does not provide plugin %lu", desc->ladspa_id);
        unit_free(u);
        return NULL;
    }
    u->h = u->d->instantiate(u->d, (unsigned long) rate);
    if (!u->h) {
        snprintf(err, errlen, "The plugin refused to start");
        unit_free(u);
        return NULL;
    }
    int n = desc->n_ports;
    u->controls = calloc(n ? n : 1, sizeof(float));
    u->audio = calloc(n ? n : 1, sizeof(float *));
    for (int i = 0; i < n; i++) {
        int k = desc->port_kind[i];
        u->controls[i] = desc->port_default[i];
        if (k == WP_PORT_AUDIO_IN || k == WP_PORT_AUDIO_OUT) {
            u->audio[i] = calloc(max_block, sizeof(float));
            u->d->connect_port(u->h, i, u->audio[i]);
        } else if (k == WP_PORT_CONTROL_IN || k == WP_PORT_CONTROL_OUT) {
            u->d->connect_port(u->h, i, &u->controls[i]);
        } else {
            u->d->connect_port(u->h, i, &u->dummy);
        }
    }
    if (u->d->activate) u->d->activate(u->h);
    return (WpUnit *) u;
}

static void ladspa_destroy(WpUnit *unit)
{
    unit_free((LadspaUnit *) unit);
}

static void ladspa_set_param(WpUnit *unit, int index, double value)
{
    LadspaUnit *u = (LadspaUnit *) unit;
    if (index < 0 || index >= u->desc->n_params) return;
    u->controls[u->desc->params[index].port] = (float) value;
}

static double ladspa_get_param(WpUnit *unit, int index)
{
    LadspaUnit *u = (LadspaUnit *) unit;
    if (index < 0 || index >= u->desc->n_params) return 0;
    return u->controls[u->desc->params[index].port];
}

static void ladspa_run(WpUnit *unit, float **in, float **out, int frames)
{
    LadspaUnit *u = (LadspaUnit *) unit;
    WpDesc *d = u->desc;
    for (int i = 0; i < d->n_in; i++) memcpy(u->audio[d->in_ports[i]], in[i], sizeof(float) * frames);
    u->d->run(u->h, (unsigned long) frames);
    for (int i = 0; i < d->n_out; i++) memcpy(out[i], u->audio[d->out_ports[i]], sizeof(float) * frames);
}

static int ladspa_latency(WpUnit *unit)
{
    LadspaUnit *u = (LadspaUnit *) unit;
    if (u->desc->latency_port < 0) return 0;
    float v = u->controls[u->desc->latency_port];
    return v > 0 ? (int) (v + 0.5f) : 0;
}

static int ladspa_save_state(WpUnit *unit, uint8_t **data, size_t *len)
{
    (void) unit;
    *data = NULL;
    *len = 0;
    return -1;
}

static int ladspa_load_state(WpUnit *unit, const uint8_t *data, size_t len)
{
    (void) unit;
    (void) data;
    (void) len;
    return -1;
}

const WpBackend wp_ladspa_backend = {
    ladspa_create,
    ladspa_destroy,
    ladspa_set_param,
    ladspa_get_param,
    ladspa_run,
    ladspa_latency,
    ladspa_save_state,
    ladspa_load_state
};
