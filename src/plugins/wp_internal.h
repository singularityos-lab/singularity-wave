#ifndef WAVE_WP_INTERNAL_H
#define WAVE_WP_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

enum {
    WP_FORMAT_LV2,
    WP_FORMAT_LADSPA,
    WP_FORMAT_CLAP
};

enum {
    WP_PORT_AUDIO_IN,
    WP_PORT_AUDIO_OUT,
    WP_PORT_CONTROL_IN,
    WP_PORT_CONTROL_OUT,
    WP_PORT_ATOM_IN,
    WP_PORT_ATOM_OUT,
    WP_PORT_CV_IN,
    WP_PORT_CV_OUT,
    WP_PORT_OTHER
};

typedef struct {
    char *id;
    char *label;
    double min;
    double max;
    double def;
    int toggle;
    int logarithmic;
    int integer;
    int n_choices;
    char **choice_labels;
    double *choice_values;
    int port;
    uint32_t clap_id;
} WpParam;

typedef struct {
    int format;
    char *kind;
    char *name;
    char *vendor;
    char *path;
    char *uri;
    char *binary;
    char *bundle;
    unsigned long ladspa_id;
    int n_in;
    int n_out;
    int *in_ports;
    int *out_ports;
    int n_params;
    WpParam *params;
    int n_ports;
    int *port_kind;
    float *port_default;
    int latency_port;
    char *ui_uri;
    char *ui_binary;
    char *ui_bundle;
    char *unsupported;
} WpDesc;

typedef struct WpUnit WpUnit;

typedef void (*WpUiWrite)(void *ctx, int param_index, double value);

typedef struct {
    WpUnit *(*create)(WpDesc *desc, int rate, int max_block, char *err, size_t errlen);
    void (*destroy)(WpUnit *u);
    void (*set_param)(WpUnit *u, int index, double value);
    double (*get_param)(WpUnit *u, int index);
    void (*run)(WpUnit *u, float **in, float **out, int frames);
    int (*latency)(WpUnit *u);
    int (*save_state)(WpUnit *u, uint8_t **data, size_t *len);
    int (*load_state)(WpUnit *u, const uint8_t *data, size_t len);
} WpBackend;

extern const WpBackend wp_lv2_backend;
extern const WpBackend wp_ladspa_backend;
extern const WpBackend wp_clap_backend;

WpDesc **wp_lv2_describe(const char *bundle, int *count);
WpDesc **wp_ladspa_describe(const char *path, int *count);
WpDesc **wp_clap_describe(const char *path, int *count);

int wp_lv2_ui_show(WpUnit *u, int show, WpUiWrite write, void *ctx, char *err, size_t errlen);
void wp_lv2_ui_idle(WpUnit *u);
void wp_lv2_ui_port_event(WpUnit *u, int param_index, double value);
int wp_lv2_ui_visible(WpUnit *u);

WpDesc *wp_desc_new(int format);
void wp_desc_free(WpDesc *d);
void wp_desc_list_free(WpDesc **list, int count);
WpParam *wp_desc_add_param(WpDesc *d);
void wp_param_add_choice(WpParam *p, const char *label, double value);

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} WpStr;

void wp_str_add(WpStr *s, const char *text);
void wp_str_addf(WpStr *s, const char *fmt, ...);
void wp_str_add_json(WpStr *s, const char *text);
void wp_str_add_double(WpStr *s, double v);
void wp_desc_to_json(WpDesc *d, WpStr *s);

double wp_strtod(const char *text);
char *wp_dup_printf(const char *fmt, ...);
int wp_has_suffix(const char *s, const char *suffix);

typedef struct WpPlugin WpPlugin;

WpDesc **wp_describe(int format, const char *path, int *count);
WpDesc *wp_find_desc(const char *kind, const char *path, char *err, size_t errlen);
WpPlugin *wp_plugin_open(const char *kind, const char *path, int rate, int channels, int max_block, char *err, size_t errlen);
void wp_plugin_free(WpPlugin *p);
WpDesc *wp_plugin_desc(WpPlugin *p);
void wp_plugin_set_param(WpPlugin *p, int index, double value);
double wp_plugin_get_param(WpPlugin *p, int index);
int wp_plugin_latency(WpPlugin *p);
void wp_plugin_run_interleaved(WpPlugin *p, float *buf, int frames);
int wp_plugin_save_state(WpPlugin *p, uint8_t **data, size_t *len);
int wp_plugin_load_state(WpPlugin *p, const uint8_t *data, size_t len);
int wp_plugin_has_ui(WpPlugin *p);
int wp_plugin_show_ui(WpPlugin *p, int show, char *err, size_t errlen);
int wp_plugin_ui_visible(WpPlugin *p);
void wp_plugin_ui_idle(WpPlugin *p);
char *wp_candidates_json(void);
char *wp_scan_json(const char *format, const char *path);

#endif
