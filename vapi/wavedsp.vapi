[CCode (cheader_filename = "wavedsp.h", lower_case_cprefix = "wd_")]
namespace WaveDsp {
    [CCode (cname = "WdWindow", cprefix = "WD_WINDOW_", has_type_id = false)]
    public enum Window {
        HANN,
        HAMMING,
        BLACKMAN_HARRIS,
        RECTANGULAR
    }

    [CCode (cname = "WdSpectralMode", cprefix = "WD_SPECTRAL_", has_type_id = false)]
    public enum SpectralMode {
        ATTENUATE,
        AMPLIFY,
        HEAL
    }

    [CCode (cname = "WdBandType", cprefix = "WD_BAND_", has_type_id = false)]
    public enum BandType {
        PEAK,
        LOW_SHELF,
        HIGH_SHELF,
        LOW_PASS,
        HIGH_PASS,
        NOTCH,
        BAND_PASS
    }

    [CCode (cname = "WdDynamicsType", cprefix = "WD_DYN_", has_type_id = false)]
    public enum DynamicsType {
        COMPRESSOR,
        LIMITER,
        GATE,
        EXPANDER,
        DEESSER
    }

    [CCode (cname = "WdModType", cprefix = "WD_MOD_", has_type_id = false)]
    public enum ModType {
        CHORUS,
        FLANGER,
        PHASER
    }

    [CCode (cname = "WdSaturation", cprefix = "WD_SAT_", has_type_id = false)]
    public enum Saturation {
        SOFT,
        HARD,
        TUBE,
        FOLD
    }

    public void fft([CCode (array_length = false)] float[] re, [CCode (array_length = false)] float[] im, int n, bool inverse);
    public void window_fill([CCode (array_length = false)] float[] w, int n, Window kind);

    public int spectrogram([CCode (array_length = false)] float[] mono, int64 frames, int fft_size, int hop, Window window, [CCode (array_length = false)] float[] out_db, int max_columns);
    public void spectrum_average([CCode (array_length = false)] float[] mono, int64 frames, int fft_size, Window window, [CCode (array_length = false)] float[] out_db);
    public float correlation([CCode (array_length = false)] float[] stereo, int64 frames);

    public void spectral_apply([CCode (array_length = false)] float[] buf, int64 frames, int channels, int fft_size, int hop, int64 start_frame, [CCode (array_length = false)] float[] mask, int columns, int bins, SpectralMode mode, float gain_db);
    public int spot_heal([CCode (array_length = false)] float[] buf, int64 frames, int channels, int rate, int64 start, int64 end, float min_hz, float max_hz);

    [Compact]
    [CCode (cname = "WdNoiseProfile", free_function = "wd_noise_profile_free", lower_case_cprefix = "wd_noise_profile_")]
    public class NoiseProfile {
        [CCode (cname = "wd_noise_profile_new")]
        public NoiseProfile(int fft_size);
        public void learn([CCode (array_length = false)] float[] buf, int64 frames, int channels);
        public bool ready();
        public int size();
        public void get([CCode (array_length = false)] float[] out_db);
        public void set([CCode (array_length = false)] float[] db, int bins);
        [CCode (cname = "wd_noise_reduce")]
        public void reduce([CCode (array_length = false)] float[] buf, int64 frames, int channels, float reduction_db, float sensitivity, float smoothing);
    }

    public void denoise_adaptive([CCode (array_length = false)] float[] buf, int64 frames, int channels, int rate, float reduction_db, float sensitivity);
    public int declick([CCode (array_length = false)] float[] buf, int64 frames, int channels, int rate, float sensitivity);
    public void dehum([CCode (array_length = false)] float[] buf, int64 frames, int channels, int rate, float base_hz, int harmonics, float q);
    public int declip([CCode (array_length = false)] float[] buf, int64 frames, int channels, float threshold);
    public void dereverb([CCode (array_length = false)] float[] buf, int64 frames, int channels, int rate, float amount);

    [Compact]
    [CCode (cname = "WdEq", free_function = "wd_eq_free", lower_case_cprefix = "wd_eq_")]
    public class Eq {
        [CCode (cname = "wd_eq_new")]
        public Eq(int rate, int channels, int bands);
        public int band_count();
        public void set_band(int index, BandType type, float freq, float gain_db, float q, bool enabled);
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
        public void response([CCode (array_length = false)] float[] freqs, [CCode (array_length = false)] float[] db_out, int n);
    }

    [Compact]
    [CCode (cname = "WdDynamics", free_function = "wd_dyn_free", lower_case_cprefix = "wd_dyn_")]
    public class Dynamics {
        [CCode (cname = "wd_dyn_new")]
        public Dynamics(DynamicsType type, int rate, int channels);
        public void set(float threshold_db, float ratio, float attack_ms, float release_ms, float knee_db, float makeup_db, float lookahead_ms, float range_db, float freq_hz, bool true_peak);
        public void reset();
        public int latency();
        public void process([CCode (array_length = false)] float[] buf, int frames);
        public float gain_reduction();
        public float curve(float input_db);
    }

    [Compact]
    [CCode (cname = "WdReverb", free_function = "wd_reverb_free", lower_case_cprefix = "wd_reverb_")]
    public class Reverb {
        [CCode (cname = "wd_reverb_new")]
        public Reverb(int rate, int channels);
        public void set(float room, float damping, float width, float predelay_ms, float wet, float dry);
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
    }

    [Compact]
    [CCode (cname = "WdConvolver", free_function = "wd_convolver_free", lower_case_cprefix = "wd_convolver_")]
    public class Convolver {
        [CCode (cname = "wd_convolver_new")]
        public Convolver(int channels, [CCode (array_length = false)] float[] ir, int64 ir_frames, int ir_channels, int block);
        public void set_mix(float wet, float dry);
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
    }

    [Compact]
    [CCode (cname = "WdDelay", free_function = "wd_delay_free", lower_case_cprefix = "wd_delay_")]
    public class Delay {
        [CCode (cname = "wd_delay_new")]
        public Delay(int rate, int channels, float max_ms);
        public void set(float time_ms, float feedback, float wet, float dry, bool ping_pong, float damping_hz);
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
    }

    [Compact]
    [CCode (cname = "WdMod", free_function = "wd_mod_free", lower_case_cprefix = "wd_mod_")]
    public class Mod {
        [CCode (cname = "wd_mod_new")]
        public Mod(ModType type, int rate, int channels);
        public void set(float rate_hz, float depth, float feedback, float mix);
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
    }

    public void saturate([CCode (array_length = false)] float[] buf, int64 samples, Saturation kind, float drive_db, float mix, float output_db);

    [Compact]
    [CCode (cname = "WdPitch", free_function = "wd_pitch_free", lower_case_cprefix = "wd_pitch_")]
    public class Pitch {
        [CCode (cname = "wd_pitch_new")]
        public Pitch(int rate, int channels);
        public void set(float semitones, float mix);
        public void set_correction(bool enabled, int key, int scale, float speed, float reference_hz);
        public float detected_hz();
        public void reset();
        public void process([CCode (array_length = false)] float[] buf, int frames);
    }

    public float detect_pitch([CCode (array_length = false)] float[] mono, int frames, int rate);
    public int64 stretch_frames(int64 frames, double ratio);
    public int64 time_stretch([CCode (array_length = false)] float[] input, int64 frames, int channels, int rate, double ratio, double semitones, [CCode (array_length = false)] float[] output, int64 out_capacity);

    [Compact]
    [CCode (cname = "WdLoudness", free_function = "wd_loud_free", lower_case_cprefix = "wd_loud_")]
    public class Loudness {
        [CCode (cname = "wd_loud_new")]
        public Loudness(int rate, int channels);
        public void reset();
        public void add([CCode (array_length = false)] float[] buf, int64 frames);
        public double momentary();
        public double short_term();
        public double integrated();
        public double range();
        public double true_peak();
        public double sample_peak();
    }

    public void gain([CCode (array_length = false)] float[] buf, int64 samples, float gain_db);
    public float peak([CCode (array_length = false)] float[] buf, int64 samples);
    public double rms([CCode (array_length = false)] float[] buf, int64 samples);
    public void fade([CCode (array_length = false)] float[] buf, int64 frames, int channels, bool fade_in, int curve);
    public float fade_gain(double t, int curve);

    public void quantize([CCode (array_length = false)] float[] input, int64 samples, int bits, bool dither, bool shaping, ref uint32 seed, void* output);
    public void quantize_frames([CCode (array_length = false)] float[] input, int64 frames, int channels, int bits, bool dither, bool shaping, ref uint32 seed, void* output);
    public int64 resample_frames(int64 frames, int from_rate, int to_rate);
    public int64 resample([CCode (array_length = false)] float[] input, int64 frames, int channels, int from_rate, int to_rate, [CCode (array_length = false)] float[] output, int64 out_capacity);

    public int vad([CCode (array_length = false)] float[] mono, int64 frames, int rate, int frame_ms, [CCode (array_length = false)] uint8[] flags, int max_flags);
    public void classify([CCode (array_length = false)] float[] mono, int64 frames, int rate, [CCode (array_length = false)] float[] scores);
}
