#ifndef WAVEDSP_H
#define WAVEDSP_H

#include <stdint.h>

typedef enum {
    WD_WINDOW_HANN,
    WD_WINDOW_HAMMING,
    WD_WINDOW_BLACKMAN_HARRIS,
    WD_WINDOW_RECTANGULAR
} WdWindow;

void wd_fft(float *re, float *im, int n, int inverse);
void wd_window_fill(float *w, int n, WdWindow kind);

int wd_spectrogram(const float *mono, int64_t frames, int fft_size, int hop, WdWindow window, float *out_db, int max_columns);
void wd_spectrum_average(const float *mono, int64_t frames, int fft_size, WdWindow window, float *out_db);
float wd_correlation(const float *stereo, int64_t frames);

typedef enum {
    WD_SPECTRAL_ATTENUATE,
    WD_SPECTRAL_AMPLIFY,
    WD_SPECTRAL_HEAL
} WdSpectralMode;

void wd_spectral_apply(float *buf, int64_t frames, int channels, int fft_size, int hop, int64_t start_frame, const float *mask, int columns, int bins, WdSpectralMode mode, float gain_db);
int wd_spot_heal(float *buf, int64_t frames, int channels, int rate, int64_t start, int64_t end, float min_hz, float max_hz);

typedef struct _WdNoiseProfile WdNoiseProfile;
WdNoiseProfile *wd_noise_profile_new(int fft_size);
void wd_noise_profile_free(WdNoiseProfile *p);
void wd_noise_profile_learn(WdNoiseProfile *p, const float *buf, int64_t frames, int channels);
int wd_noise_profile_ready(WdNoiseProfile *p);
int wd_noise_profile_size(WdNoiseProfile *p);
void wd_noise_profile_get(WdNoiseProfile *p, float *out_db);
void wd_noise_profile_set(WdNoiseProfile *p, const float *db, int bins);
void wd_noise_reduce(WdNoiseProfile *p, float *buf, int64_t frames, int channels, float reduction_db, float sensitivity, float smoothing);
void wd_denoise_adaptive(float *buf, int64_t frames, int channels, int rate, float reduction_db, float sensitivity);
int wd_declick(float *buf, int64_t frames, int channels, int rate, float sensitivity);
void wd_dehum(float *buf, int64_t frames, int channels, int rate, float base_hz, int harmonics, float q);
int wd_declip(float *buf, int64_t frames, int channels, float threshold);
void wd_dereverb(float *buf, int64_t frames, int channels, int rate, float amount);

typedef enum {
    WD_BAND_PEAK,
    WD_BAND_LOW_SHELF,
    WD_BAND_HIGH_SHELF,
    WD_BAND_LOW_PASS,
    WD_BAND_HIGH_PASS,
    WD_BAND_NOTCH,
    WD_BAND_BAND_PASS
} WdBandType;

typedef struct _WdEq WdEq;
WdEq *wd_eq_new(int rate, int channels, int bands);
void wd_eq_free(WdEq *eq);
int wd_eq_band_count(WdEq *eq);
void wd_eq_set_band(WdEq *eq, int index, WdBandType type, float freq, float gain_db, float q, int enabled);
void wd_eq_reset(WdEq *eq);
void wd_eq_process(WdEq *eq, float *buf, int frames);
void wd_eq_response(WdEq *eq, const float *freqs, float *db_out, int n);

typedef enum {
    WD_DYN_COMPRESSOR,
    WD_DYN_LIMITER,
    WD_DYN_GATE,
    WD_DYN_EXPANDER,
    WD_DYN_DEESSER
} WdDynamicsType;

typedef struct _WdDynamics WdDynamics;
WdDynamics *wd_dyn_new(WdDynamicsType type, int rate, int channels);
void wd_dyn_free(WdDynamics *d);
void wd_dyn_set(WdDynamics *d, float threshold_db, float ratio, float attack_ms, float release_ms, float knee_db, float makeup_db, float lookahead_ms, float range_db, float freq_hz, int true_peak);
void wd_dyn_reset(WdDynamics *d);
int wd_dyn_latency(WdDynamics *d);
void wd_dyn_process(WdDynamics *d, float *buf, int frames);
float wd_dyn_gain_reduction(WdDynamics *d);
float wd_dyn_curve(WdDynamics *d, float input_db);

typedef struct _WdReverb WdReverb;
WdReverb *wd_reverb_new(int rate, int channels);
void wd_reverb_free(WdReverb *r);
void wd_reverb_set(WdReverb *r, float room, float damping, float width, float predelay_ms, float wet, float dry);
void wd_reverb_reset(WdReverb *r);
void wd_reverb_process(WdReverb *r, float *buf, int frames);

typedef struct _WdConvolver WdConvolver;
WdConvolver *wd_convolver_new(int channels, const float *ir, int64_t ir_frames, int ir_channels, int block);
void wd_convolver_free(WdConvolver *c);
void wd_convolver_set_mix(WdConvolver *c, float wet, float dry);
void wd_convolver_reset(WdConvolver *c);
void wd_convolver_process(WdConvolver *c, float *buf, int frames);

typedef struct _WdDelay WdDelay;
WdDelay *wd_delay_new(int rate, int channels, float max_ms);
void wd_delay_free(WdDelay *d);
void wd_delay_set(WdDelay *d, float time_ms, float feedback, float wet, float dry, int ping_pong, float damping_hz);
void wd_delay_reset(WdDelay *d);
void wd_delay_process(WdDelay *d, float *buf, int frames);

typedef enum {
    WD_MOD_CHORUS,
    WD_MOD_FLANGER,
    WD_MOD_PHASER
} WdModType;

typedef struct _WdMod WdMod;
WdMod *wd_mod_new(WdModType type, int rate, int channels);
void wd_mod_free(WdMod *m);
void wd_mod_set(WdMod *m, float rate_hz, float depth, float feedback, float mix);
void wd_mod_reset(WdMod *m);
void wd_mod_process(WdMod *m, float *buf, int frames);

typedef enum {
    WD_SAT_SOFT,
    WD_SAT_HARD,
    WD_SAT_TUBE,
    WD_SAT_FOLD
} WdSaturation;

void wd_saturate(float *buf, int64_t samples, WdSaturation kind, float drive_db, float mix, float output_db);

typedef struct _WdPitch WdPitch;
WdPitch *wd_pitch_new(int rate, int channels);
void wd_pitch_free(WdPitch *p);
void wd_pitch_set(WdPitch *p, float semitones, float mix);
void wd_pitch_set_correction(WdPitch *p, int enabled, int key, int scale, float speed, float reference_hz);
float wd_pitch_detected_hz(WdPitch *p);
void wd_pitch_reset(WdPitch *p);
void wd_pitch_process(WdPitch *p, float *buf, int frames);
float wd_detect_pitch(const float *mono, int frames, int rate);

int64_t wd_stretch_frames(int64_t frames, double ratio);
int64_t wd_time_stretch(const float *in, int64_t frames, int channels, int rate, double ratio, double semitones, float *out, int64_t out_capacity);

typedef struct _WdLoudness WdLoudness;
WdLoudness *wd_loud_new(int rate, int channels);
void wd_loud_free(WdLoudness *l);
void wd_loud_reset(WdLoudness *l);
void wd_loud_add(WdLoudness *l, const float *buf, int64_t frames);
double wd_loud_momentary(WdLoudness *l);
double wd_loud_short_term(WdLoudness *l);
double wd_loud_integrated(WdLoudness *l);
double wd_loud_range(WdLoudness *l);
double wd_loud_true_peak(WdLoudness *l);
double wd_loud_sample_peak(WdLoudness *l);

void wd_gain(float *buf, int64_t samples, float gain_db);
float wd_peak(const float *buf, int64_t samples);
double wd_rms(const float *buf, int64_t samples);
void wd_fade(float *buf, int64_t frames, int channels, int fade_in, int curve);
float wd_fade_gain(double t, int curve);

void wd_quantize(const float *in, int64_t samples, int bits, int dither, int shaping, uint32_t *seed, void *out);
void wd_quantize_frames(const float *in, int64_t frames, int channels, int bits, int dither, int shaping, uint32_t *seed, void *out);
int64_t wd_resample_frames(int64_t frames, int from_rate, int to_rate);
int64_t wd_resample(const float *in, int64_t frames, int channels, int from_rate, int to_rate, float *out, int64_t out_capacity);

int wd_vad(const float *mono, int64_t frames, int rate, int frame_ms, uint8_t *flags, int max_flags);
void wd_classify(const float *mono, int64_t frames, int rate, float *scores);

#endif
