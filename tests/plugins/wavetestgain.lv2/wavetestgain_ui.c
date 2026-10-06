#include "abi_lv2.h"

#include <stdlib.h>
#include <string.h>

typedef struct {
    LV2_External_UI_Widget widget;
    LV2UI_Write_Function write;
    LV2UI_Controller controller;
    int shown;
    int written;
} Ui;

static void ui_run(LV2_External_UI_Widget *w)
{
    Ui *ui = (Ui *) w;
    if (ui->shown && !ui->written) {
        float v = 0.25f;
        ui->write(ui->controller, 0, sizeof(float), 0, &v);
        ui->written = 1;
    }
}

static void ui_show(LV2_External_UI_Widget *w)
{
    ((Ui *) w)->shown = 1;
}

static void ui_hide(LV2_External_UI_Widget *w)
{
    ((Ui *) w)->shown = 0;
}

static LV2UI_Handle instantiate(const LV2UI_Descriptor *d, const char *plugin, const char *bundle, LV2UI_Write_Function write, LV2UI_Controller controller, LV2UI_Widget *widget, const LV2_Feature *const *features)
{
    (void) d;
    (void) bundle;
    if (strcmp(plugin, "urn:singularity:wave-test:gain") != 0) return NULL;
    int host = 0;
    for (int i = 0; features && features[i]; i++) {
        if (strcmp(features[i]->URI, "http://kxstudio.sf.net/ns/lv2ext/external-ui#Host") == 0) host = 1;
    }
    if (!host) return NULL;
    Ui *ui = calloc(1, sizeof(Ui));
    ui->widget.run = ui_run;
    ui->widget.show = ui_show;
    ui->widget.hide = ui_hide;
    ui->write = write;
    ui->controller = controller;
    *widget = &ui->widget;
    return ui;
}

static void cleanup(LV2UI_Handle h)
{
    free(h);
}

static void port_event(LV2UI_Handle h, uint32_t port, uint32_t size, uint32_t format, const void *buffer)
{
    (void) h;
    (void) port;
    (void) size;
    (void) format;
    (void) buffer;
}

static const LV2UI_Descriptor descriptor = {
    "urn:singularity:wave-test:gain#ui",
    instantiate,
    cleanup,
    port_event,
    NULL
};

const LV2UI_Descriptor *lv2ui_descriptor(uint32_t index)
{
    return index == 0 ? &descriptor : NULL;
}
