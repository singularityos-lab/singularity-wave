#ifndef WAVE_ABI_LADSPA_H
#define WAVE_ABI_LADSPA_H

typedef float LADSPA_Data;
typedef void *LADSPA_Handle;
typedef int LADSPA_Properties;
typedef int LADSPA_PortDescriptor;
typedef int LADSPA_PortRangeHintDescriptor;

typedef struct {
    LADSPA_PortRangeHintDescriptor HintDescriptor;
    LADSPA_Data LowerBound;
    LADSPA_Data UpperBound;
} LADSPA_PortRangeHint;

typedef struct _LADSPA_Descriptor {
    unsigned long UniqueID;
    const char *Label;
    LADSPA_Properties Properties;
    const char *Name;
    const char *Maker;
    const char *Copyright;
    unsigned long PortCount;
    const LADSPA_PortDescriptor *PortDescriptors;
    const char *const *PortNames;
    const LADSPA_PortRangeHint *PortRangeHints;
    void *ImplementationData;
    LADSPA_Handle (*instantiate)(const struct _LADSPA_Descriptor *descriptor, unsigned long sample_rate);
    void (*connect_port)(LADSPA_Handle instance, unsigned long port, LADSPA_Data *data_location);
    void (*activate)(LADSPA_Handle instance);
    void (*run)(LADSPA_Handle instance, unsigned long sample_count);
    void (*run_adding)(LADSPA_Handle instance, unsigned long sample_count);
    void (*set_run_adding_gain)(LADSPA_Handle instance, LADSPA_Data gain);
    void (*deactivate)(LADSPA_Handle instance);
    void (*cleanup)(LADSPA_Handle instance);
} LADSPA_Descriptor;

typedef const LADSPA_Descriptor *(*LADSPA_Descriptor_Function)(unsigned long index);

#define LADSPA_PORT_INPUT 0x1
#define LADSPA_PORT_OUTPUT 0x2
#define LADSPA_PORT_CONTROL 0x4
#define LADSPA_PORT_AUDIO 0x8

#define LADSPA_HINT_BOUNDED_BELOW 0x1
#define LADSPA_HINT_BOUNDED_ABOVE 0x2
#define LADSPA_HINT_TOGGLED 0x4
#define LADSPA_HINT_SAMPLE_RATE 0x8
#define LADSPA_HINT_LOGARITHMIC 0x10
#define LADSPA_HINT_INTEGER 0x20
#define LADSPA_HINT_DEFAULT_MASK 0x3C0
#define LADSPA_HINT_DEFAULT_NONE 0x0
#define LADSPA_HINT_DEFAULT_MINIMUM 0x40
#define LADSPA_HINT_DEFAULT_LOW 0x80
#define LADSPA_HINT_DEFAULT_MIDDLE 0xC0
#define LADSPA_HINT_DEFAULT_HIGH 0x100
#define LADSPA_HINT_DEFAULT_MAXIMUM 0x140
#define LADSPA_HINT_DEFAULT_0 0x200
#define LADSPA_HINT_DEFAULT_1 0x240
#define LADSPA_HINT_DEFAULT_100 0x280
#define LADSPA_HINT_DEFAULT_440 0x2C0

#endif
