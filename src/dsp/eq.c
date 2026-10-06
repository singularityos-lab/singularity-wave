#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

void wd__biquad_design(WdBiquadCoef *c, WdBandType type, double rate, double freq, double gain_db, double q)
{
    if (freq < 1) freq = 1;
    if (freq > rate * 0.499) freq = rate * 0.499;
    if (q <= 0.01) q = 0.01;
    double A = pow(10, gain_db / 40);
    double w0 = 2 * M_PI * freq / rate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / (2 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
    case WD_BAND_LOW_SHELF: {
        double s = 2 * sqrt(A) * alpha;
        b0 = A * ((A + 1) - (A - 1) * cw + s);
        b1 = 2 * A * ((A - 1) - (A + 1) * cw);
        b2 = A * ((A + 1) - (A - 1) * cw - s);
        a0 = (A + 1) + (A - 1) * cw + s;
        a1 = -2 * ((A - 1) + (A + 1) * cw);
        a2 = (A + 1) + (A - 1) * cw - s;
        break;
    }
    case WD_BAND_HIGH_SHELF: {
        double s = 2 * sqrt(A) * alpha;
        b0 = A * ((A + 1) + (A - 1) * cw + s);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 = A * ((A + 1) + (A - 1) * cw - s);
        a0 = (A + 1) - (A - 1) * cw + s;
        a1 = 2 * ((A - 1) - (A + 1) * cw);
        a2 = (A + 1) - (A - 1) * cw - s;
        break;
    }
    case WD_BAND_LOW_PASS:
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = (1 - cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
        break;
    case WD_BAND_HIGH_PASS:
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = (1 + cw) / 2;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
        break;
    case WD_BAND_NOTCH:
        b0 = 1;
        b1 = -2 * cw;
        b2 = 1;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
        break;
    case WD_BAND_BAND_PASS:
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
        break;
    default:
        b0 = 1 + alpha * A;
        b1 = -2 * cw;
        b2 = 1 - alpha * A;
        a0 = 1 + alpha / A;
        a1 = -2 * cw;
        a2 = 1 - alpha / A;
        break;
    }
    c->b0 = b0 / a0;
    c->b1 = b1 / a0;
    c->b2 = b2 / a0;
    c->a1 = a1 / a0;
    c->a2 = a2 / a0;
}

double wd__biquad_mag(const WdBiquadCoef *c, double rate, double freq)
{
    double w = 2 * M_PI * freq / rate;
    double c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w);
    double nr = c->b0 + c->b1 * c1 + c->b2 * c2;
    double ni = -(c->b1 * s1 + c->b2 * s2);
    double dr = 1 + c->a1 * c1 + c->a2 * c2;
    double di = -(c->a1 * s1 + c->a2 * s2);
    double num = nr * nr + ni * ni, den = dr * dr + di * di;
    return den > 0 ? sqrt(num / den) : 0;
}

typedef struct {
    WdBandType type;
    float freq, gain, q;
    int enabled;
    WdBiquadCoef cur;
    WdBiquadCoef target;
    int dirty;
} EqBand;

struct _WdEq {
    int rate;
    int channels;
    int bands;
    EqBand *band;
    WdBiquadState *state;
};

static const WdBiquadCoef identity = { 1, 0, 0, 0, 0 };

WdEq *wd_eq_new(int rate, int channels, int bands)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    if (bands < 1) bands = 1;
    WdEq *eq = calloc(1, sizeof(WdEq));
    eq->rate = rate > 0 ? rate : 48000;
    eq->channels = channels;
    eq->bands = bands;
    eq->band = calloc(bands, sizeof(EqBand));
    eq->state = calloc((size_t) bands * channels, sizeof(WdBiquadState));
    for (int i = 0; i < bands; i++) {
        eq->band[i].cur = identity;
        eq->band[i].target = identity;
        eq->band[i].q = 1;
        eq->band[i].freq = 1000;
    }
    return eq;
}

void wd_eq_free(WdEq *eq)
{
    if (!eq) return;
    free(eq->band);
    free(eq->state);
    free(eq);
}

int wd_eq_band_count(WdEq *eq)
{
    return eq ? eq->bands : 0;
}

void wd_eq_set_band(WdEq *eq, int index, WdBandType type, float freq, float gain_db, float q, int enabled)
{
    if (!eq || index < 0 || index >= eq->bands) return;
    EqBand *b = &eq->band[index];
    b->type = type;
    b->freq = freq;
    b->gain = gain_db;
    b->q = q;
    b->enabled = enabled;
    if (enabled) wd__biquad_design(&b->target, type, eq->rate, freq, gain_db, q);
    else b->target = identity;
    b->dirty = 1;
}

void wd_eq_reset(WdEq *eq)
{
    if (!eq) return;
    memset(eq->state, 0, sizeof(WdBiquadState) * eq->bands * eq->channels);
    for (int i = 0; i < eq->bands; i++) {
        eq->band[i].cur = eq->band[i].target;
        eq->band[i].dirty = 0;
    }
}

void wd_eq_process(WdEq *eq, float *buf, int frames)
{
    if (!eq || frames <= 0) return;
    int nch = eq->channels;
    for (int bi = 0; bi < eq->bands; bi++) {
        EqBand *b = &eq->band[bi];
        WdBiquadState *st = eq->state + (size_t) bi * nch;
        if (!b->dirty && !b->enabled) continue;
        if (b->dirty) {
            WdBiquadCoef from = b->cur, to = b->target;
            int ramp = frames < 64 ? frames : 64;
            for (int i = 0; i < frames; i++) {
                double t = i < ramp ? (i + 1) / (double) ramp : 1.0;
                WdBiquadCoef c = {
                    from.b0 + (to.b0 - from.b0) * t, from.b1 + (to.b1 - from.b1) * t, from.b2 + (to.b2 - from.b2) * t,
                    from.a1 + (to.a1 - from.a1) * t, from.a2 + (to.a2 - from.a2) * t
                };
                for (int ch = 0; ch < nch; ch++) buf[i * nch + ch] = (float) wd__biquad_tick(&c, &st[ch], buf[i * nch + ch]);
            }
            b->cur = to;
            b->dirty = 0;
            continue;
        }
        for (int i = 0; i < frames; i++)
            for (int ch = 0; ch < nch; ch++) buf[i * nch + ch] = (float) wd__biquad_tick(&b->cur, &st[ch], buf[i * nch + ch]);
    }
}

void wd_eq_response(WdEq *eq, const float *freqs, float *db_out, int n)
{
    if (!eq) return;
    for (int i = 0; i < n; i++) {
        double mag = 1;
        for (int bi = 0; bi < eq->bands; bi++) {
            if (!eq->band[bi].enabled) continue;
            mag *= wd__biquad_mag(&eq->band[bi].target, eq->rate, freqs[i]);
        }
        db_out[i] = mag > 1e-12 ? (float) (20 * log10(mag)) : -240.0f;
    }
}
