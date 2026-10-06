#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

struct _WdNoiseProfile {
    int fft;
    int bins;
    double *sum;
    int64_t count;
    float *window;
};

WdNoiseProfile *wd_noise_profile_new(int fft_size)
{
    if (!wd__is_pow2(fft_size)) fft_size = 2048;
    WdNoiseProfile *p = calloc(1, sizeof(WdNoiseProfile));
    p->fft = fft_size;
    p->bins = fft_size / 2 + 1;
    p->sum = calloc(p->bins, sizeof(double));
    p->window = malloc(sizeof(float) * fft_size);
    wd_window_fill(p->window, fft_size, WD_WINDOW_HANN);
    return p;
}

void wd_noise_profile_free(WdNoiseProfile *p)
{
    if (!p) return;
    free(p->sum);
    free(p->window);
    free(p);
}

void wd_noise_profile_learn(WdNoiseProfile *p, const float *buf, int64_t frames, int channels)
{
    if (!p || frames <= 0 || channels <= 0) return;
    int n = p->fft, hop = n / 4;
    float *re = malloc(sizeof(float) * n);
    float *im = malloc(sizeof(float) * n);
    for (int ch = 0; ch < channels; ch++) {
        for (int64_t b = 0; b == 0 || b + n <= frames; b += hop) {
            for (int i = 0; i < n; i++) {
                int64_t q = b + i;
                re[i] = q < frames ? buf[q * channels + ch] * p->window[i] : 0.0f;
                im[i] = 0;
            }
            wd_fft(re, im, n, 0);
            for (int k = 0; k < p->bins; k++) p->sum[k] += sqrt((double) re[k] * re[k] + (double) im[k] * im[k]);
            p->count++;
            if (frames <= n) break;
        }
    }
    free(re);
    free(im);
}

int wd_noise_profile_ready(WdNoiseProfile *p)
{
    return p && p->count > 0;
}

int wd_noise_profile_size(WdNoiseProfile *p)
{
    return p ? p->bins : 0;
}

void wd_noise_profile_get(WdNoiseProfile *p, float *out_db)
{
    for (int k = 0; k < p->bins; k++) {
        double m = p->count > 0 ? p->sum[k] / p->count : 0;
        out_db[k] = m > 1e-12 ? (float) (20 * log10(m)) : -240.0f;
    }
}

void wd_noise_profile_set(WdNoiseProfile *p, const float *db, int bins)
{
    if (!p || bins != p->bins) return;
    for (int k = 0; k < bins; k++) p->sum[k] = db[k] <= -239 ? 0 : pow(10, db[k] / 20.0);
    p->count = 1;
}

typedef struct {
    const float *noise;
    float thr_scale;
    float floor;
    float smoothing;
    int bins;
    float *prev;
    float *gain;
    int last_channel;
} ReduceCtx;

static void shape_gains(float *g, float *prev, int bins, float smoothing, float floor, int first)
{
    float *t = prev + bins;
    for (int k = 0; k < bins; k++) {
        float a = k > 0 ? g[k - 1] : g[k];
        float c = k < bins - 1 ? g[k + 1] : g[k];
        float avg = 0.25f * a + 0.5f * g[k] + 0.25f * c;
        t[k] = g[k] >= 0.9f ? g[k] : (1 - smoothing) * g[k] + smoothing * avg;
    }
    float rel = smoothing * 0.8f;
    for (int k = 0; k < bins; k++) {
        float v = t[k];
        if (!first) {
            float sm = rel * prev[k] + (1 - rel) * v;
            if (sm > v) v = sm;
        }
        if (v < floor) v = floor;
        if (v > 1) v = 1;
        prev[k] = v;
        g[k] = v;
    }
}

static int reduce_fn(void *ctx, int channel, int column, float *re, float *im, int bins)
{
    ReduceCtx *r = ctx;
    float *prev = r->prev + (int64_t) channel * bins * 2;
    int first = r->last_channel != channel;
    r->last_channel = channel;
    for (int k = 0; k < bins; k++) {
        float mag2 = re[k] * re[k] + im[k] * im[k];
        float thr = r->noise[k] * r->thr_scale;
        float thr2 = thr * thr;
        float g = mag2 > thr2 && mag2 > 0 ? 1.0f - thr2 / mag2 : 0.0f;
        r->gain[k] = g;
    }
    shape_gains(r->gain, prev, bins, r->smoothing, r->floor, first);
    for (int k = 0; k < bins; k++) {
        re[k] *= r->gain[k];
        im[k] *= r->gain[k];
    }
    return 1;
}

void wd_noise_reduce(WdNoiseProfile *p, float *buf, int64_t frames, int channels, float reduction_db, float sensitivity, float smoothing)
{
    if (!p || p->count == 0 || frames <= 0 || channels <= 0) return;
    float *noise = malloc(sizeof(float) * p->bins);
    for (int k = 0; k < p->bins; k++) noise[k] = (float) (p->sum[k] / p->count);
    if (smoothing < 0) smoothing = 0;
    if (smoothing > 1) smoothing = 1;
    ReduceCtx r = { noise, powf(10.0f, sensitivity / 20.0f), powf(10.0f, -fabsf(reduction_db) / 20.0f), smoothing, p->bins,
        calloc((size_t) channels * p->bins * 2, sizeof(float)), malloc(sizeof(float) * p->bins), -1 };
    wd__stft_full(buf, frames, channels, p->fft, p->fft / 4, reduce_fn, &r);
    free(noise);
    free(r.prev);
    free(r.gain);
}

#define MS_SUB 8

typedef struct {
    int bins;
    int sub_len;
    float thr_scale;
    float floor;
    float *power;
    float *mins;
    float *cur;
    int *pos;
    int *slot;
    float *prev;
    float *gain;
    float *noise;
    int last_channel;
} AdaptiveCtx;

static int adaptive_fn(void *ctx, int channel, int column, float *re, float *im, int bins)
{
    AdaptiveCtx *a = ctx;
    float *power = a->power + (int64_t) channel * bins;
    float *mins = a->mins + (int64_t) channel * bins * MS_SUB;
    float *cur = a->cur + (int64_t) channel * bins;
    float *prev = a->prev + (int64_t) channel * bins * 2;
    int first = a->last_channel != channel;
    a->last_channel = channel;
    if (first) {
        for (int k = 0; k < bins; k++) {
            float m2 = re[k] * re[k] + im[k] * im[k];
            power[k] = m2;
            cur[k] = m2;
            for (int s = 0; s < MS_SUB; s++) mins[k * MS_SUB + s] = m2;
        }
        a->pos[channel] = 0;
        a->slot[channel] = 0;
    }
    for (int k = 0; k < bins; k++) {
        float m2 = re[k] * re[k] + im[k] * im[k];
        power[k] = 0.7f * power[k] + 0.3f * m2;
        if (power[k] < cur[k]) cur[k] = power[k];
        float n = cur[k];
        for (int s = 0; s < MS_SUB; s++) if (mins[k * MS_SUB + s] < n) n = mins[k * MS_SUB + s];
        a->noise[k] = n * 2.0f;
    }
    if (++a->pos[channel] >= a->sub_len) {
        a->pos[channel] = 0;
        int s = a->slot[channel];
        for (int k = 0; k < bins; k++) {
            mins[k * MS_SUB + s] = cur[k];
            cur[k] = power[k];
        }
        a->slot[channel] = (s + 1) % MS_SUB;
    }
    for (int k = 0; k < bins; k++) {
        float m2 = re[k] * re[k] + im[k] * im[k];
        float thr2 = a->noise[k] * a->thr_scale;
        a->gain[k] = m2 > thr2 && m2 > 0 ? 1.0f - thr2 / m2 : 0.0f;
    }
    shape_gains(a->gain, prev, bins, 0.5f, a->floor, first);
    for (int k = 0; k < bins; k++) {
        re[k] *= a->gain[k];
        im[k] *= a->gain[k];
    }
    return 1;
}

void wd_denoise_adaptive(float *buf, int64_t frames, int channels, int rate, float reduction_db, float sensitivity)
{
    if (frames <= 0 || channels <= 0 || rate <= 0) return;
    int fft = rate >= 32000 ? 2048 : 1024;
    int hop = fft / 4, bins = fft / 2 + 1;
    int sub = (int) (1.5 * rate / hop / MS_SUB);
    if (sub < 2) sub = 2;
    AdaptiveCtx a;
    a.bins = bins;
    a.sub_len = sub;
    a.thr_scale = powf(10.0f, sensitivity / 10.0f);
    a.floor = powf(10.0f, -fabsf(reduction_db) / 20.0f);
    a.power = calloc((size_t) channels * bins, sizeof(float));
    a.mins = calloc((size_t) channels * bins * MS_SUB, sizeof(float));
    a.cur = calloc((size_t) channels * bins, sizeof(float));
    a.pos = calloc(channels, sizeof(int));
    a.slot = calloc(channels, sizeof(int));
    a.prev = calloc((size_t) channels * bins * 2, sizeof(float));
    a.gain = malloc(sizeof(float) * bins);
    a.noise = malloc(sizeof(float) * bins);
    a.last_channel = -1;
    wd__stft_full(buf, frames, channels, fft, hop, adaptive_fn, &a);
    free(a.power);
    free(a.mins);
    free(a.cur);
    free(a.pos);
    free(a.slot);
    free(a.prev);
    free(a.gain);
    free(a.noise);
}

void wd__lpc(const double *x, int n, int order, double *a)
{
    double r[65], tmp[65];
    if (order > 64) order = 64;
    for (int k = 0; k <= order; k++) {
        double s = 0;
        for (int i = k; i < n; i++) s += x[i] * x[i - k];
        r[k] = s;
    }
    r[0] = r[0] * (1.0 + 1e-6) + 1e-12;
    for (int k = 1; k <= order; k++) r[k] *= exp(-0.5 * pow(0.002 * k, 2));
    double err = r[0];
    for (int i = 0; i <= order; i++) a[i] = 0;
    for (int i = 1; i <= order; i++) {
        double acc = r[i];
        for (int j = 1; j < i; j++) acc -= a[j] * r[i - j];
        double k = err > 0 ? acc / err : 0;
        for (int j = 1; j < i; j++) tmp[j] = a[j] - k * a[i - j];
        for (int j = 1; j < i; j++) a[j] = tmp[j];
        a[i] = k;
        err *= (1 - k * k);
        if (err <= 0) break;
    }
}

int wd__lsar(double *x, int len, const double *a, int order, int start, int count)
{
    if (count <= 0 || start < order || start + count + order > len) return 0;
    double c[65];
    c[0] = 1;
    for (int k = 1; k <= order; k++) c[k] = -a[k];
    double *m = calloc((size_t) count * count, sizeof(double));
    double *v = calloc(count, sizeof(double));
    double *row = malloc(sizeof(double) * count);
    for (int n = start; n < start + count + order && n < len; n++) {
        double known = 0;
        for (int j = 0; j < count; j++) row[j] = 0;
        for (int k = 0; k <= order; k++) {
            int idx = n - k;
            if (idx < 0) continue;
            if (idx >= start && idx < start + count) row[idx - start] = c[k];
            else known += c[k] * x[idx];
        }
        for (int i = 0; i < count; i++) {
            if (row[i] == 0) continue;
            v[i] -= row[i] * known;
            for (int j = 0; j < count; j++) m[i * count + j] += row[i] * row[j];
        }
    }
    for (int i = 0; i < count; i++) m[i * count + i] += 1e-12;
    int ok = 1;
    for (int col = 0; col < count; col++) {
        int piv = col;
        for (int r = col + 1; r < count; r++) if (fabs(m[r * count + col]) > fabs(m[piv * count + col])) piv = r;
        if (fabs(m[piv * count + col]) < 1e-18) {
            ok = 0;
            break;
        }
        if (piv != col) {
            for (int j = 0; j < count; j++) {
                double t = m[col * count + j];
                m[col * count + j] = m[piv * count + j];
                m[piv * count + j] = t;
            }
            double t = v[col];
            v[col] = v[piv];
            v[piv] = t;
        }
        for (int r = col + 1; r < count; r++) {
            double f = m[r * count + col] / m[col * count + col];
            if (f == 0) continue;
            for (int j = col; j < count; j++) m[r * count + j] -= f * m[col * count + j];
            v[r] -= f * v[col];
        }
    }
    if (ok) {
        for (int i = count - 1; i >= 0; i--) {
            double s = v[i];
            for (int j = i + 1; j < count; j++) s -= m[i * count + j] * row[j];
            row[i] = s / m[i * count + i];
        }
        for (int i = 0; i < count; i++) x[start + i] = row[i];
    }
    free(m);
    free(v);
    free(row);
    return ok;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *) a, y = *(const double *) b;
    return x < y ? -1 : x > y;
}

int wd_declick(float *buf, int64_t frames, int channels, int rate, float sensitivity)
{
    if (frames <= 0 || channels <= 0) return 0;
    const int order = 16, block = 4096, maxrun = 160;
    if (sensitivity < 0) sensitivity = 0;
    if (sensitivity > 1) sensitivity = 1;
    double k = 4.0 + (1.0 - sensitivity) * 8.0;
    double *x = malloc(sizeof(double) * frames);
    double *e = malloc(sizeof(double) * frames);
    double *tmp = malloc(sizeof(double) * block);
    unsigned char *flag = calloc(frames, 1);
    double *win = malloc(sizeof(double) * (maxrun + 4 * order + 8));
    double a[65];
    int repaired = 0;
    (void) rate;
    for (int ch = 0; ch < channels; ch++) {
        for (int64_t i = 0; i < frames; i++) x[i] = buf[i * channels + ch];
        memset(flag, 0, frames);
        for (int64_t b0 = 0; b0 < frames; b0 += block) {
            int n = (int) (frames - b0 < block ? frames - b0 : block);
            if (n <= order * 2) {
                for (int i = 0; i < n; i++) e[b0 + i] = 0;
                continue;
            }
            wd__lpc(x + b0, n, order, a);
            for (int i = 0; i < n; i++) {
                int64_t t = b0 + i;
                double pr = 0;
                for (int j = 1; j <= order; j++) if (t - j >= 0) pr += a[j] * x[t - j];
                e[t] = x[t] - pr;
                tmp[i] = fabs(e[t]);
            }
            qsort(tmp, n, sizeof(double), cmp_double);
            double mad = tmp[n / 2] * 1.4826;
            double thr = k * mad;
            if (thr < 2e-3) thr = 2e-3;
            for (int i = 0; i < n; i++) if (fabs(e[b0 + i]) > thr) flag[b0 + i] = 1;
        }
        int64_t i = 0;
        while (i < frames) {
            if (!flag[i]) {
                i++;
                continue;
            }
            int64_t s = i, last = i;
            int64_t j = i + 1;
            while (j < frames && j - last <= 4) {
                if (flag[j]) last = j;
                j++;
            }
            int64_t len = last - s + 1;
            i = last + 1;
            if (len > maxrun) continue;
            int64_t ws = s - 2 * order - 2;
            int64_t we = last + 1 + 2 * order + 2;
            if (ws < 0 || we > frames) continue;
            int wl = (int) (we - ws);
            for (int q = 0; q < wl; q++) win[q] = x[ws + q];
            int64_t ab = ws - 1024 > 0 ? ws - 1024 : 0;
            int an = (int) ((we + 1024 < frames ? we + 1024 : frames) - ab);
            if (an > 4 * order) wd__lpc(x + ab, an, order, a);
            if (wd__lsar(win, wl, a, order, (int) (s - ws), (int) len)) {
                for (int q = 0; q < len; q++) {
                    x[s + q] = win[s - ws + q];
                    buf[(s + q) * channels + ch] = (float) win[s - ws + q];
                }
                repaired++;
            }
        }
    }
    free(x);
    free(e);
    free(tmp);
    free(flag);
    free(win);
    return repaired;
}

void wd_dehum(float *buf, int64_t frames, int channels, int rate, float base_hz, int harmonics, float q)
{
    if (frames <= 0 || channels <= 0 || rate <= 0 || base_hz <= 0) return;
    if (harmonics < 1) harmonics = 1;
    if (harmonics > 64) harmonics = 64;
    if (q <= 0) q = 30;
    WdBiquadCoef coef[64];
    int count = 0;
    for (int h = 1; h <= harmonics; h++) {
        double f = base_hz * h;
        if (f >= rate * 0.45) break;
        wd__biquad_design(&coef[count++], WD_BAND_NOTCH, rate, f, 0, q);
    }
    for (int ch = 0; ch < channels; ch++) {
        WdBiquadState st[64];
        memset(st, 0, sizeof(st));
        for (int64_t i = 0; i < frames; i++) {
            double v = buf[i * channels + ch];
            for (int c = 0; c < count; c++) v = wd__biquad_tick(&coef[c], &st[c], v);
            buf[i * channels + ch] = (float) v;
        }
    }
}

int wd_declip(float *buf, int64_t frames, int channels, float threshold)
{
    if (frames <= 0 || channels <= 0) return 0;
    threshold = fabsf(threshold);
    if (threshold <= 0) return 0;
    int runs = 0;
    for (int ch = 0; ch < channels; ch++) {
        int64_t i = 2;
        while (i < frames - 2) {
            float v = buf[i * channels + ch];
            if (fabsf(v) < threshold) {
                i++;
                continue;
            }
            float sign = v > 0 ? 1.0f : -1.0f;
            int64_t s = i, e = i;
            while (e < frames && buf[e * channels + ch] * sign >= threshold) e++;
            i = e;
            if (e - s < 2 || s < 2 || e + 1 >= frames) continue;
            double p0 = buf[(s - 1) * channels + ch];
            double p1 = buf[e * channels + ch];
            double m0 = p0 - buf[(s - 2) * channels + ch];
            double m1 = buf[(e + 1) * channels + ch] - p1;
            double L = (double) (e - (s - 1));
            for (int64_t t = s; t < e; t++) {
                double u = (t - (s - 1)) / L;
                double u2 = u * u, u3 = u2 * u;
                double val = (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * L * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * L * m1;
                if (val * sign < threshold) val = sign * threshold;
                buf[t * channels + ch] = (float) val;
            }
            runs++;
        }
    }
    return runs;
}

typedef struct {
    int bins;
    int delay;
    float decay;
    float amount;
    float floor;
    float *hist;
    int *pos;
    float *prev;
    float *gain;
    int last_channel;
} DereverbCtx;

static int dereverb_fn(void *ctx, int channel, int column, float *re, float *im, int bins)
{
    DereverbCtx *d = ctx;
    int D = d->delay;
    float *hist = d->hist + (int64_t) channel * bins * (D + 1);
    float *prev = d->prev + (int64_t) channel * bins * 2;
    int first = d->last_channel != channel;
    d->last_channel = channel;
    if (first) {
        memset(hist, 0, sizeof(float) * bins * (D + 1));
        d->pos[channel] = 0;
    }
    int p = d->pos[channel];
    int old = (p + 1) % (D + 1);
    for (int k = 0; k < bins; k++) {
        float m2 = re[k] * re[k] + im[k] * im[k];
        float late = d->decay * hist[old * bins + k];
        hist[p * bins + k] = m2;
        float g = m2 > 0 ? 1.0f - d->amount * late / m2 : 1.0f;
        d->gain[k] = g;
    }
    d->pos[channel] = (p + 1) % (D + 1);
    shape_gains(d->gain, prev, bins, 0.3f, d->floor, first);
    for (int k = 0; k < bins; k++) {
        re[k] *= d->gain[k];
        im[k] *= d->gain[k];
    }
    return 1;
}

void wd_dereverb(float *buf, int64_t frames, int channels, int rate, float amount)
{
    if (frames <= 0 || channels <= 0 || rate <= 0) return;
    if (amount <= 0) return;
    if (amount > 1) amount = 1;
    int fft = rate >= 32000 ? 2048 : 1024;
    int hop = fft / 4, bins = fft / 2 + 1;
    int D = (int) lround(0.05 * rate / hop);
    if (D < 1) D = 1;
    double rt60 = 0.6;
    double delta = 3 * log(10) / rt60;
    DereverbCtx d;
    d.bins = bins;
    d.delay = D;
    d.decay = (float) exp(-2 * delta * D * hop / (double) rate);
    d.amount = amount * 1.5f;
    d.floor = powf(10.0f, -amount * 15.0f / 20.0f);
    d.hist = calloc((size_t) channels * bins * (D + 1), sizeof(float));
    d.pos = calloc(channels, sizeof(int));
    d.prev = calloc((size_t) channels * bins * 2, sizeof(float));
    d.gain = malloc(sizeof(float) * bins);
    d.last_channel = -1;
    wd__stft_full(buf, frames, channels, fft, hop, dereverb_fn, &d);
    free(d.hist);
    free(d.pos);
    free(d.prev);
    free(d.gain);
}
