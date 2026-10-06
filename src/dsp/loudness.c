#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

static double bessel_i0(double x)
{
    double sum = 1, term = 1;
    for (int k = 1; k < 40; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

void wd__tp_design(double coef[4][WD_TP_TAPS])
{
    double beta = 5.0, half = 6.5;
    for (int ph = 0; ph < 4; ph++) {
        double d = ph / 4.0, sum = 0;
        for (int i = 0; i < WD_TP_TAPS; i++) {
            int k = i - (WD_TP_HALF - 1);
            double t = k - d;
            double s = fabs(t) < 1e-12 ? 1.0 : sin(M_PI * t) / (M_PI * t);
            double r = t / half;
            double w = fabs(r) >= 1 ? 0 : bessel_i0(beta * sqrt(1 - r * r)) / bessel_i0(beta);
            coef[ph][i] = s * w;
            sum += coef[ph][i];
        }
        for (int i = 0; i < WD_TP_TAPS; i++) coef[ph][i] /= sum;
    }
}

double wd__tp_eval(const double coef[4][WD_TP_TAPS], const float *hist, int pos)
{
    double best = 0;
    for (int ph = 0; ph < 4; ph++) {
        double acc = 0;
        for (int i = 0; i < WD_TP_TAPS; i++) {
            int k = i - (WD_TP_HALF - 1);
            int j = WD_TP_HALF - k;
            int idx = ((pos - j) % WD_TP_TAPS + WD_TP_TAPS) % WD_TP_TAPS;
            acc += coef[ph][i] * hist[idx];
        }
        if (fabs(acc) > best) best = fabs(acc);
    }
    return best;
}

struct _WdLoudness {
    int rate;
    int channels;
    double weight[WD_MAX_CHANNELS];
    WdBiquadCoef pre, rlb;
    WdBiquadState spre[WD_MAX_CHANNELS], srlb[WD_MAX_CHANNELS];
    int sub_len;
    int sub_pos;
    double sub_acc;
    double ring[30];
    int ring_count;
    int ring_pos;
    double *blocks;
    int64_t nblocks, cblocks;
    double *shorts;
    int64_t nshorts, cshorts;
    double tp_coef[4][WD_TP_TAPS];
    float hist[WD_MAX_CHANNELS][WD_TP_TAPS];
    int hpos;
    int64_t seen;
    double true_peak;
    double sample_peak;
};

static void k_filters(WdLoudness *l)
{
    double rate = l->rate;
    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = tan(M_PI * f0 / rate);
    double Vh = pow(10, G / 20), Vb = pow(Vh, 0.4996667741545416);
    double a0 = 1 + K / Q + K * K;
    l->pre.b0 = (Vh + Vb * K / Q + K * K) / a0;
    l->pre.b1 = 2 * (K * K - Vh) / a0;
    l->pre.b2 = (Vh - Vb * K / Q + K * K) / a0;
    l->pre.a1 = 2 * (K * K - 1) / a0;
    l->pre.a2 = (1 - K / Q + K * K) / a0;
    f0 = 38.13547087602444;
    Q = 0.5003270373238773;
    K = tan(M_PI * f0 / rate);
    double d = 1 + K / Q + K * K;
    l->rlb.b0 = 1;
    l->rlb.b1 = -2;
    l->rlb.b2 = 1;
    l->rlb.a1 = 2 * (K * K - 1) / d;
    l->rlb.a2 = (1 - K / Q + K * K) / d;
}

WdLoudness *wd_loud_new(int rate, int channels)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    WdLoudness *l = calloc(1, sizeof(WdLoudness));
    l->rate = rate > 0 ? rate : 48000;
    l->channels = channels;
    for (int i = 0; i < channels; i++) l->weight[i] = 1.0;
    if (channels == 6) {
        l->weight[3] = 0;
        l->weight[4] = 1.41;
        l->weight[5] = 1.41;
    }
    k_filters(l);
    wd__tp_design(l->tp_coef);
    l->sub_len = (int) lround(l->rate / 10.0);
    if (l->sub_len < 1) l->sub_len = 1;
    wd_loud_reset(l);
    return l;
}

void wd_loud_free(WdLoudness *l)
{
    if (!l) return;
    free(l->blocks);
    free(l->shorts);
    free(l);
}

void wd_loud_reset(WdLoudness *l)
{
    if (!l) return;
    memset(l->spre, 0, sizeof(l->spre));
    memset(l->srlb, 0, sizeof(l->srlb));
    memset(l->hist, 0, sizeof(l->hist));
    l->sub_pos = 0;
    l->sub_acc = 0;
    l->ring_count = 0;
    l->ring_pos = 0;
    l->nblocks = 0;
    l->nshorts = 0;
    l->hpos = 0;
    l->seen = 0;
    l->true_peak = 0;
    l->sample_peak = 0;
}

static void push(double **arr, int64_t *n, int64_t *cap, double v)
{
    if (*n >= *cap) {
        int64_t nc = *cap ? *cap * 2 : 1024;
        double *na = realloc(*arr, sizeof(double) * nc);
        if (!na) return;
        *arr = na;
        *cap = nc;
    }
    (*arr)[(*n)++] = v;
}

static double ring_mean(WdLoudness *l, int count)
{
    if (l->ring_count < count) return -1;
    double s = 0;
    for (int i = 0; i < count; i++) s += l->ring[((l->ring_pos - 1 - i) % 30 + 30) % 30];
    return s / count;
}

static void finish_sub(WdLoudness *l)
{
    l->ring[l->ring_pos] = l->sub_acc / l->sub_len;
    l->ring_pos = (l->ring_pos + 1) % 30;
    if (l->ring_count < 30) l->ring_count++;
    l->sub_acc = 0;
    l->sub_pos = 0;
    double m = ring_mean(l, 4);
    if (m >= 0) push(&l->blocks, &l->nblocks, &l->cblocks, m);
    double s = ring_mean(l, 30);
    if (s >= 0) push(&l->shorts, &l->nshorts, &l->cshorts, s);
}

void wd_loud_add(WdLoudness *l, const float *buf, int64_t frames)
{
    if (!l || frames <= 0) return;
    int nch = l->channels;
    for (int64_t i = 0; i < frames; i++) {
        double e = 0;
        l->hpos = (l->hpos + 1) % WD_TP_TAPS;
        for (int ch = 0; ch < nch; ch++) {
            float x = buf[i * nch + ch];
            double ax = fabs(x);
            if (ax > l->sample_peak) l->sample_peak = ax;
            l->hist[ch][l->hpos] = x;
            if (l->seen >= WD_TP_HALF) {
                double tp = wd__tp_eval(l->tp_coef, l->hist[ch], l->hpos);
                if (tp > l->true_peak) l->true_peak = tp;
            }
            if (l->weight[ch] == 0) continue;
            double y = wd__biquad_tick(&l->pre, &l->spre[ch], x);
            y = wd__biquad_tick(&l->rlb, &l->srlb[ch], y);
            e += l->weight[ch] * y * y;
        }
        l->seen++;
        l->sub_acc += e;
        if (++l->sub_pos >= l->sub_len) finish_sub(l);
    }
}

static double lufs(double e)
{
    return e > 0 ? -0.691 + 10 * log10(e) : -HUGE_VAL;
}

double wd_loud_momentary(WdLoudness *l)
{
    double m = l ? ring_mean(l, 4) : -1;
    return m < 0 ? -HUGE_VAL : lufs(m);
}

double wd_loud_short_term(WdLoudness *l)
{
    double m = l ? ring_mean(l, 30) : -1;
    return m < 0 ? -HUGE_VAL : lufs(m);
}

double wd_loud_integrated(WdLoudness *l)
{
    if (!l || l->nblocks == 0) return -HUGE_VAL;
    double abs_e = pow(10, (-70 + 0.691) / 10);
    double sum = 0;
    int64_t n = 0;
    for (int64_t i = 0; i < l->nblocks; i++) {
        if (l->blocks[i] > abs_e) {
            sum += l->blocks[i];
            n++;
        }
    }
    if (n == 0) return -HUGE_VAL;
    double rel_e = (sum / n) * pow(10, -10 / 10.0);
    sum = 0;
    n = 0;
    for (int64_t i = 0; i < l->nblocks; i++) {
        if (l->blocks[i] > abs_e && l->blocks[i] > rel_e) {
            sum += l->blocks[i];
            n++;
        }
    }
    return n == 0 ? -HUGE_VAL : lufs(sum / n);
}

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *) a, y = *(const double *) b;
    return x < y ? -1 : x > y;
}

double wd_loud_range(WdLoudness *l)
{
    if (!l || l->nshorts == 0) return 0;
    double abs_e = pow(10, (-70 + 0.691) / 10);
    double sum = 0;
    int64_t n = 0;
    for (int64_t i = 0; i < l->nshorts; i++) {
        if (l->shorts[i] > abs_e) {
            sum += l->shorts[i];
            n++;
        }
    }
    if (n == 0) return 0;
    double rel_e = (sum / n) * pow(10, -20 / 10.0);
    double *v = malloc(sizeof(double) * n);
    int64_t m = 0;
    for (int64_t i = 0; i < l->nshorts; i++) if (l->shorts[i] > abs_e && l->shorts[i] > rel_e) v[m++] = lufs(l->shorts[i]);
    double r = 0;
    if (m >= 2) {
        qsort(v, m, sizeof(double), cmp_d);
        int64_t lo = (int64_t) llround(0.10 * (m - 1));
        int64_t hi = (int64_t) llround(0.95 * (m - 1));
        r = v[hi] - v[lo];
    }
    free(v);
    return r;
}

double wd_loud_true_peak(WdLoudness *l)
{
    if (!l || l->seen == 0) return -HUGE_VAL;
    double p = l->true_peak > l->sample_peak ? l->true_peak : l->sample_peak;
    return p > 0 ? 20 * log10(p) : -HUGE_VAL;
}

double wd_loud_sample_peak(WdLoudness *l)
{
    if (!l || l->seen == 0 || l->sample_peak <= 0) return -HUGE_VAL;
    return 20 * log10(l->sample_peak);
}
