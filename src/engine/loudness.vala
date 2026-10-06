namespace Singularity.Apps.Wave {

    public class LoudnessResult : Object {
        public double integrated = -double.INFINITY;
        public double short_term_max = -double.INFINITY;
        public double momentary_max = -double.INFINITY;
        public double range = 0;
        public double true_peak = -double.INFINITY;
        public double sample_peak = -double.INFINITY;

        public static string format_lufs(double v) {
            return v.is_finite() ? "%.1f LUFS".printf(v) : _("Silent");
        }

        public static string format_db(double v, string unit = "dB") {
            return v.is_finite() ? "%.1f %s".printf(v, unit) : "-inf %s".printf(unit);
        }
    }

    public class LoudnessTarget {
        public string id;
        public string label;
        public double lufs;
        public double true_peak;

        public LoudnessTarget(string id, string label, double lufs, double true_peak) {
            this.id = id;
            this.label = label;
            this.lufs = lufs;
            this.true_peak = true_peak;
        }

        public static LoudnessTarget[] all() {
            return {
                new LoudnessTarget("podcast", _("Podcast, -16 LUFS"), -16, -1),
                new LoudnessTarget("streaming", _("Music Streaming, -14 LUFS"), -14, -1),
                new LoudnessTarget("broadcast", _("Broadcast EBU R128, -23 LUFS"), -23, -1),
                new LoudnessTarget("atsc", _("Broadcast ATSC A/85, -24 LKFS"), -24, -2),
                new LoudnessTarget("audiobook", _("Audiobook, -20 LUFS"), -20, -3),
                new LoudnessTarget("video", _("Online Video, -14 LUFS"), -14, -1)
            };
        }

        public static LoudnessTarget find(string id) {
            foreach (var t in all()) {
                if (t.id == id) return t;
            }
            return all()[0];
        }
    }

    namespace Loudness {
        public LoudnessResult measure(float[] buf, int64 frames, int channels, int rate) {
            var meter = new WaveDsp.Loudness(rate, channels);
            var r = new LoudnessResult();
            int block = rate / 10;
            var tmp = new float[block * channels];
            for (int64 pos = 0; pos < frames; pos += block) {
                int n = (int) int64.min(block, frames - pos);
                Memory.copy(tmp, &buf[pos * channels], n * channels * sizeof(float));
                meter.add(tmp, n);
                double m = meter.momentary();
                double s = meter.short_term();
                if (m.is_finite() && m > r.momentary_max) r.momentary_max = m;
                if (s.is_finite() && s > r.short_term_max) r.short_term_max = s;
            }
            r.integrated = meter.integrated();
            r.range = meter.range();
            r.true_peak = meter.true_peak();
            r.sample_peak = meter.sample_peak();
            return r;
        }

        public LoudnessResult measure_renderable(Renderable src, Cancellable? cancel = null, owned ProgressFunc? report = null) {
            int channels = src.channel_count;
            int rate = src.sample_rate;
            var meter = new WaveDsp.Loudness(rate, channels);
            var r = new LoudnessResult();
            int block = rate / 10;
            var tmp = new float[block * channels];
            int64 total = src.total_frames;
            for (int64 pos = 0; pos < total; pos += block) {
                if (cancel != null && cancel.is_cancelled()) break;
                int n = (int) int64.min(block, total - pos);
                src.render(pos, n, tmp);
                meter.add(tmp, n);
                double m = meter.momentary();
                double s = meter.short_term();
                if (m.is_finite() && m > r.momentary_max) r.momentary_max = m;
                if (s.is_finite() && s > r.short_term_max) r.short_term_max = s;
                if (report != null && pos % (block * 50) == 0) report((double) pos / total);
            }
            r.integrated = meter.integrated();
            r.range = meter.range();
            r.true_peak = meter.true_peak();
            r.sample_peak = meter.sample_peak();
            return r;
        }

        public void normalize(float[] buf, int64 frames, int channels, int rate, double target_lufs, double ceiling_dbtp) {
            for (int pass = 0; pass < 3; pass++) {
                var r = measure(buf, frames, channels, rate);
                if (!r.integrated.is_finite()) return;
                double gain = target_lufs - r.integrated;
                bool needs_limit = r.true_peak + gain > ceiling_dbtp;
                if (Math.fabs(gain) < 0.05 && !needs_limit) return;
                WaveDsp.gain(buf, frames * channels, (float) gain);
                if (needs_limit) limit(buf, frames, channels, rate, ceiling_dbtp);
            }
        }

        public void limit(float[] buf, int64 frames, int channels, int rate, double ceiling_dbtp) {
            var lim = new WaveDsp.Dynamics(WaveDsp.DynamicsType.LIMITER, rate, channels);
            lim.set((float) ceiling_dbtp - 0.1f, 20, 0.1f, 60, 0, 0, 5, 0, 0, true);
            int lat = lim.latency();
            int block = 4096;
            int64 total = frames + lat;
            var tmp = new float[block * channels];
            var result = new float[frames * channels];
            for (int64 pos = 0; pos < total; pos += block) {
                int n = (int) int64.min(block, total - pos);
                for (int i = 0; i < n * channels; i++) {
                    int64 idx = pos * channels + i;
                    tmp[i] = idx < frames * channels ? buf[idx] : 0;
                }
                lim.process(tmp, n);
                for (int i = 0; i < n * channels; i++) {
                    int64 dst = (pos - lat) * channels + i;
                    if (dst >= 0 && dst < frames * channels) result[dst] = tmp[i];
                }
            }
            Memory.copy(buf, result, (size_t) (frames * channels * sizeof(float)));
        }

        public void normalize_peak(float[] buf, int64 frames, int channels, double target_db, bool per_channel) {
            if (!per_channel) {
                float p = WaveDsp.peak(buf, frames * channels);
                if (p <= 0) return;
                WaveDsp.gain(buf, frames * channels, (float) (target_db - 20 * Math.log10(p)));
                return;
            }
            for (int c = 0; c < channels; c++) {
                float p = 0;
                for (int64 f = 0; f < frames; f++) p = float.max(p, Math.fabsf(buf[f * channels + c]));
                if (p <= 0) continue;
                float g = (float) Math.pow(10, (target_db - 20 * Math.log10(p)) / 20);
                for (int64 f = 0; f < frames; f++) buf[f * channels + c] *= g;
            }
        }
    }

    public class LiveMeter : Object {
        public int channels { get; private set; }
        public int rate { get; private set; }
        public float[] peak;
        public float[] rms;
        public float[] hold;
        public double momentary = -double.INFINITY;
        public double short_term = -double.INFINITY;
        public double integrated = -double.INFINITY;
        public double range = 0;
        public double true_peak = -double.INFINITY;
        public float correlation = 1;
        public float[] scope = new float[1024];
        public float[] spectrum = new float[1025];
        public bool has_spectrum = false;
        private float[] ring = new float[2048];
        private int ring_pos = 0;
        public int scope_frames = 0;

        private WaveDsp.Loudness? loud;
        private Mutex mutex;

        public LiveMeter(int rate, int channels) {
            configure(rate, channels);
        }

        public void configure(int rate, int channels) {
            mutex.lock();
            this.rate = rate;
            this.channels = channels;
            peak = new float[channels];
            rms = new float[channels];
            hold = new float[channels];
            loud = new WaveDsp.Loudness(rate, channels);
            mutex.unlock();
        }

        public void reset_loudness() {
            mutex.lock();
            loud.reset();
            integrated = -double.INFINITY;
            momentary = -double.INFINITY;
            short_term = -double.INFINITY;
            true_peak = -double.INFINITY;
            range = 0;
            mutex.unlock();
        }

        public void feed(float[] buf, int frames) {
            if (frames <= 0) return;
            mutex.lock();
            for (int c = 0; c < channels; c++) {
                float p = 0;
                double sum = 0;
                for (int f = 0; f < frames; f++) {
                    float v = buf[f * channels + c];
                    p = float.max(p, Math.fabsf(v));
                    sum += v * v;
                }
                peak[c] = float.max(p, peak[c] * 0.85f);
                rms[c] = (float) Math.sqrt(sum / frames);
                hold[c] = float.max(hold[c] * 0.995f, p);
            }
            loud.add(buf, frames);
            momentary = loud.momentary();
            short_term = loud.short_term();
            integrated = loud.integrated();
            range = loud.range();
            true_peak = loud.true_peak();
            for (int f = 0; f < frames; f++) {
                float sum = 0;
                for (int c = 0; c < channels; c++) sum += buf[f * channels + c];
                ring[ring_pos++] = sum / channels;
                if (ring_pos == ring.length) {
                    var db = new float[1025];
                    WaveDsp.spectrum_average(ring, ring.length, 2048, WaveDsp.Window.HANN, db);
                    for (int i = 0; i < db.length; i++) spectrum[i] = has_spectrum ? spectrum[i] * 0.6f + db[i] * 0.4f : db[i];
                    has_spectrum = true;
                    ring_pos = 0;
                }
            }
            if (channels >= 2) {
                correlation = WaveDsp.correlation(buf, frames);
                int n = int.min(frames, scope.length / 2);
                for (int f = 0; f < n; f++) {
                    scope[f * 2] = buf[f * channels];
                    scope[f * 2 + 1] = buf[f * channels + 1];
                }
                scope_frames = n;
            }
            mutex.unlock();
        }

        public void decay() {
            mutex.lock();
            for (int c = 0; c < channels; c++) peak[c] *= 0.8f;
            mutex.unlock();
        }
    }
}
