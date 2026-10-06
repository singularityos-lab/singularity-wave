#include "abi_clap.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    clap_plugin_t plugin;
    const clap_host_t *host;
    double gain;
    double mode;
    int active;
    int processing;
} Gain;

static const char *const features[] = { "audio-effect", NULL };

static const clap_plugin_descriptor_t descriptor = {
    { 1, 2, 0 },
    "dev.sinty.wave.test.gain",
    "Wave Test Gain (CLAP)",
    "Singularity",
    "",
    "",
    "",
    "1.0.0",
    "Gain used by the Wave plugin host tests",
    features
};

static bool init(const clap_plugin_t *p)
{
    (void) p;
    return true;
}

static void destroy(const clap_plugin_t *p)
{
    free(p->plugin_data);
}

static bool activate(const clap_plugin_t *p, double rate, uint32_t min_frames, uint32_t max_frames)
{
    (void) rate;
    (void) min_frames;
    (void) max_frames;
    ((Gain *) p->plugin_data)->active = 1;
    return true;
}

static void deactivate(const clap_plugin_t *p)
{
    ((Gain *) p->plugin_data)->active = 0;
}

static bool start_processing(const clap_plugin_t *p)
{
    ((Gain *) p->plugin_data)->processing = 1;
    return true;
}

static void stop_processing(const clap_plugin_t *p)
{
    ((Gain *) p->plugin_data)->processing = 0;
}

static void reset(const clap_plugin_t *p)
{
    (void) p;
}

static void apply_events(Gain *g, const clap_input_events_t *in)
{
    if (!in) return;
    uint32_t n = in->size(in);
    for (uint32_t i = 0; i < n; i++) {
        const clap_event_header_t *h = in->get(in, i);
        if (!h || h->space_id != CLAP_CORE_EVENT_SPACE_ID || h->type != CLAP_EVENT_PARAM_VALUE) continue;
        const clap_event_param_value_t *e = (const clap_event_param_value_t *) h;
        if (e->param_id == 7) g->gain = e->value;
        else if (e->param_id == 9) g->mode = e->value;
    }
}

static clap_process_status process(const clap_plugin_t *p, const clap_process_t *pr)
{
    Gain *g = p->plugin_data;
    if (!g->active || !g->processing) return CLAP_PROCESS_ERROR;
    apply_events(g, pr->in_events);
    if (pr->audio_inputs_count < 1 || pr->audio_outputs_count < 1) return CLAP_PROCESS_ERROR;
    const clap_audio_buffer_t *in = &pr->audio_inputs[0];
    clap_audio_buffer_t *out = &pr->audio_outputs[0];
    for (uint32_t c = 0; c < out->channel_count && c < in->channel_count; c++) {
        for (uint32_t i = 0; i < pr->frames_count; i++) out->data32[c][i] = (float) (in->data32[c][i] * g->gain);
    }
    return CLAP_PROCESS_CONTINUE;
}

static uint32_t params_count(const clap_plugin_t *p)
{
    (void) p;
    return 2;
}

static bool params_info(const clap_plugin_t *p, uint32_t index, clap_param_info_t *info)
{
    (void) p;
    memset(info, 0, sizeof(*info));
    if (index == 0) {
        info->id = 7;
        info->flags = CLAP_PARAM_IS_AUTOMATABLE;
        snprintf(info->name, sizeof info->name, "Gain");
        info->min_value = 0;
        info->max_value = 4;
        info->default_value = 1;
        return true;
    }
    if (index == 1) {
        info->id = 9;
        info->flags = CLAP_PARAM_IS_STEPPED | CLAP_PARAM_IS_ENUM;
        snprintf(info->name, sizeof info->name, "Mode");
        info->min_value = 0;
        info->max_value = 2;
        info->default_value = 0;
        return true;
    }
    return false;
}

static bool params_value(const clap_plugin_t *p, clap_id id, double *out)
{
    Gain *g = p->plugin_data;
    if (id == 7) *out = g->gain;
    else if (id == 9) *out = g->mode;
    else return false;
    return true;
}

static bool params_text(const clap_plugin_t *p, clap_id id, double value, char *out, uint32_t cap)
{
    (void) p;
    static const char *modes[] = { "Clean", "Warm", "Bright" };
    if (id == 9 && value >= 0 && value <= 2) {
        snprintf(out, cap, "%s", modes[(int) (value + 0.5)]);
        return true;
    }
    snprintf(out, cap, "%.2f", value);
    return true;
}

static bool params_parse(const clap_plugin_t *p, clap_id id, const char *text, double *out)
{
    (void) p;
    (void) id;
    *out = atof(text);
    return true;
}

static void params_flush(const clap_plugin_t *p, const clap_input_events_t *in, const clap_output_events_t *out)
{
    (void) out;
    apply_events(p->plugin_data, in);
}

static const clap_plugin_params_t params = { params_count, params_info, params_value, params_text, params_parse, params_flush };

static uint32_t ports_count(const clap_plugin_t *p, bool is_input)
{
    (void) p;
    (void) is_input;
    return 1;
}

static bool ports_get(const clap_plugin_t *p, uint32_t index, bool is_input, clap_audio_port_info_t *info)
{
    (void) p;
    if (index != 0) return false;
    memset(info, 0, sizeof(*info));
    info->id = is_input ? 0 : 1;
    snprintf(info->name, sizeof info->name, "%s", is_input ? "In" : "Out");
    info->channel_count = 2;
    info->port_type = "stereo";
    info->in_place_pair = CLAP_INVALID_ID;
    return true;
}

static const clap_plugin_audio_ports_t ports = { ports_count, ports_get };

static bool state_save(const clap_plugin_t *p, const clap_ostream_t *s)
{
    Gain *g = p->plugin_data;
    char text[128];
    int n = snprintf(text, sizeof text, "wave-test-gain %.17g %.17g", g->gain, g->mode);
    return s->write(s, text, (uint64_t) n) == n;
}

static bool state_load(const clap_plugin_t *p, const clap_istream_t *s)
{
    Gain *g = p->plugin_data;
    char text[128] = {0};
    int64_t n = s->read(s, text, sizeof text - 1);
    if (n <= 0) return false;
    double gain, mode;
    if (sscanf(text, "wave-test-gain %lf %lf", &gain, &mode) != 2) return false;
    g->gain = gain;
    g->mode = mode;
    return true;
}

static const clap_plugin_state_t state = { state_save, state_load };

static const void *get_extension(const clap_plugin_t *p, const char *id)
{
    (void) p;
    if (strcmp(id, CLAP_EXT_PARAMS) == 0) return &params;
    if (strcmp(id, CLAP_EXT_AUDIO_PORTS) == 0) return &ports;
    if (strcmp(id, CLAP_EXT_STATE) == 0) return &state;
    return NULL;
}

static void on_main_thread(const clap_plugin_t *p)
{
    (void) p;
}

static uint32_t factory_count(const clap_plugin_factory_t *f)
{
    (void) f;
    return 1;
}

static const clap_plugin_descriptor_t *factory_descriptor(const clap_plugin_factory_t *f, uint32_t index)
{
    (void) f;
    return index == 0 ? &descriptor : NULL;
}

static const clap_plugin_t *factory_create(const clap_plugin_factory_t *f, const clap_host_t *host, const char *id)
{
    (void) f;
    if (strcmp(id, descriptor.id) != 0) return NULL;
    Gain *g = calloc(1, sizeof(Gain));
    g->host = host;
    g->gain = 1;
    g->plugin.desc = &descriptor;
    g->plugin.plugin_data = g;
    g->plugin.init = init;
    g->plugin.destroy = destroy;
    g->plugin.activate = activate;
    g->plugin.deactivate = deactivate;
    g->plugin.start_processing = start_processing;
    g->plugin.stop_processing = stop_processing;
    g->plugin.reset = reset;
    g->plugin.process = process;
    g->plugin.get_extension = get_extension;
    g->plugin.on_main_thread = on_main_thread;
    return &g->plugin;
}

static const clap_plugin_factory_t factory = { factory_count, factory_descriptor, factory_create };

static bool entry_init(const char *path)
{
    (void) path;
    return true;
}

static void entry_deinit(void)
{
}

static const void *entry_factory(const char *id)
{
    return strcmp(id, CLAP_PLUGIN_FACTORY_ID) == 0 ? &factory : NULL;
}

const clap_plugin_entry_t clap_entry = { { 1, 2, 0 }, entry_init, entry_deinit, entry_factory };
