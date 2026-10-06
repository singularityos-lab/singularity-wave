#ifndef WAVEPLUG_H
#define WAVEPLUG_H

#include <stddef.h>
#include <stdint.h>

typedef struct _WpInstance WpInstance;

WpInstance *wp_instance_open(const char *kind, const char *path, int rate, int channels, int max_block, int isolated, char **error);
void wp_instance_free(WpInstance *i);
int wp_instance_process(WpInstance *i, float *buf, int frames);
int wp_instance_param_count(WpInstance *i);
void wp_instance_set_param(WpInstance *i, int index, double value);
double wp_instance_get_param(WpInstance *i, int index);
int wp_instance_sync_params(WpInstance *i, double *values, int n);
int wp_instance_latency(WpInstance *i);
int wp_instance_alive(WpInstance *i);
int wp_instance_is_isolated(WpInstance *i);
int wp_instance_restart(WpInstance *i, char **error);
char *wp_instance_take_crash(WpInstance *i);
int wp_instance_save_state(WpInstance *i, uint8_t **data, size_t *len);
int wp_instance_load_state(WpInstance *i, const uint8_t *data, size_t len);
int wp_instance_has_native_ui(WpInstance *i);
int wp_instance_show_native_ui(WpInstance *i, int show, char **error);
int wp_instance_native_ui_visible(WpInstance *i);
void wp_instance_idle(WpInstance *i);
int wp_instance_pid(WpInstance *i);
char *wp_candidates(void);
char *wp_scan_isolated(const char *format, const char *path, int timeout_ms, char **error);
char *wp_lv2_presets_json(const char *uri);
const char *wp_helper_path(void);

#endif
