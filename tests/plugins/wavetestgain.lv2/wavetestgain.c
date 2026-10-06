#include "abi_lv2.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    const float *gain;
    const float *invert;
    const float *mode;
    const float *in;
    float *out;
    float *latency;
    const LV2_Atom_Sequence *control;
    uint32_t seq;
} Gain;

static LV2_Handle instantiate(const LV2_Descriptor *d, double rate, const char *bundle, const LV2_Feature *const *features)
{
    (void) d;
    (void) rate;
    (void) bundle;
    const LV2_URID_Map *map = NULL;
    for (int i = 0; features && features[i]; i++) {
        if (strcmp(features[i]->URI, "http://lv2plug.in/ns/ext/urid#map") == 0) map = features[i]->data;
    }
    if (!map) return NULL;
    Gain *g = calloc(1, sizeof(Gain));
    g->seq = map->map(map->handle, "http://lv2plug.in/ns/ext/atom#Sequence");
    return g;
}

static void connect_port(LV2_Handle h, uint32_t port, void *data)
{
    Gain *g = h;
    switch (port) {
    case 0: g->gain = data; break;
    case 1: g->invert = data; break;
    case 2: g->mode = data; break;
    case 3: g->in = data; break;
    case 4: g->out = data; break;
    case 5: g->latency = data; break;
    case 6: g->control = data; break;
    default: break;
    }
}

static void run(LV2_Handle h, uint32_t n)
{
    Gain *g = h;
    int valid = g->control && g->control->atom.type == g->seq;
    float k = *g->gain * (*g->invert > 0.5f ? -1.0f : 1.0f);
    for (uint32_t i = 0; i < n; i++) g->out[i] = valid ? g->in[i] * k : 0.0f;
    if (g->latency) *g->latency = 3.0f;
}

static void cleanup(LV2_Handle h)
{
    free(h);
}

static const LV2_Descriptor descriptor = {
    "urn:singularity:wave-test:gain",
    instantiate,
    connect_port,
    NULL,
    run,
    NULL,
    cleanup,
    NULL
};

const LV2_Descriptor *lv2_descriptor(uint32_t index)
{
    return index == 0 ? &descriptor : NULL;
}
