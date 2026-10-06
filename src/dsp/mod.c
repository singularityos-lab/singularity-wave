#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

#define PHASER_STAGES 6

struct _WdMod {
    WdModType type;
    int rate;
    int channels;
    float rate_hz, depth, feedback, mix;
    int len;
    float *line;
    int pos;
    double phase;
    float fb[WD_MAX_CHANNELS];
    float ap[WD_MAX_CHANNELS][PHASER_STAGES];
};

WdMod *wd_mod_new(WdModType type, int rate, int channels)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    WdMod *m = calloc(1, sizeof(WdMod));
    m->type = type;
    m->rate = rate > 0 ? rate : 48000;
    m->channels = channels;
    m->len = (int) (0.05 * m->rate) + 4;
    m->line = calloc((size_t) m->len * channels, sizeof(float));
    wd_mod_set(m, type == WD_MOD_PHASER ? 0.5f : type == WD_MOD_FLANGER ? 0.25f : 1.2f, 0.5f, type == WD_MOD_CHORUS ? 0.0f : 0.5f, 0.5f);
    return m;
}

void wd_mod_free(WdMod *m)
{
    if (!m) return;
    free(m->line);
    free(m);
}

void wd_mod_set(WdMod *m, float rate_hz, float depth, float feedback, float mix)
{
    if (!m) return;
    m->rate_hz = rate_hz < 0.01f ? 0.01f : rate_hz;
    m->depth = depth < 0 ? 0 : depth > 1 ? 1 : depth;
    m->feedback = feedback < -0.95f ? -0.95f : feedback > 0.95f ? 0.95f : feedback;
    m->mix = mix < 0 ? 0 : mix > 1 ? 1 : mix;
}

void wd_mod_reset(WdMod *m)
{
    if (!m) return;
    memset(m->line, 0, sizeof(float) * (size_t) m->len * m->channels);
    memset(m->fb, 0, sizeof(m->fb));
    memset(m->ap, 0, sizeof(m->ap));
    m->pos = 0;
    m->phase = 0;
}

static float read_line(WdMod *m, int ch, float delay)
{
    float rp = m->pos - delay;
    while (rp < 0) rp += m->len;
    int i0 = (int) rp;
    float fr = rp - i0;
    int i1 = (i0 + 1) % m->len;
    float a = m->line[(size_t) i0 * m->channels + ch], b = m->line[(size_t) i1 * m->channels + ch];
    return a + (b - a) * fr;
}

void wd_mod_process(WdMod *m, float *buf, int frames)
{
    if (!m || frames <= 0) return;
    int nch = m->channels;
    double inc = m->rate_hz / m->rate;
    for (int i = 0; i < frames; i++) {
        float *f = buf + (size_t) i * nch;
        for (int ch = 0; ch < nch; ch++) {
            double ph = m->phase + (nch > 1 ? (double) ch / nch * 0.5 : 0);
            float lfo = (float) (0.5 + 0.5 * sin(2 * M_PI * ph));
            float x = f[ch];
            float wet;
            if (m->type == WD_MOD_PHASER) {
                double fmin = 200, fmax = 200 + 3800 * m->depth;
                double fc = fmin * pow(fmax / fmin, lfo);
                double t = tan(M_PI * fc / m->rate);
                float a = (float) ((t - 1) / (t + 1));
                float v = x + m->feedback * m->fb[ch];
                for (int s = 0; s < PHASER_STAGES; s++) {
                    float y = a * v + m->ap[ch][s];
                    m->ap[ch][s] = v - a * y;
                    v = y;
                }
                m->fb[ch] = v;
                wet = v;
            } else {
                float base = m->type == WD_MOD_CHORUS ? 0.015f : 0.001f;
                float span = m->type == WD_MOD_CHORUS ? 0.010f : 0.004f;
                float delay = (base + span * m->depth * lfo) * m->rate;
                wet = read_line(m, ch, delay);
                m->line[(size_t) m->pos * nch + ch] = x + m->feedback * wet;
            }
            f[ch] = x * (1 - m->mix * 0.5f) + wet * m->mix * (m->type == WD_MOD_PHASER ? 1.0f : 0.7f);
        }
        if (m->type != WD_MOD_PHASER && ++m->pos >= m->len) m->pos = 0;
        m->phase += inc;
        if (m->phase >= 1) m->phase -= 1;
    }
}

void wd_saturate(float *buf, int64_t samples, WdSaturation kind, float drive_db, float mix, float output_db)
{
    if (samples <= 0) return;
    float g = powf(10.0f, drive_db / 20.0f);
    float out = powf(10.0f, output_db / 20.0f);
    if (mix < 0) mix = 0;
    if (mix > 1) mix = 1;
    float bias = 0.2f, tb = tanhf(bias);
    for (int64_t i = 0; i < samples; i++) {
        float x = buf[i], v = x * g, y;
        switch (kind) {
        case WD_SAT_HARD:
            y = v > 1 ? 1 : v < -1 ? -1 : v;
            break;
        case WD_SAT_TUBE:
            y = (tanhf(v + bias) - tb) / (1 - tb * tb + 1e-6f);
            if (y > 1) y = 1;
            if (y < -1) y = -1;
            break;
        case WD_SAT_FOLD:
            y = v;
            for (int k = 0; k < 16 && (y > 1 || y < -1); k++) y = y > 1 ? 2 - y : -2 - y;
            break;
        default:
            y = tanhf(v);
            break;
        }
        buf[i] = (x * (1 - mix) + y * mix) * out;
    }
}
