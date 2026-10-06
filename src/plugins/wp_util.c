#define _GNU_SOURCE
#include "wp_internal.h"

#include <locale.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

WpDesc *wp_desc_new(int format)
{
    WpDesc *d = calloc(1, sizeof(WpDesc));
    d->format = format;
    d->latency_port = -1;
    return d;
}

void wp_desc_free(WpDesc *d)
{
    if (!d) return;
    for (int i = 0; i < d->n_params; i++) {
        WpParam *p = &d->params[i];
        free(p->id);
        free(p->label);
        for (int c = 0; c < p->n_choices; c++) free(p->choice_labels[c]);
        free(p->choice_labels);
        free(p->choice_values);
    }
    free(d->params);
    free(d->kind);
    free(d->name);
    free(d->vendor);
    free(d->path);
    free(d->uri);
    free(d->binary);
    free(d->bundle);
    free(d->in_ports);
    free(d->out_ports);
    free(d->port_kind);
    free(d->port_default);
    free(d->ui_uri);
    free(d->ui_binary);
    free(d->ui_bundle);
    free(d->unsupported);
    free(d);
}

void wp_desc_list_free(WpDesc **list, int count)
{
    if (!list) return;
    for (int i = 0; i < count; i++) wp_desc_free(list[i]);
    free(list);
}

WpParam *wp_desc_add_param(WpDesc *d)
{
    d->params = realloc(d->params, sizeof(WpParam) * (d->n_params + 1));
    WpParam *p = &d->params[d->n_params++];
    memset(p, 0, sizeof(WpParam));
    p->max = 1;
    p->port = -1;
    return p;
}

void wp_param_add_choice(WpParam *p, const char *label, double value)
{
    p->choice_labels = realloc(p->choice_labels, sizeof(char *) * (p->n_choices + 1));
    p->choice_values = realloc(p->choice_values, sizeof(double) * (p->n_choices + 1));
    p->choice_labels[p->n_choices] = strdup(label);
    p->choice_values[p->n_choices] = value;
    p->n_choices++;
}

static void reserve(WpStr *s, size_t extra)
{
    if (s->len + extra + 1 <= s->cap) return;
    size_t cap = s->cap ? s->cap : 256;
    while (cap < s->len + extra + 1) cap *= 2;
    s->data = realloc(s->data, cap);
    s->cap = cap;
}

void wp_str_add(WpStr *s, const char *text)
{
    size_t n = strlen(text);
    reserve(s, n);
    memcpy(s->data + s->len, text, n);
    s->len += n;
    s->data[s->len] = 0;
}

void wp_str_addf(WpStr *s, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *t = NULL;
    if (vasprintf(&t, fmt, ap) < 0) t = NULL;
    va_end(ap);
    if (t) {
        wp_str_add(s, t);
        free(t);
    }
}

void wp_str_add_json(WpStr *s, const char *text)
{
    if (!text) {
        wp_str_add(s, "null");
        return;
    }
    reserve(s, strlen(text) * 6 + 2);
    s->data[s->len++] = '"';
    for (const unsigned char *c = (const unsigned char *) text; *c; c++) {
        if (*c == '"' || *c == '\\') {
            s->data[s->len++] = '\\';
            s->data[s->len++] = (char) *c;
        } else if (*c < 0x20) {
            s->len += (size_t) sprintf(s->data + s->len, "\\u%04x", *c);
        } else {
            s->data[s->len++] = (char) *c;
        }
    }
    s->data[s->len++] = '"';
    s->data[s->len] = 0;
}

static locale_t c_locale(void)
{
    static locale_t loc;
    if (!loc) loc = newlocale(LC_ALL_MASK, "C", (locale_t) 0);
    return loc;
}

double wp_strtod(const char *text)
{
    if (!text) return 0;
    return strtod_l(text, NULL, c_locale());
}

void wp_str_add_double(WpStr *s, double v)
{
    if (!isfinite(v)) v = 0;
    char buf[64];
    locale_t old = uselocale(c_locale());
    snprintf(buf, sizeof buf, "%.17g", v);
    uselocale(old);
    wp_str_add(s, buf);
}

void wp_desc_to_json(WpDesc *d, WpStr *s)
{
    static const char *formats[] = { "LV2", "LADSPA", "CLAP" };
    wp_str_add(s, "{\"kind\":");
    wp_str_add_json(s, d->kind);
    wp_str_add(s, ",\"name\":");
    wp_str_add_json(s, d->name ? d->name : d->kind);
    wp_str_add(s, ",\"format\":");
    wp_str_add_json(s, formats[d->format]);
    wp_str_add(s, ",\"vendor\":");
    wp_str_add_json(s, d->vendor ? d->vendor : "");
    wp_str_add(s, ",\"path\":");
    wp_str_add_json(s, d->path ? d->path : "");
    wp_str_addf(s, ",\"audio_inputs\":%d,\"audio_outputs\":%d", d->n_in, d->n_out);
    wp_str_addf(s, ",\"native_ui\":%s", d->ui_binary ? "true" : "false");
    if (d->unsupported) {
        wp_str_add(s, ",\"unsupported\":");
        wp_str_add_json(s, d->unsupported);
    }
    wp_str_add(s, ",\"params\":[");
    for (int i = 0; i < d->n_params; i++) {
        WpParam *p = &d->params[i];
        if (i) wp_str_add(s, ",");
        wp_str_add(s, "{\"id\":");
        wp_str_add_json(s, p->id);
        wp_str_add(s, ",\"label\":");
        wp_str_add_json(s, p->label ? p->label : p->id);
        wp_str_add(s, ",\"min\":");
        wp_str_add_double(s, p->min);
        wp_str_add(s, ",\"max\":");
        wp_str_add_double(s, p->max);
        wp_str_add(s, ",\"default\":");
        wp_str_add_double(s, p->def);
        wp_str_addf(s, ",\"toggle\":%s,\"log\":%s,\"integer\":%s", p->toggle ? "true" : "false", p->logarithmic ? "true" : "false", p->integer ? "true" : "false");
        wp_str_add(s, ",\"choices\":[");
        for (int c = 0; c < p->n_choices; c++) {
            if (c) wp_str_add(s, ",");
            wp_str_add_json(s, p->choice_labels[c]);
        }
        wp_str_add(s, "],\"values\":[");
        for (int c = 0; c < p->n_choices; c++) {
            if (c) wp_str_add(s, ",");
            wp_str_add_double(s, p->choice_values[c]);
        }
        wp_str_add(s, "]}");
    }
    wp_str_add(s, "]}");
}

char *wp_dup_printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    char *t = NULL;
    if (vasprintf(&t, fmt, ap) < 0) t = NULL;
    va_end(ap);
    return t;
}

int wp_has_suffix(const char *s, const char *suffix)
{
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcmp(s + a - b, suffix) == 0;
}
