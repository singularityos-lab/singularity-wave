#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wavedsp.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static int failures = 0;

static void check(int ok, const char *name, double value)
{
    printf("%s %s (%.4f)\n", ok ? "ok" : "FAIL", name, value);
    if (!ok) failures++;
}

static uint32_t rng = 1234567;

static double noise(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng / 4294967296.0 * 2 - 1;
}

static float *sine(int64_t frames, int channels, int rate, double freq, double amp)
{
    float *b = malloc(sizeof(float) * frames * channels);
    for (int64_t i = 0; i < frames; i++)
        for (int c = 0; c < channels; c++) b[i * channels + c] = (float) (amp * sin(2 * M_PI * freq * i / rate));
    return b;
}

static double band_db(const float *x, int64_t frames, int channels, int ch, int rate, double freq)
{
    double cr = 0, ci = 0;
    for (int64_t i = 0; i < frames; i++) {
        double w = 0.5 - 0.5 * cos(2 * M_PI * i / frames);
        double a = 2 * M_PI * freq * i / rate;
        cr += x[i * channels + ch] * w * cos(a);
        ci += x[i * channels + ch] * w * sin(a);
    }
    double mag = sqrt(cr * cr + ci * ci) * 4.0 / frames;
    return 20 * log10(mag + 1e-12);
}

static void test_fft(void)
{
    int n = 1024;
    float re[1024], im[1024], o[1024];
    for (int i = 0; i < n; i++) {
        re[i] = o[i] = (float) noise();
        im[i] = 0;
    }
    wd_fft(re, im, n, 0);
    wd_fft(re, im, n, 1);
    double err = 0;
    for (int i = 0; i < n; i++) err = fmax(err, fabs(re[i] - o[i]));
    check(err < 1e-5, "fft round trip", err);
}

static void test_spectrogram(void)
{
    int rate = 48000;
    float *x = sine(rate, 1, rate, 1500, 1.0);
    int fft = 2048, bins = fft / 2 + 1;
    float *out = malloc(sizeof(float) * 200 * bins);
    int cols = wd_spectrogram(x, rate, fft, 512, WD_WINDOW_HANN, out, 200);
    float best = -200;
    int bb = 0;
    for (int b = 0; b < bins; b++) if (out[40 * bins + b] > best) {
        best = out[40 * bins + b];
        bb = b;
    }
    check(cols == 94 && fabs(best) < 1.6 && abs(bb - 64) <= 1, "spectrogram full scale sine near 0 dB", best);
    free(x);
    free(out);
    float st[2000];
    for (int i = 0; i < 1000; i++) {
        st[2 * i] = (float) sin(i * 0.1);
        st[2 * i + 1] = -st[2 * i];
    }
    check(wd_correlation(st, 1000) < -0.99, "correlation anti phase", wd_correlation(st, 1000));
}

static void test_eq(void)
{
    WdEq *eq = wd_eq_new(48000, 2, 3);
    wd_eq_set_band(eq, 0, WD_BAND_PEAK, 1000, 6, 1, 1);
    float f[1] = { 1000 }, d[1];
    wd_eq_response(eq, f, d, 1);
    check(fabs(d[0] - 6) < 0.01, "eq response at centre", d[0]);
    int64_t n = 48000;
    float *x = sine(n, 2, 48000, 1000, 0.25);
    wd_eq_process(eq, x, (int) n);
    double lvl = band_db(x + 24000 * 2, 24000, 2, 1, 48000, 1000);
    check(fabs(lvl - (20 * log10(0.25) + 6)) < 0.2, "eq processed gain at centre", lvl);
    wd_eq_free(eq);
    free(x);
}

static void test_dynamics(void)
{
    int rate = 48000;
    int64_t n = rate;
    float *x = sine(n, 2, rate, 440, 1.0);
    WdDynamics *c = wd_dyn_new(WD_DYN_COMPRESSOR, rate, 2);
    wd_dyn_set(c, -20, 4, 5, 50, 0, 0, 0, 0, 0, 0);
    wd_dyn_process(c, x, (int) n);
    float gr = wd_dyn_gain_reduction(c);
    check(gr > 13 && gr < 16, "compressor gain reduction", gr);
    check(fabs(wd_dyn_curve(c, 0) - (-15)) < 0.01, "compressor static curve", wd_dyn_curve(c, 0));
    wd_dyn_free(c);
    free(x);

    x = malloc(sizeof(float) * n * 2);
    for (int64_t i = 0; i < n; i++) x[2 * i] = x[2 * i + 1] = (float) (1.0 * sin(2 * M_PI * (rate / 4.0) * i / rate + M_PI / 4));
    WdLoudness *li = wd_loud_new(rate, 2);
    wd_loud_add(li, x, n);
    double tp_in = wd_loud_true_peak(li);
    check(fabs(tp_in) < 0.3, "true peak of fs/4 sine at 45 degrees", tp_in);
    check(fabs(wd_loud_sample_peak(li) + 3.01) < 0.05, "sample peak of the same", wd_loud_sample_peak(li));
    wd_loud_free(li);
    WdDynamics *l = wd_dyn_new(WD_DYN_LIMITER, rate, 2);
    wd_dyn_set(l, -1, 1, 0.1f, 50, 0, 0, 2, 0, 0, 1);
    wd_dyn_process(l, x, (int) n);
    WdLoudness *lo = wd_loud_new(rate, 2);
    int lat = wd_dyn_latency(l);
    wd_loud_add(lo, x + lat * 2, n - lat);
    double tp = wd_loud_true_peak(lo);
    check(tp <= -0.95, "limiter output true peak under ceiling", tp);
    check(tp > -2.0, "limiter does not over reduce", tp);
    wd_dyn_free(l);
    wd_loud_free(lo);
    free(x);

    x = sine(n, 1, rate, 440, 0.001);
    WdDynamics *g = wd_dyn_new(WD_DYN_GATE, rate, 1);
    wd_dyn_set(g, -40, 1, 1, 20, 0, 0, 0, 40, 0, 0);
    wd_dyn_process(g, x, (int) n);
    double r = wd_rms(x + rate / 2, rate / 2);
    double att = 20 * log10(r / (0.001 / sqrt(2)));
    check(att < -35, "gate attenuation", att);
    wd_dyn_free(g);
    free(x);

    x = malloc(sizeof(float) * n);
    for (int64_t i = 0; i < n; i++) x[i] = (float) (0.3 * sin(2 * M_PI * 300 * i / rate) + 0.5 * sin(2 * M_PI * 7000 * i / rate));
    WdDynamics *ds = wd_dyn_new(WD_DYN_DEESSER, rate, 1);
    wd_dyn_set(ds, -30, 8, 1, 50, 0, 0, 0, 0, 7000, 0);
    wd_dyn_process(ds, x, (int) n);
    double hi = band_db(x + rate / 2, rate / 2, 1, 0, rate, 7000);
    double lo300 = band_db(x + rate / 2, rate / 2, 1, 0, rate, 300);
    check(hi < 20 * log10(0.5) - 6 && fabs(lo300 - 20 * log10(0.3)) < 1.0, "de-esser reduces 7 kHz only", hi);
    wd_dyn_free(ds);
    free(x);
}

static double loud_of_sine(int rate, double dbfs, double seconds)
{
    int64_t n = (int64_t) (rate * seconds);
    float *x = sine(n, 2, rate, 1000, pow(10, dbfs / 20));
    WdLoudness *l = wd_loud_new(rate, 2);
    wd_loud_add(l, x, n);
    double v = wd_loud_integrated(l);
    wd_loud_free(l);
    free(x);
    return v;
}

static void test_loudness(void)
{
    double v = loud_of_sine(48000, -23, 20);
    check(fabs(v + 23) <= 0.1, "integrated -23 dBFS stereo sine at 48k", v);
    v = loud_of_sine(48000, -33, 20);
    check(fabs(v + 33) <= 0.1, "integrated -33 dBFS stereo sine at 48k", v);
    v = loud_of_sine(44100, -23, 20);
    check(fabs(v + 23) <= 0.1, "integrated -23 dBFS stereo sine at 44.1k", v);
    int rate = 48000;
    int64_t n = rate * 20;
    float *x = malloc(sizeof(float) * n * 2);
    for (int64_t i = 0; i < n; i++) {
        double a = i < n / 2 ? pow(10, -20 / 20.0) : pow(10, -30 / 20.0);
        x[2 * i] = x[2 * i + 1] = (float) (a * sin(2 * M_PI * 1000 * i / rate));
    }
    WdLoudness *l = wd_loud_new(rate, 2);
    wd_loud_add(l, x, n);
    double lra = wd_loud_range(l);
    check(fabs(lra - 10) < 1.0, "loudness range of -20 and -30 halves", lra);
    check(fabs(wd_loud_short_term(l) + 30) < 0.2, "short term at the end", wd_loud_short_term(l));
    check(fabs(wd_loud_momentary(l) + 30) < 0.2, "momentary at the end", wd_loud_momentary(l));
    wd_loud_free(l);
    free(x);
    WdLoudness *e = wd_loud_new(rate, 2);
    check(isinf(wd_loud_integrated(e)) && wd_loud_integrated(e) < 0, "integrated undefined without audio", wd_loud_integrated(e));
    wd_loud_free(e);
    float *s6 = calloc(rate * 10 * 6, sizeof(float));
    for (int64_t i = 0; i < rate * 10; i++) s6[i * 6 + 3] = (float) (0.5 * sin(2 * M_PI * 1000 * i / rate));
    WdLoudness *l6 = wd_loud_new(rate, 6);
    wd_loud_add(l6, s6, rate * 10);
    check(isinf(wd_loud_integrated(l6)), "lfe excluded in 5.1", wd_loud_integrated(l6));
    wd_loud_free(l6);
    free(s6);
}

static void test_noise(void)
{
    int rate = 48000;
    int64_t n = rate * 4;
    float *x = malloc(sizeof(float) * n);
    float *noise_only = malloc(sizeof(float) * rate);
    for (int64_t i = 0; i < rate; i++) noise_only[i] = (float) (0.02 * noise());
    for (int64_t i = 0; i < n; i++) x[i] = (float) (0.3 * sin(2 * M_PI * 1000 * i / rate) + 0.02 * noise());
    int fft = 2048, bins = fft / 2 + 1;
    float *before = malloc(sizeof(float) * bins), *after = malloc(sizeof(float) * bins);
    wd_spectrum_average(x + rate, rate * 2, fft, WD_WINDOW_HANN, before);
    WdNoiseProfile *p = wd_noise_profile_new(fft);
    wd_noise_profile_learn(p, noise_only, rate, 1);
    check(wd_noise_profile_ready(p), "noise profile learned", wd_noise_profile_size(p));
    float *db = malloc(sizeof(float) * bins);
    wd_noise_profile_get(p, db);
    wd_noise_profile_set(p, db, bins);
    wd_noise_reduce(p, x, n, 1, 20, 6, 0.5f);
    wd_spectrum_average(x + rate, rate * 2, fft, WD_WINDOW_HANN, after);
    double nb = 0, na = 0;
    int cnt = 0;
    for (int b = 100; b < bins - 10; b++) {
        if (abs(b - 43) < 6) continue;
        nb += before[b];
        na += after[b];
        cnt++;
    }
    double drop = (nb - na) / cnt;
    check(drop >= 10, "noise reduction lowers the floor", drop);
    double s0 = 20 * log10(0.3);
    double s1 = band_db(x + rate, rate * 2, 1, 0, rate, 1000);
    check(fabs(s1 - s0) < 1.0, "noise reduction keeps the sine", s1 - s0);
    wd_noise_profile_free(p);
    for (int64_t i = 0; i < n; i++) {
        double on = fmod((double) i / rate, 1.0) < 0.6 ? 1 : 0;
        x[i] = (float) (on * 0.3 * sin(2 * M_PI * 1000 * i / rate) + (i < n / 2 ? 0.01 : 0.03) * noise());
    }
    int64_t off0 = n - rate + (int64_t) (0.65 * rate), offn = (int64_t) (0.3 * rate);
    int64_t on0 = n - rate + (int64_t) (0.1 * rate), onn = (int64_t) (0.4 * rate);
    wd_spectrum_average(x + off0, offn, fft, WD_WINDOW_HANN, before);
    wd_denoise_adaptive(x, n, 1, rate, 20, 6);
    wd_spectrum_average(x + off0, offn, fft, WD_WINDOW_HANN, after);
    nb = na = 0;
    cnt = 0;
    for (int b = 100; b < bins - 10; b++) {
        nb += before[b];
        na += after[b];
        cnt++;
    }
    check((nb - na) / cnt >= 8, "adaptive denoise tracks louder noise", (nb - na) / cnt);
    s1 = band_db(x + on0, onn, 1, 0, rate, 1000);
    check(fabs(s1 - s0) < 1.0, "adaptive denoise keeps the program", s1 - s0);
    free(x);
    free(noise_only);
    free(before);
    free(after);
    free(db);
}

static void test_repair(void)
{
    int rate = 48000;
    int64_t n = rate;
    float *clean = malloc(sizeof(float) * n), *x = malloc(sizeof(float) * n);
    for (int64_t i = 0; i < n; i++) clean[i] = (float) (0.4 * sin(2 * M_PI * 440 * i / rate) + 0.2 * sin(2 * M_PI * 660 * i / rate) + 0.001 * noise());
    memcpy(x, clean, sizeof(float) * n);
    int clicks = 0;
    for (int64_t p = 2000; p < n - 2000; p += 4801) {
        x[p] += 0.8f;
        x[p + 1] -= 0.6f;
        x[p + 2] += 0.5f;
        clicks++;
    }
    int rep = wd_declick(x, n, 1, rate, 0.5f);
    double err = 0;
    for (int64_t i = 0; i < n; i++) err = fmax(err, fabs(x[i] - clean[i]));
    check(rep >= clicks && rep <= clicks * 3, "declick finds the clicks", rep);
    check(err < 0.05, "declick restores the waveform", err);
    free(clean);
    free(x);

    n = rate * 2;
    x = malloc(sizeof(float) * n);
    for (int64_t i = 0; i < n; i++) {
        double h = 0;
        for (int k = 1; k <= 6; k++) h += 0.1 / k * sin(2 * M_PI * 50 * k * i / rate + k);
        x[i] = (float) (h + 0.3 * sin(2 * M_PI * 1234 * i / rate));
    }
    wd_dehum(x, n, 1, rate, 50, 6, 30);
    double worst = -200;
    for (int k = 1; k <= 6; k++) {
        double before = 20 * log10(0.1 / k);
        double after = band_db(x + rate, rate, 1, 0, rate, 50 * k);
        worst = fmax(worst, after - before);
    }
    check(worst < -30, "dehum removes 50 Hz and harmonics", worst);
    check(fabs(band_db(x + rate, rate, 1, 0, rate, 1234) - 20 * log10(0.3)) < 0.5, "dehum keeps program", band_db(x + rate, rate, 1, 0, rate, 1234));
    free(x);

    n = rate;
    float *orig = sine(n, 2, rate, 100, 1.0);
    x = malloc(sizeof(float) * n * 2);
    for (int64_t i = 0; i < n * 2; i++) x[i] = orig[i] > 0.7f ? 0.7f : orig[i] < -0.7f ? -0.7f : orig[i];
    double e0 = 0, e1 = 0;
    for (int64_t i = 0; i < n * 2; i++) e0 += (x[i] - orig[i]) * (x[i] - orig[i]);
    int runs = wd_declip(x, n, 2, 0.7f);
    for (int64_t i = 0; i < n * 2; i++) e1 += (x[i] - orig[i]) * (x[i] - orig[i]);
    check(runs >= 300 && e1 < e0 * 0.2, "declip reconstructs clipped peaks", e1 / e0);
    check(wd_peak(x, n * 2) > 0.9f, "declip restores peaks above threshold", wd_peak(x, n * 2));
    free(orig);
    free(x);

    n = rate * 3;
    x = calloc(n, sizeof(float));
    for (int64_t i = 0; i < n; i++) {
        double env = fmod(i, rate / 2.0) < rate / 8.0 ? 1 : 0;
        x[i] = (float) (env * 0.3 * sin(2 * M_PI * 300 * i / rate));
    }
    float *wet = malloc(sizeof(float) * n);
    memcpy(wet, x, sizeof(float) * n);
    WdReverb *rv = wd_reverb_new(rate, 1);
    wd_reverb_set(rv, 0.9f, 0.3f, 1, 0, 0.5f, 1);
    wd_reverb_process(rv, wet, (int) n);
    double tail_before = 0, tail_after = 0;
    for (int64_t i = rate + rate / 4; i < rate + rate / 2 - 2000; i++) tail_before += wet[i] * wet[i];
    wd_dereverb(wet, n, 1, rate, 1.0f);
    for (int64_t i = rate + rate / 4; i < rate + rate / 2 - 2000; i++) tail_after += wet[i] * wet[i];
    double red = 10 * log10(tail_after / tail_before);
    check(red < -3, "dereverb lowers the reverb tail", red);
    wd_reverb_free(rv);
    free(wet);
    free(x);
}

static void test_effects(void)
{
    int rate = 48000;
    int64_t n = rate / 2;
    float *x = calloc(n * 2, sizeof(float));
    x[0] = x[1] = 1;
    WdReverb *r = wd_reverb_new(rate, 2);
    wd_reverb_set(r, 0.8f, 0.5f, 1, 10, 0.5f, 0);
    wd_reverb_process(r, x, (int) n);
    double tail = wd_rms(x + rate / 4 * 2, rate / 8 * 2);
    check(tail > 1e-5 && isfinite(tail), "reverb produces a tail", tail);
    free(x);
    wd_reverb_free(r);

    int64_t irn = 3000;
    float *ir = calloc(irn, sizeof(float));
    ir[0] = 0.5f;
    ir[1500] = 0.25f;
    ir[2999] = -0.125f;
    WdConvolver *c = wd_convolver_new(1, ir, irn, 1, 256);
    int64_t m = 10000;
    float *in = malloc(sizeof(float) * m), *ref = calloc(m, sizeof(float));
    for (int64_t i = 0; i < m; i++) in[i] = (float) noise();
    for (int64_t i = 0; i < m; i++)
        for (int64_t k = 0; k < irn; k++) if (ir[k] != 0 && i - k >= 0) ref[i] += ir[k] * in[i - k];
    float *y = malloc(sizeof(float) * m);
    memcpy(y, in, sizeof(float) * m);
    int64_t pos = 0;
    int sizes[5] = { 1, 100, 77, 300, 513 };
    int si = 0;
    while (pos < m) {
        int chunk = sizes[si++ % 5];
        if (pos + chunk > m) chunk = (int) (m - pos);
        wd_convolver_process(c, y + pos, chunk);
        pos += chunk;
    }
    double err = 0;
    for (int64_t i = 0; i < m; i++) err = fmax(err, fabs(y[i] - ref[i]));
    check(err < 1e-4, "partitioned convolution matches direct convolution", err);
    wd_convolver_free(c);
    free(ir);
    free(in);
    free(ref);
    free(y);

    x = calloc(rate, sizeof(float));
    x[0] = 1;
    WdDelay *d = wd_delay_new(rate, 1, 2000);
    wd_delay_set(d, 100, 0.5f, 1, 0, 0, 0);
    wd_delay_process(d, x, rate);
    check(fabs(x[4800] - 1) < 1e-3 && fabs(x[9600] - 0.5) < 1e-3, "delay echoes with feedback", x[9600]);
    wd_delay_free(d);
    free(x);

    WdModType kinds[3] = { WD_MOD_CHORUS, WD_MOD_FLANGER, WD_MOD_PHASER };
    const char *names[3] = { "chorus changes the signal", "flanger changes the signal", "phaser changes the signal" };
    for (int k = 0; k < 3; k++) {
        float *s = sine(rate, 2, rate, 500, 0.5);
        float *o = malloc(sizeof(float) * rate * 2);
        memcpy(o, s, sizeof(float) * rate * 2);
        WdMod *mm = wd_mod_new(kinds[k], rate, 2);
        wd_mod_set(mm, 1, 0.8f, 0.3f, 0.5f);
        wd_mod_process(mm, o, rate);
        double diff = 0;
        for (int64_t i = 0; i < rate * 2; i++) diff += (o[i] - s[i]) * (o[i] - s[i]);
        double pk = wd_peak(o, rate * 2);
        check(diff > 1 && pk < 2 && isfinite(pk), names[k], diff);
        wd_mod_free(mm);
        free(s);
        free(o);
    }
    float sat[4] = { 0.1f, 0.5f, 1.0f, -1.0f };
    wd_saturate(sat, 4, WD_SAT_SOFT, 12, 1, 0);
    check(fabs(sat[2]) <= 1 && sat[1] > 0.9f, "soft saturation bounds", sat[1]);
}

static void test_pitch(void)
{
    int rate = 48000;
    int64_t n = rate * 2;
    float *x = sine(n, 1, rate, 220, 0.5);
    float f0 = wd_detect_pitch(x, 4096, rate);
    check(fabs(f0 - 220) < 1, "yin detects 220 Hz", f0);
    WdPitch *p = wd_pitch_new(rate, 1);
    wd_pitch_set(p, 12, 1);
    wd_pitch_process(p, x, (int) n);
    float f1 = wd_detect_pitch(x + rate, 4096, rate);
    check(fabs(f1 - 440) < 440 * 0.03, "pitch shift up an octave", f1);
    wd_pitch_free(p);
    free(x);
    x = sine(n, 1, rate, 452, 0.5);
    WdPitch *c = wd_pitch_new(rate, 1);
    wd_pitch_set(c, 0, 1);
    wd_pitch_set_correction(c, 1, 9, 1, 1, 440);
    wd_pitch_process(c, x, (int) n);
    float f2 = wd_detect_pitch(x + rate, 4096, rate);
    check(fabs(f2 - 440) < 440 * 0.015, "pitch correction to A", f2);
    check(fabs(wd_pitch_detected_hz(c) - 452) < 3, "correction detects input pitch", wd_pitch_detected_hz(c));
    wd_pitch_free(c);
    free(x);

    x = sine(rate * 2, 2, rate, 330, 0.5);
    int64_t cap = wd_stretch_frames(rate * 2, 1.5);
    float *y = malloc(sizeof(float) * cap * 2);
    int64_t got = wd_time_stretch(x, rate * 2, 2, rate, 1.5, 0, y, cap);
    check(got == rate * 3, "time stretch output length", (double) got);
    float *mono = malloc(sizeof(float) * cap);
    for (int64_t i = 0; i < got; i++) mono[i] = y[i * 2];
    float f3 = wd_detect_pitch(mono + rate, 4096, rate);
    check(fabs(f3 - 330) < 330 * 0.01, "time stretch preserves pitch", f3);
    check(fabs(wd_rms(mono + rate, rate) - 0.5 / sqrt(2)) < 0.06, "time stretch preserves level", wd_rms(mono + rate, rate));
    free(y);
    cap = wd_stretch_frames(rate * 2, 1.0);
    y = malloc(sizeof(float) * cap * 2);
    got = wd_time_stretch(x, rate * 2, 2, rate, 1.0, 7, y, cap);
    for (int64_t i = 0; i < got; i++) mono[i] = y[i * 2];
    float f4 = wd_detect_pitch(mono + rate / 2, 4096, rate);
    check(got == rate * 2 && fabs(f4 - 330 * pow(2, 7 / 12.0)) < 5, "pitch shift without duration change", f4);
    free(y);
    free(mono);
    free(x);
}

static void test_resample_quantize(void)
{
    int64_t n = 44100;
    float *x = sine(n, 2, 44100, 1000, 0.5);
    int64_t cap = wd_resample_frames(n, 44100, 48000);
    float *y = malloc(sizeof(float) * cap * 2);
    int64_t got = wd_resample(x, n, 2, 44100, 48000, y, cap);
    check(got == 48000, "resample length", (double) got);
    float *mono = malloc(sizeof(float) * got);
    for (int64_t i = 0; i < got; i++) mono[i] = y[i * 2 + 1];
    float f = wd_detect_pitch(mono + 10000, 4096, 48000);
    check(fabs(f - 1000) < 2, "resample keeps frequency", f);
    check(fabs(band_db(mono + 4000, 40000, 1, 0, 48000, 1000) - 20 * log10(0.5)) < 0.1, "resample keeps level", band_db(mono + 4000, 40000, 1, 0, 48000, 1000));
    free(x);
    free(y);
    free(mono);
    int64_t m = 100000;
    float *z = calloc(m, sizeof(float));
    int16_t *q = malloc(sizeof(int16_t) * m);
    uint32_t seed = 42;
    wd_quantize(z, m, 16, 1, 0, &seed, q);
    int nonzero = 0;
    double mean = 0;
    for (int64_t i = 0; i < m; i++) {
        if (q[i] != 0) nonzero++;
        mean += q[i];
    }
    mean /= m;
    check(fabs(nonzero / (double) m - 0.25) < 0.02 && fabs(mean) < 0.02, "tpdf dither statistics", nonzero / (double) m);
    for (int64_t i = 0; i < m; i++) z[i] = 0.3f / 32768;
    wd_quantize(z, m, 16, 0, 0, &seed, q);
    int all0 = 1;
    for (int64_t i = 0; i < m; i++) if (q[i] != 0) all0 = 0;
    check(all0, "no dither truncates sub lsb", 0);
    float big[3] = { 1.0f, -1.0f, 0.5f };
    uint8_t p24[9];
    wd_quantize(big, 3, 24, 0, 0, &seed, p24);
    int32_t v = p24[6] | (p24[7] << 8) | ((int8_t) p24[8] << 16);
    check(v == 4194304 && p24[0] == 0xff && p24[1] == 0xff && p24[2] == 0x7f, "24 bit packing and clipping", v);
    free(z);
    free(q);
}

static float *speech_like(int64_t n, int rate)
{
    float *x = malloc(sizeof(float) * n);
    double ph = 0;
    for (int64_t i = 0; i < n; i++) {
        double t = (double) i / rate;
        double seg = fmod(t, 2.0);
        double on = seg < 1.0 ? 1 : 0;
        double syl = pow(fmax(0, sin(2 * M_PI * 4 * t)), 1.5);
        double f0 = 140 + 30 * sin(2 * M_PI * 1.3 * t);
        ph += 2 * M_PI * f0 / rate;
        double v = 0;
        for (int k = 1; k <= 12; k++) {
            double fk = f0 * k;
            double form = exp(-pow((fk - 600) / 300, 2)) + 0.6 * exp(-pow((fk - 1500) / 400, 2)) + 0.1;
            v += form * sin(k * ph) / k;
        }
        x[i] = (float) (on * syl * 0.3 * v + 0.0005 * noise());
    }
    return x;
}

static void test_vad_classify(void)
{
    int rate = 16000;
    int64_t n = rate * 8;
    float *x = speech_like(n, rate);
    uint8_t flags[1000];
    int count = wd_vad(x, n, rate, 10, flags, 1000);
    int on_speech = 0, on_total = 0, off_sil = 0, off_total = 0;
    for (int i = 0; i < count; i++) {
        double t = i * 0.01;
        double seg = fmod(t, 2.0);
        if (seg >= 0.05 && seg < 0.95) {
            on_total++;
            on_speech += flags[i];
        } else if (seg > 1.3 && seg < 1.95) {
            off_total++;
            off_sil += !flags[i];
        }
    }
    check(count == 800, "vad frame count", count);
    check(on_speech > on_total * 0.7, "vad marks speech", (double) on_speech / on_total);
    check(off_sil > off_total * 0.9, "vad marks silence", (double) off_sil / off_total);
    float s[4];
    wd_classify(x, n, rate, s);
    check(s[0] > s[1] && s[0] > s[2] && s[0] > s[3] && fabs(s[0] + s[1] + s[2] + s[3] - 1) < 1e-4, "classify speech", s[0]);
    free(x);

    x = malloc(sizeof(float) * n);
    double notes[4][3] = { { 261.6, 329.6, 392.0 }, { 293.7, 349.2, 440.0 }, { 246.9, 293.7, 392.0 }, { 261.6, 329.6, 392.0 } };
    for (int64_t i = 0; i < n; i++) {
        int idx = (int) (i / (rate / 2)) % 4;
        double v = 0;
        for (int k = 0; k < 3; k++)
            for (int h = 1; h <= 4; h++) v += sin(2 * M_PI * notes[idx][k] * h * i / rate) / (h * 6.0);
        x[i] = (float) (0.3 * v);
    }
    wd_classify(x, n, rate, s);
    check(s[1] > s[0] && s[1] > s[2] && s[1] > s[3], "classify music", s[1]);
    for (int64_t i = 0; i < n; i++) x[i] = (float) (0.1 * noise());
    wd_classify(x, n, rate, s);
    check(s[3] > s[0] && s[3] > s[1] && s[3] > s[2], "classify ambience", s[3]);
    for (int64_t i = 0; i < n; i++) {
        double t = fmod((double) i / rate, 0.9);
        x[i] = (float) (0.8 * exp(-t * 30) * noise() + 0.0005 * noise());
    }
    wd_classify(x, n, rate, s);
    check(s[2] > s[0] && s[2] > s[1] && s[2] > s[3], "classify effects", s[2]);
    free(x);
}

static void test_spectral(void)
{
    int rate = 48000;
    int64_t n = rate * 2;
    float *x = malloc(sizeof(float) * n * 2), *orig = malloc(sizeof(float) * n * 2);
    for (int64_t i = 0; i < n; i++)
        for (int c = 0; c < 2; c++) x[i * 2 + c] = (float) (0.3 * sin(2 * M_PI * 500 * i / rate) + 0.3 * sin(2 * M_PI * 3000 * i / rate));
    memcpy(orig, x, sizeof(float) * n * 2);
    int fft = 2048, hop = 512, bins = fft / 2 + 1;
    int64_t start = rate / 2;
    int cols = rate / 2 / hop;
    float *mask = calloc((size_t) cols * bins, sizeof(float));
    int kc = (int) (3000.0 * fft / rate);
    for (int c = 0; c < cols; c++)
        for (int k = kc - 6; k <= kc + 6; k++) mask[c * bins + k] = 1;
    wd_spectral_apply(x, n, 2, fft, hop, start, mask, cols, bins, WD_SPECTRAL_ATTENUATE, -60);
    double mid3k = band_db(x + (start + rate / 8) * 2, rate / 4, 2, 0, rate, 3000);
    double mid500 = band_db(x + (start + rate / 8) * 2, rate / 4, 2, 1, rate, 500);
    check(mid3k < 20 * log10(0.3) - 30, "spectral attenuate removes the tone", mid3k);
    check(fabs(mid500 - 20 * log10(0.3)) < 0.5, "spectral attenuate keeps other tone", mid500);
    int64_t lo = start - fft / 2, hi = start + (int64_t) (cols - 1) * hop + fft / 2;
    int same = 1;
    for (int64_t i = 0; i < n * 2; i++) {
        int64_t f = i / 2;
        if (f >= lo && f < hi) continue;
        if (x[i] != orig[i]) same = 0;
    }
    check(same, "samples outside the span are identical", 0);
    free(mask);
    free(x);
    free(orig);

    x = malloc(sizeof(float) * n);
    for (int64_t i = 0; i < n; i++) {
        double beep = (i >= rate && i < rate + rate / 10) ? 0.5 * sin(2 * M_PI * 2500 * i / rate) : 0;
        x[i] = (float) (0.2 * sin(2 * M_PI * 400 * i / rate) + 0.01 * noise() + beep);
    }
    double b0 = band_db(x + rate, rate / 10, 1, 0, rate, 2500);
    int healed = wd_spot_heal(x, n, 1, rate, rate, rate + rate / 10, 2000, 3000);
    double b1 = band_db(x + rate, rate / 10, 1, 0, rate, 2500);
    double k400 = band_db(x + rate, rate / 10, 1, 0, rate, 400);
    check(healed > 0 && b1 < b0 - 20, "spot heal removes a beep", b1 - b0);
    check(fabs(k400 - 20 * log10(0.2)) < 1.0, "spot heal keeps the program", k400);
    free(x);
}

static void test_fades(void)
{
    check(wd_fade_gain(0, 0) == 0 && wd_fade_gain(1, 2) == 1 && fabs(wd_fade_gain(0.5, 2) - 0.5) < 1e-6, "fade curves endpoints", wd_fade_gain(0.5, 2));
    check(wd_fade_gain(0.5, 1) < 0.05 && wd_fade_gain(0.5, 3) < 0.2 && wd_fade_gain(0.5, 0) == 0.5f, "fade curve shapes", wd_fade_gain(0.5, 1));
    float b[8] = { 1, 1, 1, 1, 1, 1, 1, 1 };
    wd_fade(b, 4, 2, 0, 0);
    check(b[0] == 1 && b[7] == 0, "fade out", b[2]);
    float g[4] = { 0.5f, -0.25f, 0.1f, 0 };
    wd_gain(g, 4, 6.0206f);
    check(fabs(g[0] - 1) < 1e-3 && fabs(wd_peak(g, 4) - 1) < 1e-3, "gain and peak", g[0]);
}

static void test_edges(void)
{
    float one[8] = { 0 };
    WdEq *eq = wd_eq_new(48000, 8, 2);
    WdDynamics *d = wd_dyn_new(WD_DYN_LIMITER, 48000, 8);
    WdReverb *r = wd_reverb_new(48000, 8);
    WdMod *m = wd_mod_new(WD_MOD_CHORUS, 48000, 8);
    WdPitch *p = wd_pitch_new(48000, 8);
    WdDelay *dl = wd_delay_new(48000, 8, 500);
    WdLoudness *l = wd_loud_new(48000, 8);
    wd_eq_process(eq, one, 0);
    wd_dyn_process(d, one, 0);
    wd_reverb_process(r, one, 0);
    wd_mod_process(m, one, 0);
    wd_pitch_process(p, one, 0);
    wd_delay_process(dl, one, 0);
    wd_loud_add(l, one, 0);
    wd_noise_reduce(NULL, one, 0, 1, 10, 6, 0.5f);
    wd_denoise_adaptive(one, 0, 1, 48000, 10, 6);
    wd_dereverb(one, 0, 1, 48000, 0.5f);
    check(wd_declick(one, 0, 1, 48000, 0.5f) == 0 && wd_declip(one, 0, 1, 0.9f) == 0, "zero frames are safe", 0);
    int64_t n = 4800;
    float *x = malloc(sizeof(float) * n * 8);
    for (int64_t i = 0; i < n * 8; i++) x[i] = (float) (0.5 * noise());
    wd_eq_set_band(eq, 0, WD_BAND_HIGH_SHELF, 4000, 3, 0.7f, 1);
    wd_eq_process(eq, x, (int) n);
    wd_dyn_process(d, x, (int) n);
    wd_reverb_process(r, x, (int) n);
    wd_mod_process(m, x, (int) n);
    wd_pitch_process(p, x, (int) n);
    wd_delay_process(dl, x, (int) n);
    wd_loud_add(l, x, n);
    int finite = 1;
    for (int64_t i = 0; i < n * 8; i++) if (!isfinite(x[i])) finite = 0;
    check(finite, "eight channel chain stays finite", 0);
    wd_eq_free(eq);
    wd_dyn_free(d);
    wd_reverb_free(r);
    wd_mod_free(m);
    wd_pitch_free(p);
    wd_delay_free(dl);
    wd_loud_free(l);
    free(x);
}

int main(void)
{
    test_fft();
    test_spectrogram();
    test_eq();
    test_dynamics();
    test_loudness();
    test_noise();
    test_repair();
    test_effects();
    test_pitch();
    test_resample_quantize();
    test_vad_classify();
    test_spectral();
    test_fades();
    test_edges();
    printf("%d failures\n", failures);
    return failures ? 1 : 0;
}
