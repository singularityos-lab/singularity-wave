#ifndef WAVE_ABI_CLAP_H
#define WAVE_ABI_CLAP_H

#include <stdbool.h>
#include <stdint.h>

#define CLAP_NAME_SIZE 256
#define CLAP_PATH_SIZE 1024
#define CLAP_INVALID_ID UINT32_MAX

typedef uint32_t clap_id;

typedef struct clap_version {
    uint32_t major;
    uint32_t minor;
    uint32_t revision;
} clap_version_t;

typedef struct clap_plugin_descriptor {
    clap_version_t clap_version;
    const char *id;
    const char *name;
    const char *vendor;
    const char *url;
    const char *manual_url;
    const char *support_url;
    const char *version;
    const char *description;
    const char *const *features;
} clap_plugin_descriptor_t;

typedef struct clap_host {
    clap_version_t clap_version;
    void *host_data;
    const char *name;
    const char *vendor;
    const char *url;
    const char *version;
    const void *(*get_extension)(const struct clap_host *host, const char *extension_id);
    void (*request_restart)(const struct clap_host *host);
    void (*request_process)(const struct clap_host *host);
    void (*request_callback)(const struct clap_host *host);
} clap_host_t;

typedef struct clap_event_header {
    uint32_t size;
    uint32_t time;
    uint16_t space_id;
    uint16_t type;
    uint32_t flags;
} clap_event_header_t;

#define CLAP_CORE_EVENT_SPACE_ID 0
#define CLAP_EVENT_PARAM_VALUE 5

typedef struct clap_event_param_value {
    clap_event_header_t header;
    clap_id param_id;
    void *cookie;
    int32_t note_id;
    int16_t port_index;
    int16_t channel;
    int16_t key;
    double value;
} clap_event_param_value_t;

typedef struct clap_input_events {
    void *ctx;
    uint32_t (*size)(const struct clap_input_events *list);
    const clap_event_header_t *(*get)(const struct clap_input_events *list, uint32_t index);
} clap_input_events_t;

typedef struct clap_output_events {
    void *ctx;
    bool (*try_push)(const struct clap_output_events *list, const clap_event_header_t *event);
} clap_output_events_t;

typedef struct clap_audio_buffer {
    float **data32;
    double **data64;
    uint32_t channel_count;
    uint32_t latency;
    uint64_t constant_mask;
} clap_audio_buffer_t;

typedef struct clap_process {
    int64_t steady_time;
    uint32_t frames_count;
    const void *transport;
    const clap_audio_buffer_t *audio_inputs;
    clap_audio_buffer_t *audio_outputs;
    uint32_t audio_inputs_count;
    uint32_t audio_outputs_count;
    const clap_input_events_t *in_events;
    const clap_output_events_t *out_events;
} clap_process_t;

typedef int32_t clap_process_status;

enum {
    CLAP_PROCESS_ERROR = 0,
    CLAP_PROCESS_CONTINUE = 1,
    CLAP_PROCESS_CONTINUE_IF_NOT_QUIET = 2,
    CLAP_PROCESS_TAIL = 3,
    CLAP_PROCESS_SLEEP = 4
};

typedef struct clap_plugin {
    const clap_plugin_descriptor_t *desc;
    void *plugin_data;
    bool (*init)(const struct clap_plugin *plugin);
    void (*destroy)(const struct clap_plugin *plugin);
    bool (*activate)(const struct clap_plugin *plugin, double sample_rate, uint32_t min_frames_count, uint32_t max_frames_count);
    void (*deactivate)(const struct clap_plugin *plugin);
    bool (*start_processing)(const struct clap_plugin *plugin);
    void (*stop_processing)(const struct clap_plugin *plugin);
    void (*reset)(const struct clap_plugin *plugin);
    clap_process_status (*process)(const struct clap_plugin *plugin, const clap_process_t *process);
    const void *(*get_extension)(const struct clap_plugin *plugin, const char *id);
    void (*on_main_thread)(const struct clap_plugin *plugin);
} clap_plugin_t;

#define CLAP_PLUGIN_FACTORY_ID "clap.plugin-factory"

typedef struct clap_plugin_factory {
    uint32_t (*get_plugin_count)(const struct clap_plugin_factory *factory);
    const clap_plugin_descriptor_t *(*get_plugin_descriptor)(const struct clap_plugin_factory *factory, uint32_t index);
    const clap_plugin_t *(*create_plugin)(const struct clap_plugin_factory *factory, const clap_host_t *host, const char *plugin_id);
} clap_plugin_factory_t;

typedef struct clap_plugin_entry {
    clap_version_t clap_version;
    bool (*init)(const char *plugin_path);
    void (*deinit)(void);
    const void *(*get_factory)(const char *factory_id);
} clap_plugin_entry_t;

#define CLAP_EXT_PARAMS "clap.params"

enum {
    CLAP_PARAM_IS_STEPPED = 1 << 0,
    CLAP_PARAM_IS_PERIODIC = 1 << 1,
    CLAP_PARAM_IS_HIDDEN = 1 << 2,
    CLAP_PARAM_IS_READONLY = 1 << 3,
    CLAP_PARAM_IS_BYPASS = 1 << 4,
    CLAP_PARAM_IS_AUTOMATABLE = 1 << 5,
    CLAP_PARAM_IS_ENUM = 1 << 16
};

typedef struct clap_param_info {
    clap_id id;
    uint32_t flags;
    void *cookie;
    char name[CLAP_NAME_SIZE];
    char module[CLAP_PATH_SIZE];
    double min_value;
    double max_value;
    double default_value;
} clap_param_info_t;

typedef struct clap_plugin_params {
    uint32_t (*count)(const clap_plugin_t *plugin);
    bool (*get_info)(const clap_plugin_t *plugin, uint32_t param_index, clap_param_info_t *param_info);
    bool (*get_value)(const clap_plugin_t *plugin, clap_id param_id, double *out_value);
    bool (*value_to_text)(const clap_plugin_t *plugin, clap_id param_id, double value, char *out_buffer, uint32_t out_buffer_capacity);
    bool (*text_to_value)(const clap_plugin_t *plugin, clap_id param_id, const char *param_value_text, double *out_value);
    void (*flush)(const clap_plugin_t *plugin, const clap_input_events_t *in, const clap_output_events_t *out);
} clap_plugin_params_t;

#define CLAP_EXT_AUDIO_PORTS "clap.audio-ports"

typedef struct clap_audio_port_info {
    clap_id id;
    char name[CLAP_NAME_SIZE];
    uint32_t flags;
    uint32_t channel_count;
    const char *port_type;
    clap_id in_place_pair;
} clap_audio_port_info_t;

typedef struct clap_plugin_audio_ports {
    uint32_t (*count)(const clap_plugin_t *plugin, bool is_input);
    bool (*get)(const clap_plugin_t *plugin, uint32_t index, bool is_input, clap_audio_port_info_t *info);
} clap_plugin_audio_ports_t;

#define CLAP_EXT_LATENCY "clap.latency"

typedef struct clap_plugin_latency {
    uint32_t (*get)(const clap_plugin_t *plugin);
} clap_plugin_latency_t;

#define CLAP_EXT_STATE "clap.state"

typedef struct clap_ostream {
    void *ctx;
    int64_t (*write)(const struct clap_ostream *stream, const void *buffer, uint64_t size);
} clap_ostream_t;

typedef struct clap_istream {
    void *ctx;
    int64_t (*read)(const struct clap_istream *stream, void *buffer, uint64_t size);
} clap_istream_t;

typedef struct clap_plugin_state {
    bool (*save)(const clap_plugin_t *plugin, const clap_ostream_t *stream);
    bool (*load)(const clap_plugin_t *plugin, const clap_istream_t *stream);
} clap_plugin_state_t;

#endif
