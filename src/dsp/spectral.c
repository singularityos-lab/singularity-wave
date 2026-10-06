#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

#define HEAL_MARGIN 16

static void column_mags(const float *buf, int64_t frames, int channels, int ch, int fft, int hop, int64_t start_frame, int c_from, int c_to, const float *w, float *re, float *im, float *out)
{
    int half = fft / 2, bins = half + 1;
    for (int c = c_from; c < c_to; c++) {
        int64_t b = start_frame + (int64_t) c * hop - half;
        for (int i = 0; i < fft; i++) {
            int64_t p = b + i;
            float v = 0;
            if (p >= 0 && p < frames) {
                if (ch >= 0) {
                    v = buf[p * channels + ch];
                } else {
                    for (int k = 0; k < channels; k++) v += buf[p * channels + k];
                    v /= channels;
                }
            }
            re[i] = v * w[i];
            im[i] = 0;
        }
        wd_fft(re, im, fft, 0);
        float *o = out + (int64_t) (c - c_from) * bins;
        for (int k = 0; k < bins; k++) o[k] = sqrtf(re[k] * re[k] + im[k] * im[k]);
    }
}

typedef struct {
    const float *mask;
    int columns;
    int bins;
    WdSpectralMode mode;
    float gain;
    float *mags;
    int margin;
} MaskCtx;

static float mask_at(MaskCtx *m, int c, int k)
{
    if (c < 0 || c >= m->columns) return 0;
    return m->mask[(int64_t) c * m->bins + k];
}

static int mask_apply(void *ctx, int channel, int column, float *re, float *im, int bins)
{
    MaskCtx *m = ctx;
    if (column < 0 || column >= m->columns) return 0;
    int modified = 0;
    int span = m->columns + 2 * m->margin;
    const float *table = m->mags ? m->mags + (int64_t) channel * span * bins : NULL;
    for (int k = 0; k < bins; k++) {
        float wgt = m->mask[(int64_t) column * bins + k];
        if (wgt <= 0) continue;
        if (wgt > 1) wgt = 1;
        modified = 1;
        if (m->mode != WD_SPECTRAL_HEAL) {
            float f = 1.0f + wgt * (m->gain - 1.0f);
            re[k] *= f;
            im[k] *= f;
            continue;
        }
        float target = -1;
        int l = column - 1, r = column + 1;
        while (l >= -m->margin && mask_at(m, l, k) >= 0.5f) l--;
        while (r < m->columns + m->margin && mask_at(m, r, k) >= 0.5f) r++;
        int lok = l >= -m->margin, rok = r < m->columns + m->margin;
        if (lok || rok) {
            float lv = lok ? table[(int64_t) (l + m->margin) * bins + k] : 0;
            float rv = rok ? table[(int64_t) (r + m->margin) * bins + k] : 0;
            if (lok && rok) {
                float t = (float) (column - l) / (float) (r - l);
                target = lv + (rv - lv) * t;
            } else {
                target = lok ? lv : rv;
            }
        } else {
            int lo = k - 1, hi = k + 1;
            while (lo >= 0 && mask_at(m, column, lo) >= 0.5f) lo--;
            while (hi < bins && mask_at(m, column, hi) >= 0.5f) hi++;
            const float *row = table + (int64_t) (column + m->margin) * bins;
            if (lo >= 0 && hi < bins) target = 0.5f * (row[lo] + row[hi]);
            else if (lo >= 0) target = row[lo];
            else if (hi < bins) target = row[hi];
            else target = 0;
        }
        float cur = sqrtf(re[k] * re[k] + im[k] * im[k]);
        float nv = (1 - wgt) * cur + wgt * target;
        if (cur > 1e-12f) {
            float s = nv / cur;
            re[k] *= s;
            im[k] *= s;
        } else {
            re[k] = nv;
            im[k] = 0;
        }
    }
    return modified;
}

void wd_spectral_apply(float *buf, int64_t frames, int channels, int fft_size, int hop, int64_t start_frame, const float *mask, int columns, int bins, WdSpectralMode mode, float gain_db)
{
    if (!wd__is_pow2(fft_size) || bins != fft_size / 2 + 1 || columns <= 0 || frames <= 0 || channels <= 0) return;
    MaskCtx m = { mask, columns, bins, mode, powf(10.0f, gain_db / 20.0f), NULL, HEAL_MARGIN };
    if (mode == WD_SPECTRAL_HEAL) {
        int span = columns + 2 * HEAL_MARGIN;
        m.mags = malloc(sizeof(float) * (size_t) channels * span * bins);
        float *w = malloc(sizeof(float) * fft_size);
        float *re = malloc(sizeof(float) * fft_size);
        float *im = malloc(sizeof(float) * fft_size);
        wd_window_fill(w, fft_size, WD_WINDOW_HANN);
        for (int ch = 0; ch < channels; ch++)
            column_mags(buf, frames, channels, ch, fft_size, hop, start_frame, -HEAL_MARGIN, columns + HEAL_MARGIN, w, re, im, m.mags + (int64_t) ch * span * bins);
        free(w);
        free(re);
        free(im);
    }
    wd__stft_delta(buf, frames, channels, fft_size, hop, start_frame, columns, mask_apply, &m);
    free(m.mags);
}

static int cmp_float(const void *a, const void *b)
{
    float x = *(const float *) a, y = *(const float *) b;
    return x < y ? -1 : x > y;
}

int wd_spot_heal(float *buf, int64_t frames, int channels, int rate, int64_t start, int64_t end, float min_hz, float max_hz)
{
    if (frames <= 0 || channels <= 0 || rate <= 0) return 0;
    if (start < 0) start = 0;
    if (end > frames) end = frames;
    if (end <= start) return 0;
    int fft = rate >= 32000 ? 2048 : 1024;
    int hop = fft / 4, bins = fft / 2 + 1;
    int col0 = (int) (start / hop);
    int col1 = (int) ((end + hop - 1) / hop);
    int ncols = col1 - col0 + 1;
    int margin = ncols > 8 ? ncols : 8;
    int total = ncols + 2 * margin;
    int64_t start_frame = (int64_t) col0 * hop;
    float *mags = malloc(sizeof(float) * (size_t) total * bins);
    float *w = malloc(sizeof(float) * fft);
    float *re = malloc(sizeof(float) * fft);
    float *im = malloc(sizeof(float) * fft);
    wd_window_fill(w, fft, WD_WINDOW_HANN);
    column_mags(buf, frames, channels, -1, fft, hop, start_frame, -margin, ncols + margin, w, re, im, mags);
    float *mask = calloc((size_t) ncols * bins, sizeof(float));
    unsigned char *hit = calloc((size_t) ncols * bins, 1);
    float *ref = malloc(sizeof(float) * 2 * margin);
    int kmin = (int) floorf(min_hz * fft / (float) rate);
    int kmax = (int) ceilf(max_hz * fft / (float) rate);
    if (kmin < 0) kmin = 0;
    if (kmax > bins - 1) kmax = bins - 1;
    float ratio = powf(10.0f, 12.0f / 20.0f);
    for (int k = kmin; k <= kmax; k++) {
        int nref = 0;
        for (int c = 0; c < total; c++) {
            int rc = c - margin;
            if (rc >= 0 && rc < ncols) continue;
            int64_t center = start_frame + (int64_t) rc * hop;
            if (center < 0 || center >= frames) continue;
            ref[nref++] = mags[(int64_t) c * bins + k];
        }
        float med = 0;
        if (nref > 0) {
            qsort(ref, nref, sizeof(float), cmp_float);
            med = ref[nref / 2];
        }
        float thr = med * ratio;
        if (thr < 1e-4f) thr = 1e-4f;
        for (int c = 0; c < ncols; c++) {
            int64_t center = start_frame + (int64_t) c * hop;
            if (center < start - hop || center > end + hop) continue;
            if (mags[(int64_t) (c + margin) * bins + k] > thr) hit[(int64_t) c * bins + k] = 1;
        }
    }
    int count = 0;
    for (int c = 0; c < ncols; c++) {
        for (int k = kmin; k <= kmax; k++) {
            if (!hit[(int64_t) c * bins + k]) continue;
            count++;
            for (int dc = -1; dc <= 1; dc++) {
                for (int dk = -1; dk <= 1; dk++) {
                    int cc = c + dc, kk = k + dk;
                    if (cc < 0 || cc >= ncols || kk < 0 || kk >= bins) continue;
                    mask[(int64_t) cc * bins + kk] = 1.0f;
                }
            }
        }
    }
    if (count > 0) wd_spectral_apply(buf, frames, channels, fft, hop, start_frame, mask, ncols, bins, WD_SPECTRAL_HEAL, 0);
    free(mags);
    free(w);
    free(re);
    free(im);
    free(mask);
    free(hit);
    free(ref);
    return count;
}
