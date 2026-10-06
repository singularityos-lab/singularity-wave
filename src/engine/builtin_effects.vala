namespace Singularity.Apps.Wave {

    public class EqEffect : Effect {
        public int bands { get; construct; }
        public bool graphic { get; construct; }
        private WaveDsp.Eq? eq = null;

        public static float[] graphic_freqs(int n) {
            if (n == 10) return { 31.5f, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
            float[] f = {};
            for (int i = 0; i < n; i++) f += (float) (20.0 * Math.pow(2, i / 3.0));
            return f;
        }

        public override string title {
            owned get { return graphic ? _("Graphic Equalizer (%d Bands)").printf(bands) : _("Parametric Equalizer"); }
        }

        public EqEffect(string kind) {
            bool g = kind.has_prefix("geq");
            Object(kind: kind, bands: g ? int.parse(kind.substring(3)) : 8, graphic: g);
            string[] types = { _("Bell"), _("Low Shelf"), _("High Shelf"), _("Low Cut"), _("High Cut"), _("Notch"), _("Band Pass") };
            if (graphic) {
                var freqs = graphic_freqs(bands);
                for (int i = 0; i < bands; i++) {
                    string label = freqs[i] >= 1000 ? "%g kHz".printf(freqs[i] / 1000) : "%g Hz".printf(freqs[i]);
                    add_param("g%d".printf(i), label, -18, 18, 0, "dB");
                }
            } else {
                float[] defaults = { 80, 200, 500, 1000, 2500, 5000, 10000, 15000 };
                int[] default_types = { 3, 1, 0, 0, 0, 0, 2, 4 };
                for (int i = 0; i < bands; i++) {
                    add_toggle("b%d_on".printf(i), _("Band %d").printf(i + 1), i > 0 && i < 7);
                    add_choice("b%d_type".printf(i), _("Shape"), types, default_types[i]);
                    var f = add_param("b%d_freq".printf(i), _("Frequency"), 20, 20000, defaults[i], "Hz");
                    f.logarithmic = true;
                    add_param("b%d_gain".printf(i), _("Gain"), -24, 24, 0, "dB");
                    var q = add_param("b%d_q".printf(i), _("Width"), 0.1, 18, 0.9, "Q");
                    q.logarithmic = true;
                }
            }
            add_param("output", _("Output"), -24, 24, 0, "dB");
        }

        public override void prepare(int rate, int channels) {
            eq = new WaveDsp.Eq(rate, channels, bands);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (eq == null) return;
            if (graphic) {
                var freqs = graphic_freqs(bands);
                float q = bands == 10 ? 1.41f : 4.32f;
                for (int i = 0; i < bands; i++) {
                    float g = (float) get_value("g%d".printf(i));
                    eq.set_band(i, WaveDsp.BandType.PEAK, float.min(freqs[i], rate * 0.45f), g, q, g != 0);
                }
                return;
            }
            WaveDsp.BandType[] map = { WaveDsp.BandType.PEAK, WaveDsp.BandType.LOW_SHELF, WaveDsp.BandType.HIGH_SHELF,
                WaveDsp.BandType.HIGH_PASS, WaveDsp.BandType.LOW_PASS, WaveDsp.BandType.NOTCH, WaveDsp.BandType.BAND_PASS };
            for (int i = 0; i < bands; i++) {
                int t = (int) get_value("b%d_type".printf(i));
                eq.set_band(i, map[t.clamp(0, 6)], float.min((float) get_value("b%d_freq".printf(i)), rate * 0.45f),
                    (float) get_value("b%d_gain".printf(i)), (float) get_value("b%d_q".printf(i)), get_value("b%d_on".printf(i)) >= 0.5);
            }
        }

        public override void reset() {
            if (eq != null) eq.reset();
        }

        public override void process(float[] buf, int frames) {
            if (eq == null) prepare(rate, channels);
            eq.process(buf, frames);
            float out_gain = (float) get_value("output");
            if (out_gain != 0) WaveDsp.gain(buf, (int64) frames * channels, out_gain);
        }

        public float[] response(float[] freqs) {
            var db = new float[freqs.length];
            if (eq == null) prepare(rate, channels);
            eq.response(freqs, db, freqs.length);
            float out_gain = (float) get_value("output");
            for (int i = 0; i < db.length; i++) db[i] += out_gain;
            return db;
        }
    }

    public class DynamicsEffect : Effect {
        public WaveDsp.DynamicsType mode { get; construct; }
        private WaveDsp.Dynamics? dyn = null;
        public float last_reduction { get; private set; default = 0; }

        public override string title {
            owned get {
                switch (mode) {
                case WaveDsp.DynamicsType.LIMITER: return _("Limiter");
                case WaveDsp.DynamicsType.GATE: return _("Noise Gate");
                case WaveDsp.DynamicsType.EXPANDER: return _("Expander");
                case WaveDsp.DynamicsType.DEESSER: return _("De-esser");
                default: return _("Compressor");
                }
            }
        }

        public DynamicsEffect(string kind) {
            WaveDsp.DynamicsType m = WaveDsp.DynamicsType.COMPRESSOR;
            if (kind == "limiter") m = WaveDsp.DynamicsType.LIMITER;
            else if (kind == "gate") m = WaveDsp.DynamicsType.GATE;
            else if (kind == "expander") m = WaveDsp.DynamicsType.EXPANDER;
            else if (kind == "deesser") m = WaveDsp.DynamicsType.DEESSER;
            Object(kind: kind, mode: m);
            switch (m) {
            case WaveDsp.DynamicsType.LIMITER:
                add_param("threshold", _("Ceiling"), -24, 0, -1, "dB");
                add_param("release", _("Release"), 1, 1000, 80, "ms");
                add_param("lookahead", _("Lookahead"), 0, 20, 5, "ms");
                add_toggle("true_peak", _("True Peak"), true);
                add_param("makeup", _("Input Gain"), 0, 24, 0, "dB");
                break;
            case WaveDsp.DynamicsType.GATE:
                add_param("threshold", _("Threshold"), -90, 0, -50, "dB");
                add_param("range", _("Reduction"), 0, 90, 40, "dB");
                add_param("attack", _("Attack"), 0.1, 100, 2, "ms");
                add_param("release", _("Release"), 5, 2000, 150, "ms");
                break;
            case WaveDsp.DynamicsType.EXPANDER:
                add_param("threshold", _("Threshold"), -90, 0, -40, "dB");
                add_param("ratio", _("Ratio"), 1, 10, 2, ":1");
                add_param("attack", _("Attack"), 0.1, 100, 5, "ms");
                add_param("release", _("Release"), 5, 2000, 200, "ms");
                add_param("range", _("Range"), 0, 90, 30, "dB");
                break;
            case WaveDsp.DynamicsType.DEESSER:
                add_param("threshold", _("Threshold"), -60, 0, -28, "dB");
                var f = add_param("frequency", _("Frequency"), 2000, 12000, 6500, "Hz");
                f.logarithmic = true;
                add_param("ratio", _("Strength"), 1, 20, 6, ":1");
                add_param("range", _("Max Reduction"), 0, 24, 12, "dB");
                break;
            default:
                add_param("threshold", _("Threshold"), -60, 0, -20, "dB");
                add_param("ratio", _("Ratio"), 1, 20, 3, ":1");
                add_param("attack", _("Attack"), 0.1, 200, 10, "ms");
                add_param("release", _("Release"), 5, 2000, 120, "ms");
                add_param("knee", _("Knee"), 0, 24, 6, "dB");
                add_param("makeup", _("Makeup"), 0, 24, 0, "dB");
                add_param("lookahead", _("Lookahead"), 0, 20, 0, "ms");
                break;
            }
        }

        public override void prepare(int rate, int channels) {
            dyn = new WaveDsp.Dynamics(mode, rate, channels);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (dyn == null) return;
            dyn.set((float) get_value("threshold"), (float) (find("ratio") != null ? get_value("ratio") : 20),
                (float) (find("attack") != null ? get_value("attack") : 0.1), (float) get_value("release"),
                (float) get_value("knee"), (float) get_value("makeup"), (float) get_value("lookahead"),
                (float) get_value("range"), (float) get_value("frequency"), get_value("true_peak") >= 0.5);
        }

        public override void reset() {
            if (dyn != null) dyn.reset();
        }

        public override int latency() {
            return dyn != null ? dyn.latency() : 0;
        }

        public override void process(float[] buf, int frames) {
            if (dyn == null) prepare(rate, channels);
            dyn.process(buf, frames);
            last_reduction = dyn.gain_reduction();
        }

        public float curve(float input_db) {
            if (dyn == null) prepare(rate, channels);
            return dyn.curve(input_db);
        }
    }

    public class ReverbEffect : Effect {
        private WaveDsp.Reverb? reverb = null;

        public override string title {
            owned get { return _("Reverb"); }
        }

        public ReverbEffect() {
            Object(kind: "reverb");
            add_param("room", _("Room Size"), 0, 1, 0.55);
            add_param("damping", _("Damping"), 0, 1, 0.45);
            add_param("width", _("Width"), 0, 1, 1);
            add_param("predelay", _("Pre-delay"), 0, 200, 12, "ms");
            add_param("wet", _("Wet"), 0, 1, 0.25);
            add_param("dry", _("Dry"), 0, 1, 1);
        }

        public override void prepare(int rate, int channels) {
            reverb = new WaveDsp.Reverb(rate, channels);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (reverb != null) reverb.set((float) get_value("room"), (float) get_value("damping"), (float) get_value("width"),
                (float) get_value("predelay"), (float) get_value("wet"), (float) get_value("dry"));
        }

        public override void reset() {
            if (reverb != null) reverb.reset();
        }

        public override void process(float[] buf, int frames) {
            if (reverb == null) prepare(rate, channels);
            reverb.process(buf, frames);
        }
    }

    public class ConvolutionEffect : Effect {
        private WaveDsp.Convolver? conv = null;
        public string ir_path { get; set; default = ""; }
        private float[]? ir = null;
        private int ir_channels = 1;
        private int ir_rate = 0;
        private string built = "";

        public override string title {
            owned get { return _("Convolution Reverb"); }
        }

        public ConvolutionEffect() {
            Object(kind: "convolution");
            add_choice("space", _("Space"), { _("Small Room"), _("Studio"), _("Hall"), _("Plate"), _("Cathedral"), _("Impulse File") }, 1);
            add_param("wet", _("Wet"), 0, 1, 0.3);
            add_param("dry", _("Dry"), 0, 1, 1);
        }

        public static float[] synthetic_ir(int space, int rate, out int out_channels) {
            double[] seconds = { 0.35, 0.8, 2.4, 1.6, 5.0 };
            double[] bright = { 0.6, 0.45, 0.35, 0.8, 0.25 };
            double t60 = seconds[space.clamp(0, 4)];
            int n = (int) (t60 * rate);
            out_channels = 2;
            var ir = new float[n * 2];
            uint32 seed = 22222 + space;
            float lp_l = 0, lp_r = 0;
            double a = bright[space.clamp(0, 4)];
            for (int i = 0; i < n; i++) {
                double env = Math.pow(10, -3.0 * i / n);
                seed = seed * 1664525 + 1013904223;
                float nl = (float) ((seed >> 8) / 8388608.0 - 1.0);
                seed = seed * 1664525 + 1013904223;
                float nr = (float) ((seed >> 8) / 8388608.0 - 1.0);
                double damp = a * (1.0 - 0.7 * i / (double) n);
                lp_l += (float) damp * (nl - lp_l);
                lp_r += (float) damp * (nr - lp_r);
                ir[i * 2] = (float) (lp_l * env * 0.5);
                ir[i * 2 + 1] = (float) (lp_r * env * 0.5);
            }
            ir[0] = 1;
            ir[1] = 1;
            return ir;
        }

        public void load_ir(string path) throws Error {
            var media = Decoder.decode_sync(path);
            var s = media.source;
            ir = new float[s.frames * s.channels];
            s.read(0, s.frames, ir);
            ir_channels = s.channels;
            ir_rate = s.rate;
            ir_path = path;
            set_value("space", 5);
            built = "";
            update();
        }

        public override void prepare(int rate, int channels) {
            base.prepare(rate, channels);
        }

        protected override void update() {
            int space = (int) get_value("space");
            string key = "%d:%d:%d:%s".printf(space, rate, channels, ir_path);
            if (key != built) {
                built = key;
                float[] data;
                int ch;
                int64 frames;
                if (space == 5 && ir != null) {
                    data = ir;
                    ch = ir_channels;
                    frames = ir.length / ch;
                    if (ir_rate != rate && ir_rate > 0) {
                        int64 n = WaveDsp.resample_frames(frames, ir_rate, rate);
                        var r = new float[n * ch];
                        frames = WaveDsp.resample(data, frames, ch, ir_rate, rate, r, n);
                        data = r;
                    }
                } else {
                    data = synthetic_ir(int.min(space, 4), rate, out ch);
                    frames = data.length / ch;
                }
                conv = new WaveDsp.Convolver(channels, data, frames, ch, 1024);
            }
            if (conv != null) conv.set_mix((float) get_value("wet"), (float) get_value("dry"));
        }

        public override void reset() {
            if (conv != null) conv.reset();
        }

        public override void process(float[] buf, int frames) {
            if (conv == null) update();
            conv.process(buf, frames);
        }

        public override Json.Object to_json() {
            var o = base.to_json();
            if (ir_path != "") o.set_string_member("ir", ir_path);
            return o;
        }

        public override void load_json(Json.Object o) {
            base.load_json(o);
            if (o.has_member("ir")) {
                try {
                    load_ir(o.get_string_member("ir"));
                } catch (Error e) {
                    warning("Wave: impulse %s: %s", o.get_string_member("ir"), e.message);
                }
            }
        }
    }

    public class DelayEffect : Effect {
        private WaveDsp.Delay? delay = null;

        public override string title {
            owned get { return _("Delay and Echo"); }
        }

        public DelayEffect() {
            Object(kind: "delay");
            add_param("time", _("Time"), 1, 2000, 350, "ms");
            add_param("feedback", _("Feedback"), 0, 0.95, 0.35);
            add_param("wet", _("Wet"), 0, 1, 0.3);
            add_param("dry", _("Dry"), 0, 1, 1);
            add_toggle("pingpong", _("Ping Pong"), false);
            var d = add_param("damping", _("Echo Tone"), 500, 20000, 6000, "Hz");
            d.logarithmic = true;
        }

        public override void prepare(int rate, int channels) {
            delay = new WaveDsp.Delay(rate, channels, 2100);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (delay != null) delay.set((float) get_value("time"), (float) get_value("feedback"), (float) get_value("wet"),
                (float) get_value("dry"), get_value("pingpong") >= 0.5, (float) get_value("damping"));
        }

        public override void reset() {
            if (delay != null) delay.reset();
        }

        public override void process(float[] buf, int frames) {
            if (delay == null) prepare(rate, channels);
            delay.process(buf, frames);
        }
    }

    public class ModulationEffect : Effect {
        private WaveDsp.Mod? mod = null;
        private WaveDsp.ModType mode;

        public override string title {
            owned get { return mode == WaveDsp.ModType.FLANGER ? _("Flanger") : mode == WaveDsp.ModType.PHASER ? _("Phaser") : _("Chorus"); }
        }

        public ModulationEffect(string kind) {
            Object(kind: kind);
            mode = kind == "flanger" ? WaveDsp.ModType.FLANGER : kind == "phaser" ? WaveDsp.ModType.PHASER : WaveDsp.ModType.CHORUS;
            add_param("rate", _("Rate"), 0.02, 10, mode == WaveDsp.ModType.CHORUS ? 0.8 : 0.3, "Hz");
            add_param("depth", _("Depth"), 0, 1, 0.5);
            add_param("feedback", _("Feedback"), 0, 0.95, mode == WaveDsp.ModType.CHORUS ? 0.1 : 0.5);
            add_param("mix", _("Mix"), 0, 1, 0.5);
        }

        public override void prepare(int rate, int channels) {
            mod = new WaveDsp.Mod(mode, rate, channels);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (mod != null) mod.set((float) get_value("rate"), (float) get_value("depth"), (float) get_value("feedback"), (float) get_value("mix"));
        }

        public override void reset() {
            if (mod != null) mod.reset();
        }

        public override void process(float[] buf, int frames) {
            if (mod == null) prepare(rate, channels);
            mod.process(buf, frames);
        }
    }

    public class SaturationEffect : Effect {
        public override string title {
            owned get { return _("Saturation"); }
        }

        public SaturationEffect() {
            Object(kind: "saturation");
            add_choice("type", _("Character"), { _("Soft"), _("Hard"), _("Tube"), _("Fold") }, 0);
            add_param("drive", _("Drive"), 0, 36, 6, "dB");
            add_param("mix", _("Mix"), 0, 1, 1);
            add_param("output", _("Output"), -24, 12, -3, "dB");
        }

        public override void process(float[] buf, int frames) {
            WaveDsp.saturate(buf, (int64) frames * channels, (WaveDsp.Saturation) (int) get_value("type"),
                (float) get_value("drive"), (float) get_value("mix"), (float) get_value("output"));
        }
    }

    public class PitchEffect : Effect {
        private WaveDsp.Pitch? pitch = null;
        public bool correction { get; construct; }

        public override string title {
            owned get { return correction ? _("Automatic Pitch Correction") : _("Pitch Shifter"); }
        }

        public PitchEffect(string kind) {
            Object(kind: kind, correction: kind == "autotune");
            if (correction) {
                add_choice("key", _("Key"), { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }, 0);
                add_choice("scale", _("Scale"), { _("Chromatic"), _("Major"), _("Minor") }, 0);
                add_param("speed", _("Correction Speed"), 0, 1, 0.6);
                add_param("reference", _("Reference A"), 415, 466, 440, "Hz");
                add_param("mix", _("Mix"), 0, 1, 1);
            } else {
                add_param("semitones", _("Pitch"), -24, 24, 0, "st");
                add_param("cents", _("Fine"), -100, 100, 0, "ct");
                add_param("mix", _("Mix"), 0, 1, 1);
            }
        }

        public override void prepare(int rate, int channels) {
            pitch = new WaveDsp.Pitch(rate, channels);
            base.prepare(rate, channels);
        }

        protected override void update() {
            if (pitch == null) return;
            if (correction) {
                pitch.set(0, (float) get_value("mix"));
                pitch.set_correction(true, (int) get_value("key"), (int) get_value("scale"), (float) get_value("speed"), (float) get_value("reference"));
            } else {
                pitch.set((float) (get_value("semitones") + get_value("cents") / 100.0), (float) get_value("mix"));
                pitch.set_correction(false, 0, 0, 0, 440);
            }
        }

        public override void reset() {
            if (pitch != null) pitch.reset();
        }

        public override void process(float[] buf, int frames) {
            if (pitch == null) prepare(rate, channels);
            pitch.process(buf, frames);
        }

        public float detected() {
            return pitch != null ? pitch.detected_hz() : 0;
        }
    }

    public class UtilityEffect : Effect {
        public override string title {
            owned get { return _("Gain and Channels"); }
        }

        public UtilityEffect() {
            Object(kind: "utility");
            add_param("gain", _("Gain"), -48, 24, 0, "dB");
            add_toggle("invert", _("Invert Polarity"), false);
            add_toggle("mono", _("Sum to Mono"), false);
            add_toggle("swap", _("Swap Left and Right"), false);
            add_param("width", _("Stereo Width"), 0, 2, 1);
        }

        public override void process(float[] buf, int frames) {
            float g = (float) Math.pow(10, get_value("gain") / 20.0);
            if (get_value("invert") >= 0.5) g = -g;
            bool mono = get_value("mono") >= 0.5;
            bool swap = get_value("swap") >= 0.5;
            float width = (float) get_value("width");
            for (int f = 0; f < frames; f++) {
                if (channels >= 2) {
                    float l = buf[f * channels], r = buf[f * channels + 1];
                    if (swap) {
                        float t = l;
                        l = r;
                        r = t;
                    }
                    float m = (l + r) * 0.5f, s = (l - r) * 0.5f * (mono ? 0 : width);
                    buf[f * channels] = (m + s) * g;
                    buf[f * channels + 1] = (m - s) * g;
                    for (int c = 2; c < channels; c++) buf[f * channels + c] *= g;
                } else {
                    buf[f] *= g;
                }
            }
        }
    }

    public class RestoreEffect : Effect {
        public float[]? profile = null;

        public override string title {
            owned get {
                switch (kind) {
                case "denoise": return _("Noise Reduction");
                case "adaptive_denoise": return _("Adaptive Noise Reduction");
                case "declick": return _("Click and Crackle Removal");
                case "dehum": return _("Hum Removal");
                case "declip": return _("Clipping Repair");
                case "dereverb": return _("Reverb Reduction");
                default: return kind;
                }
            }
        }

        public RestoreEffect(string kind) {
            Object(kind: kind);
            switch (kind) {
            case "denoise":
                add_param("reduction", _("Reduction"), 0, 48, 18, "dB");
                add_param("sensitivity", _("Sensitivity"), 0, 24, 6, "dB");
                add_param("smoothing", _("Smoothing"), 0, 1, 0.5);
                break;
            case "adaptive_denoise":
                add_param("reduction", _("Reduction"), 0, 40, 12, "dB");
                add_param("sensitivity", _("Sensitivity"), 0, 24, 6, "dB");
                break;
            case "declick":
                add_param("sensitivity", _("Sensitivity"), 0, 1, 0.5);
                break;
            case "dehum":
                add_choice("base", _("Mains Frequency"), { "50 Hz", "60 Hz" }, 0);
                add_param("harmonics", _("Harmonics"), 1, 12, 6);
                add_param("q", _("Width"), 5, 100, 30, "Q");
                break;
            case "declip":
                add_param("threshold", _("Clip Level"), 0.5, 1, 0.98);
                break;
            case "dereverb":
                add_param("amount", _("Amount"), 0, 1, 0.5);
                break;
            default:
                break;
            }
        }

        public override bool offline_only() {
            return true;
        }

        public override void process(float[] buf, int frames) {
            switch (kind) {
            case "denoise":
                if (profile == null) return;
                var p = new WaveDsp.NoiseProfile(4096);
                p.set(profile, profile.length);
                p.reduce(buf, frames, channels, (float) get_value("reduction"), (float) get_value("sensitivity"), (float) get_value("smoothing"));
                break;
            case "adaptive_denoise":
                WaveDsp.denoise_adaptive(buf, frames, channels, rate, (float) get_value("reduction"), (float) get_value("sensitivity"));
                break;
            case "declick":
                WaveDsp.declick(buf, frames, channels, rate, (float) get_value("sensitivity"));
                break;
            case "dehum":
                WaveDsp.dehum(buf, frames, channels, rate, get_value("base") >= 0.5 ? 60 : 50, (int) get_value("harmonics"), (float) get_value("q"));
                break;
            case "declip":
                WaveDsp.declip(buf, frames, channels, (float) get_value("threshold"));
                break;
            case "dereverb":
                WaveDsp.dereverb(buf, frames, channels, rate, (float) get_value("amount"));
                break;
            default:
                break;
            }
        }

        public override Json.Object to_json() {
            var o = base.to_json();
            if (profile != null) {
                var a = new Json.Array();
                foreach (float v in profile) a.add_double_element(v);
                o.set_array_member("profile", a);
            }
            return o;
        }

        public override void load_json(Json.Object o) {
            base.load_json(o);
            if (o.has_member("profile")) {
                var a = o.get_array_member("profile");
                profile = new float[a.get_length()];
                for (uint i = 0; i < a.get_length(); i++) profile[i] = (float) a.get_double_element(i);
            }
        }
    }

    public class EffectKind {
        public string kind;
        public string title;
        public string category;

        public EffectKind(string kind, string title, string category) {
            this.kind = kind;
            this.title = title;
            this.category = category;
        }
    }

    namespace EffectRegistry {
        public EffectKind[] builtin() {
            return {
                new EffectKind("eq", _("Parametric Equalizer"), _("Filter and EQ")),
                new EffectKind("geq10", _("Graphic Equalizer (10 Bands)"), _("Filter and EQ")),
                new EffectKind("geq31", _("Graphic Equalizer (31 Bands)"), _("Filter and EQ")),
                new EffectKind("compressor", _("Compressor"), _("Dynamics")),
                new EffectKind("limiter", _("Limiter"), _("Dynamics")),
                new EffectKind("gate", _("Noise Gate"), _("Dynamics")),
                new EffectKind("expander", _("Expander"), _("Dynamics")),
                new EffectKind("deesser", _("De-esser"), _("Dynamics")),
                new EffectKind("reverb", _("Reverb"), _("Reverb and Delay")),
                new EffectKind("convolution", _("Convolution Reverb"), _("Reverb and Delay")),
                new EffectKind("delay", _("Delay and Echo"), _("Reverb and Delay")),
                new EffectKind("chorus", _("Chorus"), _("Modulation")),
                new EffectKind("flanger", _("Flanger"), _("Modulation")),
                new EffectKind("phaser", _("Phaser"), _("Modulation")),
                new EffectKind("saturation", _("Saturation"), _("Modulation")),
                new EffectKind("pitch", _("Pitch Shifter"), _("Time and Pitch")),
                new EffectKind("autotune", _("Automatic Pitch Correction"), _("Time and Pitch")),
                new EffectKind("utility", _("Gain and Channels"), _("Utility")),
                new EffectKind("denoise", _("Noise Reduction"), _("Restoration")),
                new EffectKind("adaptive_denoise", _("Adaptive Noise Reduction"), _("Restoration")),
                new EffectKind("declick", _("Click and Crackle Removal"), _("Restoration")),
                new EffectKind("dehum", _("Hum Removal"), _("Restoration")),
                new EffectKind("declip", _("Clipping Repair"), _("Restoration")),
                new EffectKind("dereverb", _("Reverb Reduction"), _("Restoration"))
            };
        }

        public Effect? create(string kind, bool isolate_plugins = true) {
            switch (kind) {
            case "eq":
            case "geq10":
            case "geq31":
                return new EqEffect(kind);
            case "compressor":
            case "limiter":
            case "gate":
            case "expander":
            case "deesser":
                return new DynamicsEffect(kind);
            case "reverb":
                return new ReverbEffect();
            case "convolution":
                return new ConvolutionEffect();
            case "delay":
                return new DelayEffect();
            case "chorus":
            case "flanger":
            case "phaser":
                return new ModulationEffect(kind);
            case "saturation":
                return new SaturationEffect();
            case "pitch":
            case "autotune":
                return new PitchEffect(kind);
            case "utility":
                return new UtilityEffect();
            case "denoise":
            case "adaptive_denoise":
            case "declick":
            case "dehum":
            case "declip":
            case "dereverb":
                return new RestoreEffect(kind);
            default:
                if (kind.has_prefix("lv2:") || kind.has_prefix("clap:") || kind.has_prefix("ladspa:")) return PluginEffect.create(kind, isolate_plugins);
                return null;
            }
        }

        public Effect? from_json(Json.Object o, bool isolate_plugins = true) {
            var e = create(o.get_string_member_with_default("kind", ""), isolate_plugins);
            if (e != null) e.load_json(o);
            return e;
        }
    }
}
