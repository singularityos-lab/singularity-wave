#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

uint32_t wd__rand(uint32_t *state)
{
    uint32_t x = *state ? *state : 0x12345678u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

double wd__randf(uint32_t *state)
{
    return wd__rand(state) / 4294967296.0;
}

void wd_gain(float *buf, int64_t samples, float gain_db)
{
    float g = powf(10.0f, gain_db / 20.0f);
    for (int64_t i = 0; i < samples; i++) buf[i] *= g;
}

float wd_peak(const float *buf, int64_t samples)
{
    float p = 0;
    for (int64_t i = 0; i < samples; i++) {
        float a = fabsf(buf[i]);
        if (a > p) p = a;
    }
    return p;
}

double wd_rms(const float *buf, int64_t samples)
{
    if (samples <= 0) return 0;
    double s = 0;
    for (int64_t i = 0; i < samples; i++) s += (double) buf[i] * buf[i];
    return sqrt(s / samples);
}

float wd_fade_gain(double t, int curve)
{
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    switch (curve) {
    case 1:
        return (float) pow(10, -60 * (1 - t) / 20) * (float) (t < 0.02 ? t / 0.02 : 1);
    case 2:
        return (float) (0.5 - 0.5 * cos(M_PI * t));
    case 3:
        return (float) ((exp(4 * t) - 1) / (exp(4) - 1));
    default:
        return (float) t;
    }
}

void wd_fade(float *buf, int64_t frames, int channels, int fade_in, int curve)
{
    if (frames <= 0 || channels <= 0) return;
    for (int64_t i = 0; i < frames; i++) {
        double t = frames > 1 ? (double) i / (frames - 1) : 1.0;
        float g = wd_fade_gain(fade_in ? t : 1 - t, curve);
        for (int ch = 0; ch < channels; ch++) buf[i * channels + ch] *= g;
    }
}

static void quantize_one(double v, int bits, int dither, int shaping, double *err, uint32_t *seed, void *out, int64_t i)
{
    double scale = ldexp(1.0, bits - 1);
    double lo = -scale, hi = scale - 1;
    double w = v * scale;
    if (shaping) w -= *err;
    double d = dither ? (wd__randf(seed) + wd__randf(seed) - 1.0) : 0.0;
    double q = floor(w + d + 0.5);
    if (q < lo) q = lo;
    if (q > hi) q = hi;
    if (shaping) {
        *err = q - w;
        if (*err > 4) *err = 4;
        if (*err < -4) *err = -4;
    }
    if (bits == 16) {
        ((int16_t *) out)[i] = (int16_t) q;
    } else if (bits == 24) {
        int32_t s = (int32_t) q;
        uint8_t *o = (uint8_t *) out + i * 3;
        o[0] = (uint8_t) (s & 0xff);
        o[1] = (uint8_t) ((s >> 8) & 0xff);
        o[2] = (uint8_t) ((s >> 16) & 0xff);
    } else {
        ((int32_t *) out)[i] = (int32_t) q;
    }
}

void wd_quantize(const float *in, int64_t samples, int bits, int dither, int shaping, uint32_t *seed, void *out)
{
    wd_quantize_frames(in, samples, 1, bits, dither, shaping, seed, out);
}

void wd_quantize_frames(const float *in, int64_t frames, int channels, int bits, int dither, int shaping, uint32_t *seed, void *out)
{
    if (frames <= 0 || channels <= 0 || !out) return;
    if (bits != 16 && bits != 24) bits = 32;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    uint32_t local = 0;
    if (!seed) seed = &local;
    double err[WD_MAX_CHANNELS] = { 0 };
    for (int64_t f = 0; f < frames; f++)
        for (int ch = 0; ch < channels; ch++) {
            int64_t i = f * channels + ch;
            quantize_one(in[i], bits, dither, shaping, &err[ch], seed, out, i);
        }
}

#define RS_ZERO 32
#define RS_RES 512

static double kaiser_k(double x, double beta)
{
    double sum = 1, term = 1;
    double y = beta * sqrt(x > 1 ? 0 : 1 - x * x);
    for (int k = 1; k < 30; k++) {
        term *= (y / (2 * k)) * (y / (2 * k));
        sum += term;
    }
    return sum;
}

int64_t wd__resample_ratio(const float *in, int64_t frames, int channels, double factor, float *out, int64_t out_frames)
{
    if (!in || !out || frames <= 0 || channels <= 0 || factor <= 0 || out_frames <= 0) return 0;
    int tlen = RS_ZERO * RS_RES + 2;
    float *table = malloc(sizeof(float) * tlen);
    double beta = 8.6;
    double base = kaiser_k(0, beta);
    for (int i = 0; i < tlen; i++) {
        double x = (double) i / RS_RES;
        double s = x < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
        double r = x / RS_ZERO;
        double w = r >= 1 ? 0 : kaiser_k(r, beta) / base;
        table[i] = (float) (s * w);
    }
    double fc = factor < 1 ? factor * 0.97 : 0.97;
    double reach = RS_ZERO / fc;
    double norm = fc;
    double acc[WD_MAX_CHANNELS];
    int nch = channels > WD_MAX_CHANNELS ? WD_MAX_CHANNELS : channels;
    for (int64_t i = 0; i < out_frames; i++) {
        double t = i / factor;
        int64_t j0 = (int64_t) ceil(t - reach);
        int64_t j1 = (int64_t) floor(t + reach);
        if (j0 < 0) j0 = 0;
        if (j1 > frames - 1) j1 = frames - 1;
        for (int ch = 0; ch < nch; ch++) acc[ch] = 0;
        for (int64_t j = j0; j <= j1; j++) {
            double x = fabs(t - j) * fc * RS_RES;
            int xi = (int) x;
            if (xi >= tlen - 1) continue;
            double fr = x - xi;
            double h = (table[xi] + (table[xi + 1] - table[xi]) * fr) * norm;
            const float *src = in + j * channels;
            for (int ch = 0; ch < nch; ch++) acc[ch] += h * src[ch];
        }
        for (int ch = 0; ch < nch; ch++) out[i * channels + ch] = (float) acc[ch];
        for (int ch = nch; ch < channels; ch++) out[i * channels + ch] = 0;
    }
    free(table);
    return out_frames;
}

int64_t wd_resample_frames(int64_t frames, int from_rate, int to_rate)
{
    if (frames <= 0 || from_rate <= 0 || to_rate <= 0) return 0;
    return (int64_t) llround((double) frames * to_rate / from_rate);
}

int64_t wd_resample(const float *in, int64_t frames, int channels, int from_rate, int to_rate, float *out, int64_t out_capacity)
{
    int64_t n = wd_resample_frames(frames, from_rate, to_rate);
    if (n > out_capacity) n = out_capacity;
    if (n <= 0) return 0;
    if (from_rate == to_rate) {
        memcpy(out, in, sizeof(float) * n * channels);
        return n;
    }
    return wd__resample_ratio(in, frames, channels, (double) to_rate / from_rate, out, n);
}

static int next_pow2(int n)
{
    int p = 64;
    while (p < n && p < 8192) p <<= 1;
    return p;
}

int wd_vad(const float *mono, int64_t frames, int rate, int frame_ms, uint8_t *flags, int max_flags)
{
    if (!mono || frames <= 0 || rate <= 0 || !flags || max_flags <= 0) return 0;
    if (frame_ms < 5) frame_ms = 5;
    int F = rate * frame_ms / 1000;
    if (F < 16) F = 16;
    int64_t count = frames / F;
    if (count > max_flags) count = max_flags;
    int N = next_pow2(F);
    float *re = malloc(sizeof(float) * N);
    float *im = malloc(sizeof(float) * N);
    float *w = malloc(sizeof(float) * N);
    wd_window_fill(w, N, WD_WINDOW_HANN);
    int k0 = (int) (100.0 * N / rate), k1 = (int) (4000.0 * N / rate);
    if (k0 < 1) k0 = 1;
    if (k1 > N / 2) k1 = N / 2;
    double floor_db = 0;
    int hang = 0, hang_len = 200 / frame_ms;
    double rise = 0.005 * frame_ms;
    for (int64_t f = 0; f < count; f++) {
        const float *x = mono + f * F;
        double e = 0;
        int zc = 0;
        for (int i = 0; i < F; i++) {
            e += (double) x[i] * x[i];
            if (i > 0 && ((x[i] >= 0) != (x[i - 1] >= 0))) zc++;
        }
        e /= F;
        double edb = 10 * log10(e + 1e-12);
        for (int i = 0; i < N; i++) {
            re[i] = i < F ? x[i] * w[i] : 0;
            im[i] = 0;
        }
        wd_fft(re, im, N, 0);
        double lg = 0, ar = 0;
        int nb = 0;
        for (int k = k0; k <= k1; k++) {
            double p = (double) re[k] * re[k] + (double) im[k] * im[k] + 1e-12;
            lg += log(p);
            ar += p;
            nb++;
        }
        double flat = nb > 0 ? exp(lg / nb) / (ar / nb) : 1;
        double zcr = (double) zc / F;
        if (f == 0) floor_db = edb;
        if (edb < floor_db) floor_db = edb;
        else floor_db += rise;
        int speech = edb > floor_db + 9 && edb > -60 && flat < 0.6 && zcr < 0.35;
        if (speech) {
            hang = hang_len;
            flags[f] = 1;
        } else if (hang > 0) {
            hang--;
            flags[f] = 1;
        } else {
            flags[f] = 0;
        }
    }
    free(re);
    free(im);
    free(w);
    return (int) count;
}

static double clamp01(double v)
{
    return v < 0 ? 0 : v > 1 ? 1 : v;
}

static int cmp_double(const void *a, const void *b)
{
    double x = *(const double *) a, y = *(const double *) b;
    return x < y ? -1 : x > y ? 1 : 0;
}

static double cl01(double v)
{
    return v < 0 ? 0 : v > 1 ? 1 : v;
}

void wd_classify(const float *mono, int64_t frames, int rate, float *scores)
{
    scores[0] = scores[1] = scores[2] = scores[3] = 0.25f;
    if (!mono || frames <= 0 || rate <= 0) return;
    int hop = rate / 100;
    int F = rate * 3 / 100;
    int64_t nf = frames > F ? (frames - F) / hop + 1 : 0;
    if (nf < 20) return;
    int N = next_pow2(F);
    int bins = N / 2 + 1;
    float *re = malloc(sizeof(float) * N);
    float *im = malloc(sizeof(float) * N);
    float *w = malloc(sizeof(float) * N);
    double *edb = malloc(sizeof(double) * nf);
    unsigned char *voiced = malloc(nf);
    double *flat = malloc(sizeof(double) * nf);
    wd_window_fill(w, N, WD_WINDOW_HANN);
    int lag0 = rate / 500, lag1 = rate / 70;
    double max_db = -200;
    for (int64_t f = 0; f < nf; f++) {
        const float *x = mono + f * hop;
        double e = 0;
        for (int i = 0; i < F; i++) e += (double) x[i] * x[i];
        e /= F;
        edb[f] = 10 * log10(e + 1e-12);
        if (edb[f] > max_db) max_db = edb[f];
        double best = 0;
        int n = F - lag1;
        if (n > 32 && e > 1e-9) {
            for (int lag = lag0; lag <= lag1; lag++) {
                double sxy = 0, sxx = 0, syy = 0;
                for (int i = 0; i < n; i += 2) {
                    sxy += (double) x[i] * x[i + lag];
                    sxx += (double) x[i] * x[i];
                    syy += (double) x[i + lag] * x[i + lag];
                }
                double c = sxy / (sqrt(sxx * syy) + 1e-12);
                if (c > best) best = c;
            }
        }
        voiced[f] = best > 0.75;
        for (int i = 0; i < N; i++) {
            re[i] = i < F ? x[i] * w[i] : 0;
            im[i] = 0;
        }
        wd_fft(re, im, N, 0);
        double lg = 0, ar = 0;
        int cnt = 0;
        for (int k = 2; k < bins; k++) {
            double p = (double) re[k] * re[k] + (double) im[k] * im[k] + 1e-20;
            lg += log(p);
            ar += p;
            cnt++;
        }
        flat[f] = cnt > 0 ? exp(lg / cnt) / (ar / cnt) : 0;
    }
    double *sorted = malloc(sizeof(double) * nf);
    memcpy(sorted, edb, sizeof(double) * nf);
    qsort(sorted, nf, sizeof(double), cmp_double);
    double p10 = sorted[nf / 10];
    double p95 = sorted[nf * 95 / 100];
    free(sorted);
    double floor_db = p10 + 6;
    if (floor_db > max_db - 12) floor_db = max_db - 12;
    if (floor_db < max_db - 40) floor_db = max_db - 40;
    if (floor_db < -65) floor_db = -65;
    int64_t act = 0, vc = 0, sw = 0;
    double mean_db = 0, flat_sum = 0;
    int last = -1;
    for (int64_t f = 0; f < nf; f++) {
        if (edb[f] < floor_db) continue;
        act++;
        mean_db += edb[f];
        flat_sum += flat[f];
        if (voiced[f]) vc++;
        if (last >= 0 && last != voiced[f]) sw++;
        last = voiced[f];
    }
    if (act < 10) {
        scores[0] = scores[1] = scores[2] = 0.05f;
        scores[3] = 0.85f;
        goto done;
    }
    mean_db /= act;
    double var = 0;
    for (int64_t f = 0; f < nf; f++) {
        if (edb[f] < floor_db) continue;
        var += (edb[f] - mean_db) * (edb[f] - mean_db);
    }
    double lstd = sqrt(var / act);
    double ar = (double) act / nf;
    double vf = (double) vc / act;
    double swr = sw / ((double) act * hop / rate);
    double fl = flat_sum / act;
    double m_in = 0, m_all = 0;
    double env_mean = 0;
    for (int64_t f = 0; f < nf; f++) env_mean += edb[f] < floor_db ? floor_db : edb[f];
    env_mean /= nf;
    for (double fr = 0.5; fr <= 20.0; fr += 0.25) {
        double cr = 0, ci = 0;
        for (int64_t f = 0; f < nf; f++) {
            double v = (edb[f] < floor_db ? floor_db : edb[f]) - env_mean;
            double ang = 2 * M_PI * fr * f / 100.0;
            cr += v * cos(ang);
            ci += v * sin(ang);
        }
        double p = cr * cr + ci * ci;
        m_all += p;
        if (fr >= 3 && fr <= 8) m_in += p;
    }
    double mod = m_all > 0 ? m_in / m_all : 0;
    double vbell = 1 - fabs(vf - 0.55) / 0.45;
    double s[4];
    double dyn = cl01((p95 - p10 - 8) / 12);
    double tonal = cl01((0.008 - fl) / 0.006);
    double flicker = cl01((swr - 15) / 10);
    s[0] = 2.0 * dyn + 1.0 * cl01(vbell) + 1.0 * cl01((swr - 3) / 6) * (1 - flicker) + 1.0 * cl01((ar - 0.2) / 0.3) - 2.0 * tonal * flicker;
    s[1] = 2.0 * tonal + 2.0 * flicker + 0.5 * (1 - dyn);
    s[2] = 1.5 * dyn + 2.0 * cl01((0.25 - ar) / 0.15) + 1.0 * cl01((0.5 - vf) / 0.5);
    s[3] = 2.0 * (1 - dyn) + 2.0 * cl01((ar - 0.85) / 0.15) + 1.0 * cl01((fl - 0.01) / 0.03) - 2.0 * flicker - 2.0 * tonal;
    double mx = s[0];
    for (int i = 1; i < 4; i++) if (s[i] > mx) mx = s[i];
    double sum = 0, e4[4];
    for (int i = 0; i < 4; i++) {
        e4[i] = exp(2.5 * (s[i] - mx));
        sum += e4[i];
    }
    for (int i = 0; i < 4; i++) scores[i] = (float) (e4[i] / sum);
done:
    free(re);
    free(im);
    free(w);
    free(edb);
    free(voiced);
    free(flat);
}
