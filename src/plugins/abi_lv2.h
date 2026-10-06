#ifndef WAVE_ABI_LV2_H
#define WAVE_ABI_LV2_H

#include <stdint.h>
#include <stdarg.h>

typedef void *LV2_Handle;

typedef struct {
    const char *URI;
    void *data;
} LV2_Feature;

typedef struct LV2_Descriptor {
    const char *URI;
    LV2_Handle (*instantiate)(const struct LV2_Descriptor *descriptor, double sample_rate, const char *bundle_path, const LV2_Feature *const *features);
    void (*connect_port)(LV2_Handle instance, uint32_t port, void *data_location);
    void (*activate)(LV2_Handle instance);
    void (*run)(LV2_Handle instance, uint32_t sample_count);
    void (*deactivate)(LV2_Handle instance);
    void (*cleanup)(LV2_Handle instance);
    const void *(*extension_data)(const char *uri);
} LV2_Descriptor;

typedef const LV2_Descriptor *(*LV2_Descriptor_Function)(uint32_t index);

typedef uint32_t LV2_URID;

typedef struct {
    void *handle;
    LV2_URID (*map)(void *handle, const char *uri);
} LV2_URID_Map;

typedef struct {
    void *handle;
    const char *(*unmap)(void *handle, LV2_URID urid);
} LV2_URID_Unmap;

typedef struct {
    int32_t context;
    uint32_t subject;
    LV2_URID key;
    uint32_t size;
    LV2_URID type;
    const void *value;
} LV2_Options_Option;

typedef struct {
    uint32_t size;
    uint32_t type;
} LV2_Atom;

typedef struct {
    uint32_t unit;
    uint32_t pad;
} LV2_Atom_Sequence_Body;

typedef struct {
    LV2_Atom atom;
    LV2_Atom_Sequence_Body body;
} LV2_Atom_Sequence;

typedef struct {
    void *handle;
    int (*printf)(void *handle, LV2_URID type, const char *fmt, ...);
    int (*vprintf)(void *handle, LV2_URID type, const char *fmt, va_list ap);
} LV2_Log_Log;

typedef void *LV2UI_Handle;
typedef void *LV2UI_Widget;
typedef void *LV2UI_Controller;

typedef void (*LV2UI_Write_Function)(LV2UI_Controller controller, uint32_t port_index, uint32_t buffer_size, uint32_t port_protocol, const void *buffer);

typedef struct LV2UI_Descriptor {
    const char *URI;
    LV2UI_Handle (*instantiate)(const struct LV2UI_Descriptor *descriptor, const char *plugin_uri, const char *bundle_path, LV2UI_Write_Function write_function, LV2UI_Controller controller, LV2UI_Widget *widget, const LV2_Feature *const *features);
    void (*cleanup)(LV2UI_Handle ui);
    void (*port_event)(LV2UI_Handle ui, uint32_t port_index, uint32_t buffer_size, uint32_t format, const void *buffer);
    const void *(*extension_data)(const char *uri);
} LV2UI_Descriptor;

typedef const LV2UI_Descriptor *(*LV2UI_DescriptorFunction)(uint32_t index);

typedef struct LV2_External_UI_Widget {
    void (*run)(struct LV2_External_UI_Widget *widget);
    void (*show)(struct LV2_External_UI_Widget *widget);
    void (*hide)(struct LV2_External_UI_Widget *widget);
} LV2_External_UI_Widget;

typedef struct {
    void (*ui_closed)(LV2UI_Controller controller);
    const char *plugin_human_id;
} LV2_External_UI_Host;

#define WAVE_LV2_CORE "http://lv2plug.in/ns/lv2core#"
#define WAVE_LV2_ATOM "http://lv2plug.in/ns/ext/atom#"
#define WAVE_LV2_UI "http://lv2plug.in/ns/extensions/ui#"
#define WAVE_LV2_KX_UI "http://kxstudio.sf.net/ns/lv2ext/external-ui#"
#define WAVE_LV2_PSET "http://lv2plug.in/ns/ext/presets#"
#define WAVE_RDF "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
#define WAVE_RDFS "http://www.w3.org/2000/01/rdf-schema#"
#define WAVE_DOAP "http://usefulinc.com/ns/doap#"
#define WAVE_FOAF "http://xmlns.com/foaf/0.1/"

#endif
