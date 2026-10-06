#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

#define MAX_LOOKAHEAD_MS 50.0

struct _WdDynamics {
    WdDynamicsType type;
    int rate;
    int channels;
    float threshold, ratio, attack, release, knee, makeup, lookahead, range, freq;
    int true_peak;
    double att_coef, rel_coef;
    double env;
    int hold, hold_len;
    int L, Dt, delay;
    int cap;
    float *line;
    int lpos;
    float hist[WD_MAX_CHANNELS][WD_TP_TAPS];
    int hpos;
    int64_t seen;
    double tp_coef[4][WD_TP_TAPS];
    double *dq_val;
    int64_t *dq_idx;
    int dq_head, dq_tail;
    double *aring;
    double asum;
    int apos;
    int64_t count;
    WdBiquadCoef side;
    WdBiquadState sstate[WD_MAX_CHANNELS];
    WdBiquadState bstate[WD_MAX_CHANNELS];
    float last_gr;
};

static double ms_coef(double ms, int rate)
{
    if (ms <= 0.01) return 0;
    return exp(-1.0 / (ms * 0.001 * rate));
}

WdDynamics *wd_dyn_new(WdDynamicsType type, int rate, int channels)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    WdDynamics *d = calloc(1, sizeof(WdDynamics));
    d->type = type;
    d->rate = rate > 0 ? rate : 48000;
    d->channels = channels;
    d->cap = (int) (MAX_LOOKAHEAD_MS * 0.001 * d->rate) + WD_TP_TAPS + 4;
    d->line = calloc((size_t) d->cap * channels, sizeof(float));
    d->dq_val = calloc(d->cap, sizeof(double));
    d->dq_idx = calloc(d->cap, sizeof(int64_t));
    d->aring = calloc(d->cap, sizeof(double));
    wd__tp_design(d->tp_coef);
    float thr = type == WD_DYN_LIMITER ? -1.0f : type == WD_DYN_GATE ? -50.0f : -20.0f;
    float lookahead = type == WD_DYN_LIMITER ? 5.0f : 0.0f;
    wd_dyn_set(d, thr, type == WD_DYN_EXPANDER ? 2.0f : 4.0f, type == WD_DYN_LIMITER ? 0.5f : 10.0f, type == WD_DYN_LIMITER ? 50.0f : 100.0f, 6.0f, 0.0f, lookahead, type == WD_DYN_GATE ? 80.0f : 0.0f, 6000.0f, 0);
    wd_dyn_reset(d);
    return d;
}

void wd_dyn_free(WdDynamics *d)
{
    if (!d) return;
    free(d->line);
    free(d->dq_val);
    free(d->dq_idx);
    free(d->aring);
    free(d);
}

void wd_dyn_set(WdDynamics *d, float threshold_db, float ratio, float attack_ms, float release_ms, float knee_db, float makeup_db, float lookahead_ms, float range_db, float freq_hz, int true_peak)
{
    if (!d) return;
    d->threshold = threshold_db;
    d->ratio = ratio < 1 ? 1 : ratio;
    d->attack = attack_ms;
    d->release = release_ms;
    d->knee = knee_db < 0 ? 0 : knee_db;
    d->makeup = makeup_db;
    if (lookahead_ms < 0) lookahead_ms = 0;
    if (lookahead_ms > MAX_LOOKAHEAD_MS) lookahead_ms = MAX_LOOKAHEAD_MS;
    d->lookahead = lookahead_ms;
    d->range = range_db < 0 ? -range_db : range_db;
    d->freq = freq_hz > 0 ? freq_hz : 6000;
    d->true_peak = true_peak != 0;
    d->att_coef = ms_coef(attack_ms, d->rate);
    d->rel_coef = ms_coef(release_ms, d->rate);
    d->hold_len = (int) (0.02 * d->rate);
    int L = (int) lround(lookahead_ms * 0.001 * d->rate);
    int Dt = d->type == WD_DYN_LIMITER && d->true_peak ? WD_TP_HALF : 0;
    if (L + Dt + 1 > d->cap) L = d->cap - Dt - 1;
    if (L != d->L || Dt != d->Dt) {
        d->L = L;
        d->Dt = Dt;
        d->delay = L + Dt;
        wd_dyn_reset(d);
    }
    wd__biquad_design(&d->side, WD_BAND_BAND_PASS, d->rate, d->freq, 0, 1.4);
}

void wd_dyn_reset(WdDynamics *d)
{
    if (!d) return;
    memset(d->line, 0, sizeof(float) * (size_t) d->cap * d->channels);
    memset(d->hist, 0, sizeof(d->hist));
    memset(d->sstate, 0, sizeof(d->sstate));
    memset(d->bstate, 0, sizeof(d->bstate));
    d->lpos = 0;
    d->hpos = 0;
    d->seen = 0;
    d->dq_head = d->dq_tail = 0;
    for (int i = 0; i < d->cap; i++) d->aring[i] = 1.0;
    d->asum = d->L + 1;
    d->apos = 0;
    d->count = 0;
    d->env = d->type == WD_DYN_LIMITER ? 1.0 : 0.0;
    d->hold = 0;
    d->last_gr = 0;
}

int wd_dyn_latency(WdDynamics *d)
{
    return d ? d->delay : 0;
}

static double static_gr(WdDynamics *d, double in)
{
    double T = d->threshold, R = d->ratio, W = d->knee;
    switch (d->type) {
    case WD_DYN_COMPRESSOR:
    case WD_DYN_DEESSER: {
        double x = in - T;
        double out;
        if (2 * x < -W) out = in;
        else if (W > 0 && fabs(2 * x) <= W) out = in + (1 / R - 1) * (x + W / 2) * (x + W / 2) / (2 * W);
        else out = T + x / R;
        return in - out;
    }
    case WD_DYN_LIMITER:
        return in > T ? in - T : 0;
    case WD_DYN_EXPANDER: {
        if (in >= T) return 0;
        double gr = (T - in) * (R - 1);
        if (d->range > 0 && gr > d->range) gr = d->range;
        return gr;
    }
    case WD_DYN_GATE:
        return in < T ? (d->range > 0 ? d->range : 80) : 0;
    }
    return 0;
}

float wd_dyn_curve(WdDynamics *d, float input_db)
{
    if (!d) return input_db;
    return (float) (input_db - static_gr(d, input_db) + (d->type == WD_DYN_LIMITER ? 0 : d->makeup));
}

float wd_dyn_gain_reduction(WdDynamics *d)
{
    return d ? d->last_gr : 0;
}

static void process_limiter(WdDynamics *d, float *buf, int frames)
{
    int nch = d->channels, L = d->L;
    double ceiling = pow(10, d->threshold / 20.0) * (d->true_peak ? 0.999 : 1.0);
    double rel = d->rel_coef;
    double maxgr = 0;
    for (int i = 0; i < frames; i++) {
        float *frame = buf + (size_t) i * nch;
        float *slot = d->line + (size_t) d->lpos * nch;
        double peak = 0;
        d->hpos = (d->hpos + 1) % WD_TP_TAPS;
        for (int ch = 0; ch < nch; ch++) {
            float x = frame[ch];
            slot[ch] = x;
            d->hist[ch][d->hpos] = x;
            if (d->true_peak) {
                double tp = wd__tp_eval(d->tp_coef, d->hist[ch], d->hpos);
                if (tp > peak) peak = tp;
            } else if (fabs(x) > peak) {
                peak = fabs(x);
            }
        }
        double greq = peak > ceiling ? ceiling / peak : 1.0;
        int64_t idx = d->count++;
        while (d->dq_tail > d->dq_head && d->dq_val[(d->dq_tail - 1) % d->cap] >= greq) d->dq_tail--;
        d->dq_val[d->dq_tail % d->cap] = greq;
        d->dq_idx[d->dq_tail % d->cap] = idx;
        d->dq_tail++;
        while (d->dq_idx[d->dq_head % d->cap] < idx - L) d->dq_head++;
        double A = d->dq_val[d->dq_head % d->cap];
        d->asum += A - d->aring[d->apos];
        d->aring[d->apos] = A;
        d->apos = (d->apos + 1) % (L + 1);
        double B = d->asum / (L + 1);
        if (B > 1) B = 1;
        if (B < d->env) d->env = B;
        else d->env = d->env + (B - d->env) * (1 - rel);
        int rd = ((d->lpos - d->delay) % (d->delay + 1) + (d->delay + 1)) % (d->delay + 1);
        float *out = d->line + (size_t) rd * nch;
        float g = (float) d->env;
        double gr = -20 * log10(d->env > 1e-9 ? d->env : 1e-9);
        if (gr > maxgr) maxgr = gr;
        for (int ch = 0; ch < nch; ch++) frame[ch] = out[ch] * g;
        d->lpos = (d->lpos + 1) % (d->delay + 1);
    }
    d->last_gr = (float) maxgr;
}

void wd_dyn_process(WdDynamics *d, float *buf, int frames)
{
    if (!d || frames <= 0) return;
    if (d->type == WD_DYN_LIMITER) {
        process_limiter(d, buf, frames);
        return;
    }
    int nch = d->channels;
    int opening = d->type == WD_DYN_GATE || d->type == WD_DYN_EXPANDER;
    double maxgr = 0;
    double makeup = pow(10, d->makeup / 20.0);
    for (int i = 0; i < frames; i++) {
        float *frame = buf + (size_t) i * nch;
        float *slot = d->line + (size_t) d->lpos * nch;
        double level = 0;
        for (int ch = 0; ch < nch; ch++) {
            float x = frame[ch];
            slot[ch] = x;
            double v = x;
            if (d->type == WD_DYN_DEESSER) v = wd__biquad_tick(&d->side, &d->sstate[ch], x);
            if (fabs(v) > level) level = fabs(v);
        }
        double ldb = 20 * log10(level > 1e-9 ? level : 1e-9);
        double target = static_gr(d, ldb);
        if (d->type == WD_DYN_GATE) {
            if (target == 0) d->hold = d->hold_len;
            else if (d->hold > 0) {
                d->hold--;
                target = 0;
            }
        }
        int rising = target > d->env;
        double coef = opening ? (rising ? d->rel_coef : d->att_coef) : (rising ? d->att_coef : d->rel_coef);
        d->env = coef * d->env + (1 - coef) * target;
        if (d->env > maxgr) maxgr = d->env;
        int rd = d->delay > 0 ? ((d->lpos - d->delay) % (d->delay + 1) + (d->delay + 1)) % (d->delay + 1) : d->lpos;
        float *out = d->line + (size_t) rd * nch;
        double g = pow(10, -d->env / 20.0);
        for (int ch = 0; ch < nch; ch++) {
            double x = out[ch];
            if (d->type == WD_DYN_DEESSER) {
                double band = wd__biquad_tick(&d->side, &d->bstate[ch], x);
                frame[ch] = (float) ((x - band * (1 - g)) * makeup);
            } else {
                frame[ch] = (float) (x * g * makeup);
            }
        }
        d->lpos = d->delay > 0 ? (d->lpos + 1) % (d->delay + 1) : 0;
    }
    d->last_gr = (float) maxgr;
}
