#ifndef WAVEDSP_INTERNAL_H
#define WAVEDSP_INTERNAL_H

#include <stdint.h>
#include "wavedsp.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define WD_MAX_CHANNELS 8
#define WD_TP_TAPS 12
#define WD_TP_HALF 6

typedef struct {
    double b0, b1, b2, a1, a2;
} WdBiquadCoef;

typedef struct {
    double x1, x2, y1, y2;
} WdBiquadState;

void wd__biquad_design(WdBiquadCoef *c, WdBandType type, double rate, double freq, double gain_db, double q);
double wd__biquad_mag(const WdBiquadCoef *c, double rate, double freq);
static inline double wd__biquad_tick(const WdBiquadCoef *c, WdBiquadState *s, double x)
{
    double y = c->b0 * x + c->b1 * s->x1 + c->b2 * s->x2 - c->a1 * s->y1 - c->a2 * s->y2;
    s->x2 = s->x1;
    s->x1 = x;
    s->y2 = s->y1;
    s->y1 = y;
    return y;
}

void wd__tp_design(double coef[4][WD_TP_TAPS]);
double wd__tp_eval(const double coef[4][WD_TP_TAPS], const float *hist, int pos);

uint32_t wd__rand(uint32_t *state);
double wd__randf(uint32_t *state);

int wd__is_pow2(int n);
int64_t wd__resample_ratio(const float *in, int64_t frames, int channels, double factor, float *out, int64_t out_frames);

typedef int (*WdSpectrumFunc)(void *ctx, int channel, int column, float *re, float *im, int bins);
void wd__stft_delta(float *buf, int64_t frames, int channels, int fft_size, int hop, int64_t start_frame, int columns, WdSpectrumFunc fn, void *ctx);
void wd__stft_full(float *buf, int64_t frames, int channels, int fft_size, int hop, WdSpectrumFunc fn, void *ctx);

void wd__lpc(const double *x, int n, int order, double *a);
int wd__lsar(double *x, int len, const double *a, int order, int start, int count);
float wd__yin(const float *x, int n, int rate, float min_hz, float max_hz, float threshold, float *work);

#endif
