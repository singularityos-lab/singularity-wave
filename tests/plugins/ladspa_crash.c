#include "abi_ladspa.h"

#include <stdlib.h>

typedef struct {
    LADSPA_Data *ports[4];
} Crash;

static const LADSPA_PortDescriptor port_desc[] = {
    LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL,
    LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL,
    LADSPA_PORT_INPUT | LADSPA_PORT_AUDIO,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO
};

static const char *const port_names[] = { "Gain", "Crash", "In", "Out" };

static const LADSPA_PortRangeHint hints[] = {
    { LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_1, 0, 4 },
    { LADSPA_HINT_TOGGLED | LADSPA_HINT_DEFAULT_0, 0, 1 },
    { 0, 0, 0 },
    { 0, 0, 0 }
};

static LADSPA_Handle instantiate(const LADSPA_Descriptor *d, unsigned long rate)
{
    (void) d;
    (void) rate;
    return calloc(1, sizeof(Crash));
}

static void connect_port(LADSPA_Handle h, unsigned long port, LADSPA_Data *data)
{
    if (port < 4) ((Crash *) h)->ports[port] = data;
}

static void run(LADSPA_Handle h, unsigned long n)
{
    Crash *c = h;
    if (*c->ports[1] > 0.5f) {
        volatile int *nowhere = NULL;
        *nowhere = 1;
    }
    for (unsigned long i = 0; i < n; i++) c->ports[3][i] = c->ports[2][i] * *c->ports[0];
}

static void cleanup(LADSPA_Handle h)
{
    free(h);
}

static const LADSPA_Descriptor descriptor = {
    4243,
    "wave_test_crash",
    0,
    "Wave Test Crash",
    "Singularity",
    "GPL-3.0-only",
    4,
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
