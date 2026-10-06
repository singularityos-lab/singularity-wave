#include "abi_ladspa.h"

#include <stdlib.h>

typedef struct {
    LADSPA_Data *ports[6];
} Gain;

static const LADSPA_PortDescriptor port_desc[] = {
    LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL,
    LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_CONTROL
};

static const char *const port_names[] = { "Gain", "In L", "In R", "Out L", "Out R", "latency" };

static const LADSPA_PortRangeHint hints[] = {
    { LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_1, 0, 4 },
    { 0, 0, 0 },
    { 0, 0, 0 },
    { 0, 0, 0 },
    { 0, 0, 0 },
    { 0, 0, 0 }
};

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate)
{
    (void) d;
    (void) rate;
    return calloc(1, sizeof(Gain));
}

static void connect_port(LADSPA_Handle h, unsigned long port, LADSPA_Data *data)
{
    if (port < 6) ((Gain *) h)->ports[port] = data;
}

static void run(LADSPA_Handle h, unsigned long n)
{
    Gain *g = h;
    float k = *g->ports[0];
    for (unsigned long i = 0; i < n; i++) {
        g->ports[3][i] = g->ports[1][i] * k;
        g->ports[4][i] = g->ports[2][i] * k;
    }
    *g->ports[5] = 0;
}

static void cleanup(LADSPA_Handle h)
{
    free(h);
}

static const LADSPA_Descriptor descriptor = {
    4242,
    "wave_test_gain",
    0,
    "Wave Test Gain (LADSPA)",
    "Singularity",
    "GPL-3.0-only",
    6,
    port_desc,
    port_names,
    hints,
    NULL,
    instantiate,
    connect_port,
    NULL,
    run,
    NULL,
    NULL,
    NULL,
    cleanup
};

const LADSPA_Descriptor *ladspa_descriptor(unsigned long index)
{
    return index == 0 ? &descriptor : NULL;
}
