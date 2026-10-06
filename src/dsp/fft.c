#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

int wd__is_pow2(int n)
{
    return n > 1 && (n & (n - 1)) == 0;
}

void wd_fft(float *re, float *im, int n, int inverse)
{
    if (!wd__is_pow2(n)) return;
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = re[i];
            re[i] = re[j];
            re[j] = t;
            t = im[i];
            im[i] = im[j];
            im[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        double ang = 2 * M_PI / len * (inverse ? 1 : -1);
        double wr = cos(ang), wi = sin(ang);
        int half = len >> 1;
        for (int i = 0; i < n; i += len) {
            double cr = 1, ci = 0;
            for (int k = 0; k < half; k++) {
                int a = i + k, b = a + half;
                double tr = re[b] * cr - im[b] * ci;
                double ti = re[b] * ci + im[b] * cr;
                re[b] = (float) (re[a] - tr);
                im[b] = (float) (im[a] - ti);
                re[a] = (float) (re[a] + tr);
                im[a] = (float) (im[a] + ti);
                double ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
    if (inverse) {
        float s = 1.0f / n;
        for (int i = 0; i < n; i++) {
            re[i] *= s;
            im[i] *= s;
        }
    }
}

void wd_window_fill(float *w, int n, WdWindow kind)
{
    for (int i = 0; i < n; i++) {
        double x = 2 * M_PI * i / n;
        switch (kind) {
        case WD_WINDOW_HAMMING:
            w[i] = (float) (0.54 - 0.46 * cos(x));
            break;
        case WD_WINDOW_BLACKMAN_HARRIS:
            w[i] = (float) (0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x));
            break;
        case WD_WINDOW_RECTANGULAR:
            w[i] = 1.0f;
            break;
        default:
            w[i] = (float) (0.5 - 0.5 * cos(x));
            break;
        }
    }
}

static float to_db(double mag)
{
    if (mag <= 1e-7) return -140.0f;
    double d = 20 * log10(mag);
    return d < -140 ? -140.0f : (float) d;
}

int wd_spectrogram(const float *mono, int64_t frames, int fft_size, int hop, WdWindow window, float *out_db, int max_columns)
{
    if (frames <= 0 || !wd__is_pow2(fft_size) || hop <= 0 || max_columns <= 0) return 0;
    int64_t cols = (frames + hop - 1) / hop;
    if (cols > max_columns) cols = max_columns;
    int bins = fft_size / 2 + 1;
    float *w = malloc(sizeof(float) * fft_size);
    float *re = malloc(sizeof(float) * fft_size);
    float *im = malloc(sizeof(float) * fft_size);
    wd_window_fill(w, fft_size, window);
    double sum = 0;
    for (int i = 0; i < fft_size; i++) sum += w[i];
    double norm = sum > 0 ? 2.0 / sum : 1.0;
    int half = fft_size / 2;
    for (int64_t c = 0; c < cols; c++) {
        int64_t b = c * hop - half;
        for (int i = 0; i < fft_size; i++) {
            int64_t p = b + i;
            re[i] = (p >= 0 && p < frames) ? mono[p] * w[i] : 0.0f;
            im[i] = 0;
        }
        wd_fft(re, im, fft_size, 0);
        float *o = out_db + c * bins;
        for (int k = 0; k < bins; k++) o[k] = to_db(sqrt((double) re[k] * re[k] + (double) im[k] * im[k]) * norm);
    }
    free(w);
    free(re);
    free(im);
    return (int) cols;
}

void wd_spectrum_average(const float *mono, int64_t frames, int fft_size, WdWindow window, float *out_db)
{
    if (!wd__is_pow2(fft_size)) return;
    int bins = fft_size / 2 + 1;
    double *acc = calloc(bins, sizeof(double));
    float *w = malloc(sizeof(float) * fft_size);
    float *re = malloc(sizeof(float) * fft_size);
    float *im = malloc(sizeof(float) * fft_size);
    wd_window_fill(w, fft_size, window);
    double sum = 0;
    for (int i = 0; i < fft_size; i++) sum += w[i];
    double norm = sum > 0 ? 2.0 / sum : 1.0;
    int hop = fft_size / 2;
    int64_t count = 0;
    for (int64_t b = 0; b == 0 || b + fft_size <= frames; b += hop) {
        for (int i = 0; i < fft_size; i++) {
            int64_t p = b + i;
            re[i] = p < frames ? mono[p] * w[i] : 0.0f;
            im[i] = 0;
        }
        wd_fft(re, im, fft_size, 0);
        for (int k = 0; k < bins; k++) acc[k] += (double) re[k] * re[k] + (double) im[k] * im[k];
        count++;
        if (frames <= fft_size) break;
    }
    for (int k = 0; k < bins; k++) out_db[k] = to_db(sqrt(acc[k] / (count > 0 ? count : 1)) * norm);
    free(acc);
    free(w);
    free(re);
    free(im);
}

float wd_correlation(const float *stereo, int64_t frames)
{
    double lr = 0, ll = 0, rr = 0;
    for (int64_t i = 0; i < frames; i++) {
        double l = stereo[2 * i], r = stereo[2 * i + 1];
        lr += l * r;
        ll += l * l;
        rr += r * r;
    }
    if (ll <= 1e-20 || rr <= 1e-20) return 0.0f;
    double c = lr / sqrt(ll * rr);
    if (c > 1) c = 1;
    if (c < -1) c = -1;
    return (float) c;
}

void wd__stft_delta(float *buf, int64_t frames, int channels, int fft_size, int hop, int64_t start_frame, int columns, WdSpectrumFunc fn, void *ctx)
{
    if (frames <= 0 || columns <= 0 || channels <= 0 || !wd__is_pow2(fft_size) || hop <= 0 || hop > fft_size) return;
    int n = fft_size, half = n / 2, bins = half + 1;
    float *w = malloc(sizeof(float) * n);
    wd_window_fill(w, n, WD_WINDOW_HANN);
    double *normp = calloc(hop, sizeof(double));
    for (int i = 0; i < n; i++) normp[i % hop] += (double) w[i] * w[i];
    int64_t span_lo = start_frame - half;
    int64_t span_hi = start_frame + (int64_t) (columns - 1) * hop + half;
    if (span_lo < 0) span_lo = 0;
    if (span_hi > frames) span_hi = frames;
    if (span_hi <= span_lo) {
        free(w);
        free(normp);
        return;
    }
    int64_t span = span_hi - span_lo;
    double *delta = malloc(sizeof(double) * span);
    unsigned char *touched = malloc(span);
    float *re = malloc(sizeof(float) * n);
    float *im = malloc(sizeof(float) * n);
    float *ore = malloc(sizeof(float) * bins);
    float *oim = malloc(sizeof(float) * bins);
    for (int ch = 0; ch < channels; ch++) {
        memset(delta, 0, sizeof(double) * span);
        memset(touched, 0, span);
        int any = 0;
        for (int c = 0; c < columns; c++) {
            int64_t b = start_frame + (int64_t) c * hop - half;
            if (b + n <= 0 || b >= frames) continue;
            for (int i = 0; i < n; i++) {
                int64_t p = b + i;
                re[i] = (p >= 0 && p < frames) ? buf[p * channels + ch] * w[i] : 0.0f;
                im[i] = 0;
            }
            wd_fft(re, im, n, 0);
            memcpy(ore, re, sizeof(float) * bins);
            memcpy(oim, im, sizeof(float) * bins);
            if (!fn(ctx, ch, c, re, im, bins)) continue;
            for (int k = 0; k < bins; k++) {
                re[k] -= ore[k];
                im[k] -= oim[k];
            }
            im[0] = 0;
            im[half] = 0;
            for (int k = 1; k < half; k++) {
                re[n - k] = re[k];
                im[n - k] = -im[k];
            }
            wd_fft(re, im, n, 1);
            for (int i = 0; i < n; i++) {
                int64_t p = b + i;
                if (p < span_lo || p >= span_hi) continue;
                delta[p - span_lo] += (double) re[i] * w[i];
                touched[p - span_lo] = 1;
            }
            any = 1;
        }
        if (!any) continue;
        for (int64_t p = 0; p < span; p++) {
            if (!touched[p]) continue;
            int64_t pos = p + span_lo;
            int64_t r = ((pos - start_frame + half) % hop + hop) % hop;
            double nv = normp[r];
            if (nv < 1e-9) continue;
            buf[pos * channels + ch] = (float) (buf[pos * channels + ch] + delta[p] / nv);
        }
    }
    free(w);
    free(normp);
    free(delta);
    free(touched);
    free(re);
    free(im);
    free(ore);
    free(oim);
}

void wd__stft_full(float *buf, int64_t frames, int channels, int fft_size, int hop, WdSpectrumFunc fn, void *ctx)
{
    if (frames <= 0) return;
    int half = fft_size / 2;
    int64_t kmin = -(half / hop);
    int64_t kmax = (frames + half) / hop + 1;
    wd__stft_delta(buf, frames, channels, fft_size, hop, kmin * hop, (int) (kmax - kmin + 1), fn, ctx);
}
