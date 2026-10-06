#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "dsp_internal.h"

static const int comb_tuning[8] = { 1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617 };
static const int allpass_tuning[4] = { 556, 441, 341, 225 };

typedef struct {
    float *buf;
    int len;
    int pos;
    float store;
} Comb;

typedef struct {
    float *buf;
    int len;
    int pos;
} Allpass;

struct _WdReverb {
    int rate;
    int channels;
    Comb comb[WD_MAX_CHANNELS][8];
    Allpass ap[WD_MAX_CHANNELS][4];
    float *pre;
    int pre_len;
    int pre_pos;
    int pre_delay;
    float feedback, damp, width, wet, dry;
};

WdReverb *wd_reverb_new(int rate, int channels)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    WdReverb *r = calloc(1, sizeof(WdReverb));
    r->rate = rate > 0 ? rate : 48000;
    r->channels = channels;
    double scale = r->rate / 44100.0;
    for (int ch = 0; ch < channels; ch++) {
        int spread = ch * 23;
        for (int i = 0; i < 8; i++) {
            int len = (int) ((comb_tuning[i] + spread) * scale);
            if (len < 1) len = 1;
            r->comb[ch][i].len = len;
            r->comb[ch][i].buf = calloc(len, sizeof(float));
        }
        for (int i = 0; i < 4; i++) {
            int len = (int) ((allpass_tuning[i] + spread) * scale);
            if (len < 1) len = 1;
            r->ap[ch][i].len = len;
            r->ap[ch][i].buf = calloc(len, sizeof(float));
        }
    }
    r->pre_len = (int) (0.5 * r->rate) + 1;
    r->pre = calloc(r->pre_len, sizeof(float));
    wd_reverb_set(r, 0.5f, 0.5f, 1.0f, 0.0f, 0.3f, 0.8f);
    return r;
}

void wd_reverb_free(WdReverb *r)
{
    if (!r) return;
    for (int ch = 0; ch < r->channels; ch++) {
        for (int i = 0; i < 8; i++) free(r->comb[ch][i].buf);
        for (int i = 0; i < 4; i++) free(r->ap[ch][i].buf);
    }
    free(r->pre);
    free(r);
}

void wd_reverb_set(WdReverb *r, float room, float damping, float width, float predelay_ms, float wet, float dry)
{
    if (!r) return;
    if (room < 0) room = 0;
    if (room > 1) room = 1;
    if (damping < 0) damping = 0;
    if (damping > 1) damping = 1;
    if (width < 0) width = 0;
    if (width > 1) width = 1;
    r->feedback = room * 0.28f + 0.7f;
    r->damp = damping * 0.4f;
    r->width = width;
    r->wet = wet * 3.0f;
    r->dry = dry;
    int pd = (int) (predelay_ms * 0.001 * r->rate);
    if (pd < 0) pd = 0;
    if (pd > r->pre_len - 1) pd = r->pre_len - 1;
    r->pre_delay = pd;
}

void wd_reverb_reset(WdReverb *r)
{
    if (!r) return;
    for (int ch = 0; ch < r->channels; ch++) {
        for (int i = 0; i < 8; i++) {
            memset(r->comb[ch][i].buf, 0, sizeof(float) * r->comb[ch][i].len);
            r->comb[ch][i].store = 0;
            r->comb[ch][i].pos = 0;
        }
        for (int i = 0; i < 4; i++) {
            memset(r->ap[ch][i].buf, 0, sizeof(float) * r->ap[ch][i].len);
            r->ap[ch][i].pos = 0;
        }
    }
    memset(r->pre, 0, sizeof(float) * r->pre_len);
    r->pre_pos = 0;
}

static float tank(WdReverb *r, int ch, float in)
{
    float out = 0;
    for (int i = 0; i < 8; i++) {
        Comb *c = &r->comb[ch][i];
        float y = c->buf[c->pos];
        c->store = y * (1 - r->damp) + c->store * r->damp;
        c->buf[c->pos] = in + c->store * r->feedback;
        if (++c->pos >= c->len) c->pos = 0;
        out += y;
    }
    for (int i = 0; i < 4; i++) {
        Allpass *a = &r->ap[ch][i];
        float b = a->buf[a->pos];
        float o = -out + b;
        a->buf[a->pos] = out + b * 0.5f;
        if (++a->pos >= a->len) a->pos = 0;
        out = o;
    }
    return out;
}

void wd_reverb_process(WdReverb *r, float *buf, int frames)
{
    if (!r || frames <= 0) return;
    int nch = r->channels;
    float t[WD_MAX_CHANNELS];
    float wet1 = r->wet * (r->width / 2 + 0.5f);
    float wet2 = r->wet * ((1 - r->width) / 2);
    for (int i = 0; i < frames; i++) {
        float *f = buf + (size_t) i * nch;
        float mono = 0;
        for (int ch = 0; ch < nch; ch++) mono += f[ch];
        mono = mono / nch * 0.03f;
        r->pre[r->pre_pos] = mono;
        int rd = r->pre_pos - r->pre_delay;
        if (rd < 0) rd += r->pre_len;
        float in = r->pre[rd];
        if (++r->pre_pos >= r->pre_len) r->pre_pos = 0;
        for (int ch = 0; ch < nch; ch++) t[ch] = tank(r, ch, in);
        if (nch == 2) {
            float l = t[0] * wet1 + t[1] * wet2;
            float rr = t[1] * wet1 + t[0] * wet2;
            f[0] = f[0] * r->dry + l;
            f[1] = f[1] * r->dry + rr;
        } else {
            for (int ch = 0; ch < nch; ch++) f[ch] = f[ch] * r->dry + t[ch] * r->wet;
        }
    }
}

struct _WdConvolver {
    int channels;
    int ir_channels;
    int B, N, P;
    float *hre, *him;
    float *xre, *xim;
    float *prev, *cur, *tail;
    int fdl_pos;
    int m;
    float wet, dry;
    float *tre, *tim, *are, *aim;
};

WdConvolver *wd_convolver_new(int channels, const float *ir, int64_t ir_frames, int ir_channels, int block)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    if (ir_channels < 1) ir_channels = 1;
    if (!wd__is_pow2(block)) block = 512;
    if (block < 64) block = 64;
    if (block > 8192) block = 8192;
    WdConvolver *c = calloc(1, sizeof(WdConvolver));
    c->channels = channels;
    c->ir_channels = ir_channels;
    c->B = block;
    c->N = 2 * block;
    if (ir_frames < 1) ir_frames = 1;
    c->P = (int) ((ir_frames + block - 1) / block);
    int N = c->N, P = c->P;
    c->hre = calloc((size_t) ir_channels * P * N, sizeof(float));
    c->him = calloc((size_t) ir_channels * P * N, sizeof(float));
    for (int ic = 0; ic < ir_channels; ic++) {
        for (int p = 0; p < P; p++) {
            float *re = c->hre + ((size_t) ic * P + p) * N;
            float *im = c->him + ((size_t) ic * P + p) * N;
            for (int i = 0; i < block; i++) {
                int64_t k = (int64_t) p * block + i;
                re[i] = (ir && k < ir_frames) ? ir[k * ir_channels + ic] : 0.0f;
            }
            wd_fft(re, im, N, 0);
        }
    }
    c->xre = calloc((size_t) channels * P * N, sizeof(float));
    c->xim = calloc((size_t) channels * P * N, sizeof(float));
    c->prev = calloc((size_t) channels * block, sizeof(float));
    c->cur = calloc((size_t) channels * block, sizeof(float));
    c->tail = calloc((size_t) channels * block, sizeof(float));
    c->tre = malloc(sizeof(float) * N);
    c->tim = malloc(sizeof(float) * N);
    c->are = malloc(sizeof(float) * N);
    c->aim = malloc(sizeof(float) * N);
    c->wet = 1;
    c->dry = 0;
    return c;
}

void wd_convolver_free(WdConvolver *c)
{
    if (!c) return;
    free(c->hre);
    free(c->him);
    free(c->xre);
    free(c->xim);
    free(c->prev);
    free(c->cur);
    free(c->tail);
    free(c->tre);
    free(c->tim);
    free(c->are);
    free(c->aim);
    free(c);
}

void wd_convolver_set_mix(WdConvolver *c, float wet, float dry)
{
    if (!c) return;
    c->wet = wet;
    c->dry = dry;
}

void wd_convolver_reset(WdConvolver *c)
{
    if (!c) return;
    size_t fdl = (size_t) c->channels * c->P * c->N;
    memset(c->xre, 0, sizeof(float) * fdl);
    memset(c->xim, 0, sizeof(float) * fdl);
    memset(c->prev, 0, sizeof(float) * c->channels * c->B);
    memset(c->cur, 0, sizeof(float) * c->channels * c->B);
    memset(c->tail, 0, sizeof(float) * c->channels * c->B);
    c->fdl_pos = 0;
    c->m = 0;
}

static void finish_block(WdConvolver *c)
{
    int N = c->N, B = c->B, P = c->P;
    int slot = c->fdl_pos;
    for (int ch = 0; ch < c->channels; ch++) {
        int ic = ch % c->ir_channels;
        float *xr = c->xre + ((size_t) ch * P + slot) * N;
        float *xi = c->xim + ((size_t) ch * P + slot) * N;
        float *prev = c->prev + (size_t) ch * B;
        float *cur = c->cur + (size_t) ch * B;
        memcpy(xr, prev, sizeof(float) * B);
        memcpy(xr + B, cur, sizeof(float) * B);
        memset(xi, 0, sizeof(float) * N);
        wd_fft(xr, xi, N, 0);
        memset(c->are, 0, sizeof(float) * N);
        memset(c->aim, 0, sizeof(float) * N);
        for (int p = 1; p < P; p++) {
            int s = ((slot + 1 - p) % P + P) % P;
            const float *ar = c->xre + ((size_t) ch * P + s) * N;
            const float *ai = c->xim + ((size_t) ch * P + s) * N;
            const float *hr = c->hre + ((size_t) ic * P + p) * N;
            const float *hi = c->him + ((size_t) ic * P + p) * N;
            for (int k = 0; k < N; k++) {
                c->are[k] += ar[k] * hr[k] - ai[k] * hi[k];
                c->aim[k] += ar[k] * hi[k] + ai[k] * hr[k];
            }
        }
        wd_fft(c->are, c->aim, N, 1);
        memcpy(c->tail + (size_t) ch * B, c->are + B, sizeof(float) * B);
        memcpy(prev, cur, sizeof(float) * B);
        memset(cur, 0, sizeof(float) * B);
    }
    c->fdl_pos = (slot + 1) % P;
}

void wd_convolver_process(WdConvolver *c, float *buf, int frames)
{
    if (!c || frames <= 0) return;
    int nch = c->channels, B = c->B, N = c->N, P = c->P;
    int done = 0;
    while (done < frames) {
        int chunk = frames - done;
        if (chunk > B - c->m) chunk = B - c->m;
        for (int ch = 0; ch < nch; ch++) {
            int ic = ch % c->ir_channels;
            float *cur = c->cur + (size_t) ch * B;
            for (int i = 0; i < chunk; i++) cur[c->m + i] = buf[(size_t) (done + i) * nch + ch];
            memcpy(c->tre, c->prev + (size_t) ch * B, sizeof(float) * B);
            memcpy(c->tre + B, cur, sizeof(float) * B);
            memset(c->tim, 0, sizeof(float) * N);
            wd_fft(c->tre, c->tim, N, 0);
            const float *hr = c->hre + ((size_t) ic * P) * N;
            const float *hi = c->him + ((size_t) ic * P) * N;
            for (int k = 0; k < N; k++) {
                float r = c->tre[k] * hr[k] - c->tim[k] * hi[k];
                float im = c->tre[k] * hi[k] + c->tim[k] * hr[k];
                c->tre[k] = r;
                c->tim[k] = im;
            }
            wd_fft(c->tre, c->tim, N, 1);
            float *tail = c->tail + (size_t) ch * B;
            for (int i = 0; i < chunk; i++) {
                int j = c->m + i;
                float w = c->tre[B + j] + tail[j];
                float *s = &buf[(size_t) (done + i) * nch + ch];
                *s = *s * c->dry + w * c->wet;
            }
        }
        c->m += chunk;
        done += chunk;
        if (c->m >= B) {
            finish_block(c);
            c->m = 0;
        }
    }
}

struct _WdDelay {
    int rate;
    int channels;
    int len;
    float *line;
    int pos;
    float time, feedback, wet, dry, damp_a;
    int ping_pong;
    float lp[WD_MAX_CHANNELS];
};

WdDelay *wd_delay_new(int rate, int channels, float max_ms)
{
    if (channels < 1) channels = 1;
    if (channels > WD_MAX_CHANNELS) channels = WD_MAX_CHANNELS;
    if (max_ms < 10) max_ms = 10;
    WdDelay *d = calloc(1, sizeof(WdDelay));
    d->rate = rate > 0 ? rate : 48000;
    d->channels = channels;
    d->len = (int) (max_ms * 0.001 * d->rate) + 4;
    d->line = calloc((size_t) d->len * channels, sizeof(float));
    wd_delay_set(d, 250, 0.3f, 0.3f, 1.0f, 0, 0);
    return d;
}

void wd_delay_free(WdDelay *d)
{
    if (!d) return;
    free(d->line);
    free(d);
}

void wd_delay_set(WdDelay *d, float time_ms, float feedback, float wet, float dry, int ping_pong, float damping_hz)
{
    if (!d) return;
    float t = time_ms * 0.001f * d->rate;
    if (t < 1) t = 1;
    if (t > d->len - 3) t = (float) (d->len - 3);
    d->time = t;
    if (feedback < 0) feedback = 0;
    if (feedback > 0.95f) feedback = 0.95f;
    d->feedback = feedback;
    d->wet = wet;
    d->dry = dry;
    d->ping_pong = ping_pong != 0;
    d->damp_a = damping_hz > 0 && damping_hz < d->rate * 0.45 ? (float) exp(-2 * M_PI * damping_hz / d->rate) : 0.0f;
}

void wd_delay_reset(WdDelay *d)
{
    if (!d) return;
    memset(d->line, 0, sizeof(float) * (size_t) d->len * d->channels);
    memset(d->lp, 0, sizeof(d->lp));
    d->pos = 0;
}

void wd_delay_process(WdDelay *d, float *buf, int frames)
{
    if (!d || frames <= 0) return;
    int nch = d->channels;
    float out[WD_MAX_CHANNELS];
    for (int i = 0; i < frames; i++) {
        float *f = buf + (size_t) i * nch;
        float rp = d->pos - d->time;
        while (rp < 0) rp += d->len;
        int i0 = (int) rp;
        float fr = rp - i0;
        int i1 = (i0 + 1) % d->len;
        for (int ch = 0; ch < nch; ch++) {
            float a = d->line[(size_t) i0 * nch + ch], b = d->line[(size_t) i1 * nch + ch];
            float v = a + (b - a) * fr;
            d->lp[ch] = (1 - d->damp_a) * v + d->damp_a * d->lp[ch];
            out[ch] = v;
        }
        float *w = d->line + (size_t) d->pos * nch;
        if (d->ping_pong && nch == 2) {
            w[0] = 0.5f * (f[0] + f[1]) + d->feedback * d->lp[1];
            w[1] = d->feedback * d->lp[0];
        } else {
            for (int ch = 0; ch < nch; ch++) w[ch] = f[ch] + d->feedback * d->lp[ch];
        }
        for (int ch = 0; ch < nch; ch++) f[ch] = f[ch] * d->dry + out[ch] * d->wet;
        if (++d->pos >= d->len) d->pos = 0;
    }
}
