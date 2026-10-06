#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

#define SHIFT_WINDOW_MS 40.0
#define AN_SIZE 2048
#define AN_HOP 512

float wd__yin(const float *x, int n, int rate, float min_hz, float max_hz, float threshold, float *work)
{
    int tmin = (int) (rate / max_hz);
    int tmax = (int) (rate / min_hz);
    if (tmin < 2) tmin = 2;
    int W = n - tmax;
    if (W < 64) {
        tmax = n / 2;
        W = n - tmax;
        if (W < 32 || tmax <= tmin + 2) return 0;
    }
    double energy = 0;
    for (int j = 0; j < W; j++) energy += (double) x[j] * x[j];
    if (energy / W < 1e-8) return 0;
    work[0] = 1;
    double run = 0;
    for (int tau = 1; tau <= tmax; tau++) {
        double s = 0;
        for (int j = 0; j < W; j++) {
            double d = x[j] - x[j + tau];
            s += d * d;
        }
        run += s;
        work[tau] = run > 0 ? (float) (s * tau / run) : 1.0f;
    }
    int best = -1;
    for (int tau = tmin; tau < tmax; tau++) {
        if (work[tau] < threshold) {
            while (tau + 1 < tmax && work[tau + 1] < work[tau]) tau++;
            best = tau;
            break;
        }
    }
    if (best < 0) return 0;
    double t = best;
    if (best > 1 && best < tmax) {
        double a = work[best - 1], b = work[best], c = work[best + 1];
        double den = a - 2 * b + c;
        if (fabs(den) > 1e-12) t = best + 0.5 * (a - c) / den;
    }
    return (float) (rate / t);
}

float wd_detect_pitch(const float *mono, int frames, int rate)
{
    if (!mono || frames <= 0 || rate <= 0) return 0;
    int tmax = rate / 50;
    int n = frames < tmax + 2048 ? frames : tmax + 2048;
    float *work = malloc(sizeof(float) * (tmax + 2));
    float f = wd__yin(mono, n, rate, 50, 1000, 0.15f, work);
    free(work);
    return f;
}

struct _WdPitch {
    int rate;
    int channels;
    float semitones, mix;
    int corr;
    int key, scale;
    float speed, reference;
    double corr_ratio;
    float detected;
    int len;
    float *line;
    int pos;
    double phase;
    double window;
    float an[AN_SIZE];
    float lin[AN_SIZE];
    int an_pos;
    int an_count;
    float *work;
};

WdPitch *wd_pitch_new(int rate, int channels)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    WdPitch *p = calloc(1, sizeof(WdPitch));
    p->rate = rate > 0 ? rate : 48000;
    p->channels = channels;
    p->window = SHIFT_WINDOW_MS * 0.001 * p->rate;
    p->len = (int) p->window + 8;
    p->line = calloc((size_t) p->len * channels, sizeof(float));
    p->work = calloc(p->rate / 60 + AN_SIZE, sizeof(float));
    p->corr_ratio = 1;
    p->mix = 1;
    p->reference = 440;
    p->speed = 1;
    return p;
}

void wd_pitch_free(WdPitch *p)
{
    if (!p) return;
    free(p->line);
    free(p->work);
    free(p);
}

void wd_pitch_set(WdPitch *p, float semitones, float mix)
{
    if (!p) return;
    p->semitones = semitones < -24 ? -24 : semitones > 24 ? 24 : semitones;
    p->mix = mix < 0 ? 0 : mix > 1 ? 1 : mix;
}

void wd_pitch_set_correction(WdPitch *p, int enabled, int key, int scale, float speed, float reference_hz)
{
    if (!p) return;
    p->corr = enabled != 0;
    p->key = ((key % 12) + 12) % 12;
    p->scale = scale;
    p->speed = speed < 0 ? 0 : speed > 1 ? 1 : speed;
    p->reference = reference_hz > 0 ? reference_hz : 440;
}

float wd_pitch_detected_hz(WdPitch *p)
{
    return p ? p->detected : 0;
}

void wd_pitch_reset(WdPitch *p)
{
    if (!p) return;
    memset(p->line, 0, sizeof(float) * (size_t) p->len * p->channels);
    memset(p->an, 0, sizeof(p->an));
    p->pos = 0;
    p->phase = 0;
    p->an_pos = 0;
    p->an_count = 0;
    p->corr_ratio = 1;
    p->detected = 0;
}

static int in_scale(int note, int key, int scale)
{
    static const int major[12] = { 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1 };
    static const int minor[12] = { 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0 };
    int d = ((note - key) % 12 + 12) % 12;
    if (scale == 1) return major[d];
    if (scale == 2) return minor[d];
    return 1;
}

static void analyse(WdPitch *p)
{
    for (int i = 0; i < AN_SIZE; i++) p->lin[i] = p->an[(p->an_pos + i) % AN_SIZE];
    float f = wd__yin(p->lin, AN_SIZE, p->rate, 60, 1000, 0.15f, p->work);
    p->detected = f;
    if (f <= 0) return;
    double midi = 69 + 12 * log2(f / p->reference);
    int base = (int) floor(midi);
    int best = base;
    double bestd = 1e9;
    for (int n = base - 6; n <= base + 7; n++) {
        if (!in_scale(n, p->key, p->scale)) continue;
        double d = fabs(n - midi);
        if (d < bestd) {
            bestd = d;
            best = n;
        }
    }
    double target = p->reference * pow(2, (best - 69) / 12.0) / f;
    p->corr_ratio += (target - p->corr_ratio) * p->speed;
}

void wd_pitch_process(WdPitch *p, float *buf, int frames)
{
    if (!p || frames <= 0) return;
    int nch = p->channels;
    double W = p->window;
    for (int i = 0; i < frames; i++) {
        float *f = buf + (size_t) i * nch;
        if (p->corr) {
            float mono = 0;
            for (int ch = 0; ch < nch; ch++) mono += f[ch];
            p->an[p->an_pos] = mono / nch;
            p->an_pos = (p->an_pos + 1) % AN_SIZE;
            if (++p->an_count >= AN_HOP) {
                p->an_count = 0;
                analyse(p);
            }
        }
        double ratio = pow(2, p->semitones / 12.0) * (p->corr ? p->corr_ratio : 1.0);
        double ph1 = p->phase, ph2 = fmod(p->phase + 0.5, 1.0);
        double d1 = ph1 * W, d2 = ph2 * W;
        double s1 = sin(M_PI * ph1), s2 = sin(M_PI * ph2);
        float g1 = (float) (s1 * s1), g2 = (float) (s2 * s2);
        for (int ch = 0; ch < nch; ch++) p->line[(size_t) p->pos * nch + ch] = f[ch];
        for (int ch = 0; ch < nch; ch++) {
            float out = 0;
            for (int t = 0; t < 2; t++) {
                double rp = p->pos - (t == 0 ? d1 : d2);
                while (rp < 0) rp += p->len;
                int i0 = (int) rp;
                float fr = (float) (rp - i0);
                int i1 = (i0 + 1) % p->len;
                float a = p->line[(size_t) i0 * nch + ch], b = p->line[(size_t) i1 * nch + ch];
                out += (a + (b - a) * fr) * (t == 0 ? g1 : g2);
            }
            f[ch] = f[ch] * (1 - p->mix) + out * p->mix;
        }
        p->phase += (1 - ratio) / W;
        p->phase -= floor(p->phase);
        if (++p->pos >= p->len) p->pos = 0;
    }
}

int64_t wd_stretch_frames(int64_t frames, double ratio)
{
    if (frames <= 0 || ratio <= 0) return 0;
    return (int64_t) llround(frames * ratio);
}

static double wrap(double a)
{
    return a - 2 * M_PI * floor((a + M_PI) / (2 * M_PI));
}

static void stretch_channel(const float *in, int64_t frames, int channels, int ch, double r, int N, float *out, int64_t S, double *norm)
{
    int Hs = N / 4, bins = N / 2 + 1, half = N / 2;
    float *w = malloc(sizeof(float) * N);
    float *re = malloc(sizeof(float) * N);
    float *im = malloc(sizeof(float) * N);
    double *pa = calloc(bins, sizeof(double));
    double *pa_prev = calloc(bins, sizeof(double));
    double *ps = calloc(bins, sizeof(double));
    float *mag = malloc(sizeof(float) * bins);
    int *peak_of = malloc(sizeof(int) * bins);
    int *peaks = malloc(sizeof(int) * bins);
    wd_window_fill(w, N, WD_WINDOW_HANN);
    int64_t K = S / Hs + 2;
    int64_t ca_prev = 0;
    for (int64_t k = 0; k < K; k++) {
        int64_t ts = k * Hs;
        int64_t ca = (int64_t) llround(ts / r);
        for (int i = 0; i < N; i++) {
            int64_t q = ca - half + i;
            re[i] = (q >= 0 && q < frames) ? in[q * channels + ch] * w[i] : 0.0f;
            im[i] = 0;
        }
        wd_fft(re, im, N, 0);
        for (int b = 0; b < bins; b++) {
            mag[b] = sqrtf(re[b] * re[b] + im[b] * im[b]);
            pa[b] = atan2(im[b], re[b]);
        }
        if (k == 0) {
            for (int b = 0; b < bins; b++) ps[b] = pa[b];
        } else {
            int64_t Ha = ca - ca_prev;
            int np = 0;
            for (int b = 2; b < bins - 2; b++) {
                if (mag[b] > mag[b - 1] && mag[b] >= mag[b + 1] && mag[b] > mag[b - 2] && mag[b] >= mag[b + 2]) peaks[np++] = b;
            }
            if (np == 0) {
                for (int b = 0; b < bins; b++) {
                    double om = 2 * M_PI * b / N;
                    double tf = Ha > 0 ? om + wrap(pa[b] - pa_prev[b] - om * Ha) / Ha : om;
                    ps[b] += tf * Hs;
                }
            } else {
                for (int j = 0; j < np; j++) {
                    int b = peaks[j];
                    double om = 2 * M_PI * b / N;
                    double tf = Ha > 0 ? om + wrap(pa[b] - pa_prev[b] - om * Ha) / Ha : om;
                    ps[b] += tf * Hs;
                }
                int j = 0;
                for (int b = 0; b < bins; b++) {
                    while (j + 1 < np && abs(peaks[j + 1] - b) < abs(peaks[j] - b)) j++;
                    peak_of[b] = peaks[j];
                }
                for (int b = 0; b < bins; b++) {
                    int pk = peak_of[b];
                    if (pk == b) continue;
                    ps[b] = ps[pk] + pa[b] - pa[pk];
                }
            }
        }
        for (int b = 0; b < bins; b++) {
            re[b] = (float) (mag[b] * cos(ps[b]));
            im[b] = (float) (mag[b] * sin(ps[b]));
        }
        im[0] = 0;
        im[half] = 0;
        for (int b = 1; b < half; b++) {
            re[N - b] = re[b];
            im[N - b] = -im[b];
        }
        wd_fft(re, im, N, 1);
        for (int i = 0; i < N; i++) {
            int64_t q = ts - half + i;
            if (q < 0 || q >= S) continue;
            out[q * channels + ch] += re[i] * w[i];
            if (ch == 0) norm[q] += (double) w[i] * w[i];
        }
        double *t = pa_prev;
        pa_prev = pa;
        pa = t;
        for (int b = 0; b < bins; b++) ps[b] = wrap(ps[b]);
        ca_prev = ca;
    }
    free(w);
    free(re);
    free(im);
    free(pa);
    free(pa_prev);
    free(ps);
    free(mag);
    free(peak_of);
    free(peaks);
}

int64_t wd_time_stretch(const float *in, int64_t frames, int channels, int rate, double ratio, double semitones, float *out, int64_t out_capacity)
{
    if (!in || !out || frames <= 0 || channels <= 0 || ratio <= 0) return 0;
    int64_t F = wd_stretch_frames(frames, ratio);
    if (F > out_capacity) F = out_capacity;
    double p = pow(2, semitones / 12.0);
    double r = ratio * p;
    if (fabs(r - 1) < 1e-9 && fabs(p - 1) < 1e-9) {
        for (int64_t i = 0; i < F * channels; i++) out[i] = i < frames * channels ? in[i] : 0;
        return F;
    }
    int N = rate >= 32000 ? 2048 : 1024;
    int64_t S = (int64_t) llround(frames * r);
    if (S < 1) S = 1;
    float *st = calloc((size_t) S * channels, sizeof(float));
    double *norm = calloc(S, sizeof(double));
    for (int ch = 0; ch < channels; ch++) stretch_channel(in, frames, channels, ch, r, N, st, S, norm);
    for (int64_t q = 0; q < S; q++) {
        double nv = norm[q] > 1e-3 ? norm[q] : 1e-3;
        for (int ch = 0; ch < channels; ch++) st[q * channels + ch] = (float) (st[q * channels + ch] / nv);
    }
    int64_t written;
    if (fabs(p - 1) < 1e-9) {
        written = F < S ? F : S;
        memcpy(out, st, sizeof(float) * written * channels);
        for (int64_t i = written * channels; i < F * channels; i++) out[i] = 0;
        written = F;
    } else {
        written = wd__resample_ratio(st, S, channels, (double) F / S, out, F);
    }
    free(st);
    free(norm);
    return written;
}
