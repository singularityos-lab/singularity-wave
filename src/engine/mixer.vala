namespace Singularity.Apps.Wave {

    public class FloatBuf {
        public float[] data;

        public FloatBuf(int n) {
            data = new float[n];
        }
    }

    public class TrackMeter {
        public float[] peak = new float[8];
        public float reduction = 0;
    }

    public class SessionMixer : Object {
        public weak Session session;
        public bool include_metronome { get; set; default = false; }
        public string? only_track { get; set; default = null; }
        public bool skip_master_rack { get; set; default = false; }
        public Gee.HashMap<string, TrackMeter> meters = new Gee.HashMap<string, TrackMeter>();
        public LiveMeter master_meter;
        public AutomationRecorder? recorder = null;

        private Gee.HashMap<string, FloatBuf> buffers = new Gee.HashMap<string, FloatBuf>();
        private Gee.HashMap<string, double?> last_gain = new Gee.HashMap<string, double?>();
        private float[] clip_buf = new float[0];
        private int64 expected = -1;
        private Mutex mutex;

        public SessionMixer(Session session) {
            this.session = session;
            master_meter = new LiveMeter(session.rate, session.channels);
        }

        public void reset() {
            mutex.lock();
            foreach (var t in session.tracks) {
                t.rack.reset();
                foreach (var c in t.clips) c.rack.reset();
            }
            session.master.rack.reset();
            last_gain.clear();
            expected = -1;
            mutex.unlock();
        }

        private unowned float[] buffer_for(string id, int samples) {
            var fb = buffers[id];
            if (fb == null || fb.data.length < samples) {
                fb = new FloatBuf(samples);
                buffers[id] = fb;
            }
            for (int i = 0; i < samples; i++) fb.data[i] = 0;
            return fb.data;
        }

        private TrackMeter meter_for(string id) {
            var m = meters[id];
            if (m == null) {
                m = new TrackMeter();
                meters[id] = m;
            }
            return m;
        }

        public static void pan_gains(int src_ch, int dst_ch, double pan, double azimuth, double spread, double lfe, float[] gains) {
            for (int i = 0; i < gains.length; i++) gains[i] = 0;
            if (dst_ch == 6) {
                int[] ring = { 2, 1, 5, 4, 0 };
                double az = azimuth;
                while (az > 180) az -= 360;
                while (az < -180) az += 360;
                double[] ring_angles = { 0, 30, 110, -110, -30 };
                for (int s = 0; s < src_ch; s++) {
                    double src_az = az;
                    if (src_ch == 2) src_az += s == 0 ? -30 * (1 - spread * 0.5) : 30 * (1 - spread * 0.5);
                    double a = src_az;
                    for (int k = 0; k < 5; k++) {
                        double a0 = ring_angles[k];
                        double a1 = ring_angles[(k + 1) % 5];
                        double span = a1 - a0;
                        if (span <= 0) span += 360;
                        double rel = a - a0;
                        while (rel < 0) rel += 360;
                        while (rel >= 360) rel -= 360;
                        if (rel <= span) {
                            double t = rel / span;
                            gains[s * 6 + ring[k]] += (float) Math.cos(t * Math.PI / 2);
                            gains[s * 6 + ring[(k + 1) % 5]] += (float) Math.sin(t * Math.PI / 2);
                            break;
                        }
                    }
                    if (spread > 0) {
                        for (int d = 0; d < 6; d++) {
                            if (d == 3) continue;
                            gains[s * 6 + d] = (float) ((1 - spread) * gains[s * 6 + d] + spread * 0.45);
                        }
                    }
                    gains[s * 6 + 3] = (float) lfe;
                }
                return;
            }
            if (dst_ch == 1) {
                for (int s = 0; s < src_ch; s++) gains[s] = 1.0f / src_ch;
                return;
            }
            if (src_ch == 1) {
                double angle = (pan.clamp(-1, 1) + 1) * Math.PI / 4;
                gains[0] = (float) Math.cos(angle);
                gains[1] = (float) Math.sin(angle);
                return;
            }
            double lg = pan > 0 ? 1 - pan : 1;
            double rg = pan < 0 ? 1 + pan : 1;
            gains[0 * dst_ch + 0] = (float) lg;
            gains[1 * dst_ch + 1] = (float) rg;
            for (int s = 2; s < src_ch && s < dst_ch; s++) gains[s * dst_ch + s] = 1;
        }

        private void route(float[] src, int src_ch, float[] dst, int dst_ch, int frames, float[] gains, double gain_a, double gain_b) {
            for (int f = 0; f < frames; f++) {
                double g = gain_a + (gain_b - gain_a) * f / frames;
                for (int s = 0; s < src_ch; s++) {
                    float v = src[f * src_ch + s] * (float) g;
                    if (v == 0) continue;
                    for (int d = 0; d < dst_ch; d++) {
                        float k = gains[s * dst_ch + d];
                        if (k != 0) dst[f * dst_ch + d] += v * k;
                    }
                }
            }
        }

        private static double db(double v) {
            return v <= -60 ? 0 : Math.pow(10, v / 20);
        }

        private void apply_effect_lanes(Track t, int64 frame) {
            foreach (var l in t.lanes) {
                if (!l.active || !l.target.has_prefix("fx:")) continue;
                string[] parts = l.target.split(":");
                if (parts.length < 3) continue;
                int idx = int.parse(parts[1]);
                if (idx < 0 || idx >= t.rack.effects.size) continue;
                var p = t.rack.effects[idx].find(parts[2]);
                if (p == null) continue;
                double v = p.min + (p.max - p.min) * l.value_at(frame);
                if (Math.fabs(p.value - v) > 1e-6) p.value = v;
            }
        }

        private void mix_clips(Track t, int64 start, int frames, float[] tbuf) {
            int tch = t.channels;
            if (clip_buf.length < frames * 8) clip_buf = new float[frames * 8];
            foreach (var c in t.clips) {
                if (c.muted || c.end <= start || c.position >= start + frames || c.source == null) continue;
                int64 a = int64.max(start, c.position);
                int64 b = int64.min(start + frames, c.end);
                int n = (int) (b - a);
                int cch = c.rendered != null ? c.rendered.channels : c.source.channels;
                c.read(a, n, clip_buf, cch);
                if (c.rack.has_realtime()) {
                    c.rack.configure(session.rate, cch);
                    c.rack.process(clip_buf, n);
                }
                double g = Math.pow(10, c.gain_db / 20);
                var overlaps = new Gee.ArrayList<Clip>();
                foreach (var o in t.clips) {
                    if (o != c && !o.muted && o.position < c.end && o.end > c.position) overlaps.add(o);
                }
                for (int i = 0; i < n; i++) {
                    int64 frame = a + i;
                    double k = g * c.gain_at(frame);
                    foreach (var o in overlaps) {
                        if (o.position < c.position && o.end > c.position && frame < o.end) {
                            double span = (double) (int64.min(o.end, c.end) - c.position);
                            k *= Math.sin(Math.PI / 2 * ((frame - c.position) / span).clamp(0, 1));
                        } else if (o.position > c.position && o.position < c.end && o.end > c.end && frame >= o.position) {
                            double span = (double) (c.end - o.position);
                            k *= Math.cos(Math.PI / 2 * ((frame - o.position) / span).clamp(0, 1));
                        }
                    }
                    int off = (int) (a - start + i) * tch;
                    for (int ch = 0; ch < tch; ch++) {
                        float v = cch == tch ? clip_buf[i * cch + ch] : cch == 1 ? clip_buf[i] : (tch == 1 ? 0.5f * (clip_buf[i * cch] + clip_buf[i * cch + 1]) : (ch < cch ? clip_buf[i * cch + ch] : 0));
                        tbuf[off + ch] += (float) (v * k);
                    }
                }
            }
        }

        private Gee.List<Track> bus_order() {
            var order = new Gee.ArrayList<Track>();
            var pending = new Gee.ArrayList<Track>();
            foreach (var t in session.tracks) {
                if (t.kind == TrackKind.BUS) pending.add(t);
            }
            int guard = 0;
            while (pending.size > 0 && guard++ < 64) {
                foreach (var b in pending.read_only_view) {
                    bool ready = true;
                    foreach (var other in pending) {
                        if (other == b) continue;
                        if (other.output == b.id) ready = false;
                        foreach (var s in other.sends) {
                            if (s.bus == b.id) ready = false;
                        }
                    }
                    if (ready) {
                        order.add(b);
                        pending.remove(b);
                        break;
                    }
                }
            }
            order.add_all(pending);
            return order;
        }

        private void process_strip(Track t, int64 start, int frames, float[] tbuf, bool audible) {
            int tch = t.channels;
            apply_effect_lanes(t, start);
            t.rack.configure(session.rate, tch);
            t.rack.process(tbuf, frames);
            var lane = t.find_lane("volume");
            bool use_lanes = t.automation != AutomationMode.OFF && t.automation != AutomationMode.WRITE;
            double vol_a = lane != null && lane.active && use_lanes ? lane.value_at(start) : t.volume_db;
            double vol_b = lane != null && lane.active && use_lanes ? lane.value_at(start + frames) : t.volume_db;
            var pan_lane = t.find_lane("pan");
            double pan = pan_lane != null && pan_lane.active && use_lanes ? pan_lane.value_at(start) : t.pan;
            if (recorder != null) recorder.capture(t, start, vol_a, pan);
            double ga = db(vol_a);
            double gb = db(vol_b);
            bool silent = !audible;
            foreach (var s in t.sends) {
                var bus = session.find_track(s.bus);
                if (bus == null || bus == t || silent) continue;
                var bfb = buffers[bus.id];
                if (bfb == null) continue;
                unowned float[] bbuf = bfb.data;
                var sg = new float[tch * bus.channels];
                pan_gains(tch, bus.channels, pan, t.azimuth, t.spread, t.lfe, sg);
                var send_lane = t.find_lane("send:" + s.bus);
                double level = send_lane != null && send_lane.active && use_lanes ? send_lane.value_at(start) : s.level_db;
                double k = db(level);
                route(tbuf, tch, bbuf, bus.channels, frames, sg, s.pre_fader ? k : k * ga, s.pre_fader ? k : k * gb);
            }
            var m = meter_for(t.id);
            for (int ch = 0; ch < int.min(tch, 8); ch++) {
                float p = 0;
                for (int f = 0; f < frames; f++) p = float.max(p, Math.fabsf(tbuf[f * tch + ch]));
                m.peak[ch] = silent ? 0 : (float) (p * gb);
            }
            float red = 0;
            foreach (var e in t.rack.effects) {
                var d = e as DynamicsEffect;
                if (d != null && !d.bypass) red = float.max(red, d.last_reduction);
            }
            m.reduction = red;
            if (silent) return;
            var dest = session.find_track(t.output) ?? session.master;
            if (dest == t) dest = session.master;
            var dfb = buffers[dest.id];
            if (dfb == null) return;
            unowned float[] dbuf = dfb.data;
            var g = new float[tch * dest.channels];
            pan_gains(tch, dest.channels, pan, t.azimuth, t.spread, t.lfe, g);
            route(tbuf, tch, dbuf, dest.channels, frames, g, ga, gb);
        }

        public void render(int64 start, int frames, float[] dest) {
            mutex.lock();
            if (expected != start) {
                foreach (var t in session.tracks) t.rack.reset();
            }
            expected = start + frames;
            int mch = session.channels;
            unowned float[] mbuf = buffer_for("master", frames * mch);
            var buses = bus_order();
            foreach (var b in buses) buffer_for(b.id, frames * b.channels);
            bool solo = session.any_solo();
            foreach (var t in session.tracks) {
                if (t.kind != TrackKind.AUDIO) continue;
                unowned float[] tbuf = buffer_for("t:" + t.id, frames * t.channels);
                mix_clips(t, start, frames, tbuf);
                bool audible = !t.mute && (!solo || t.solo);
                if (only_track != null) audible = t.id == only_track;
                process_strip(t, start, frames, tbuf, audible);
            }
            foreach (var b in buses) {
                unowned float[] bbuf = buffers[b.id].data;
                bool audible = !b.mute && (!solo || b.solo || !has_soloed_sources(b));
                if (only_track != null) audible = audible && feeds_track(b);
                process_strip(b, start, frames, bbuf, audible);
            }
            if (!skip_master_rack) {
                session.master.rack.configure(session.rate, mch);
                apply_effect_lanes(session.master, start);
                session.master.rack.process(mbuf, frames);
            }
            var mlane = session.master.find_lane("volume");
            double mv_a = mlane != null && mlane.active ? mlane.value_at(start) : session.master.volume_db;
            double mv_b = mlane != null && mlane.active ? mlane.value_at(start + frames) : session.master.volume_db;
            if (session.master.mute) mv_a = mv_b = -100;
            for (int f = 0; f < frames; f++) {
                double g = db(mv_a + (mv_b - mv_a) * f / frames);
                for (int c = 0; c < mch; c++) dest[f * mch + c] = (float) (mbuf[f * mch + c] * g);
            }
            if (include_metronome && session.metronome) add_click(start, frames, dest, mch);
            var mm = meter_for("master");
            for (int c = 0; c < int.min(mch, 8); c++) {
                float p = 0;
                for (int f = 0; f < frames; f++) p = float.max(p, Math.fabsf(dest[f * mch + c]));
                mm.peak[c] = p;
            }
            mutex.unlock();
        }

        private bool has_soloed_sources(Track bus) {
            foreach (var t in session.tracks) {
                if (t.solo && (t.output == bus.id)) return true;
                foreach (var s in t.sends) {
                    if (t.solo && s.bus == bus.id) return true;
                }
            }
            return false;
        }

        private bool feeds_track(Track bus) {
            var t = session.find_track(only_track);
            if (t == null) return false;
            if (t.output == bus.id) return true;
            foreach (var s in t.sends) {
                if (s.bus == bus.id) return true;
            }
            return false;
        }

        private void add_click(int64 start, int frames, float[] dest, int ch) {
            int64 beat = session.grid_frames();
            if (beat <= 0) return;
            int click_len = session.rate / 30;
            int64 first = (start / beat) * beat;
            for (int64 b = first; b < start + frames; b += beat) {
                bool accent = (b / beat) % session.beats_per_bar == 0;
                double freq = accent ? 1760 : 1320;
                for (int i = 0; i < click_len; i++) {
                    int64 f = b + i - start;
                    if (f < 0 || f >= frames) continue;
                    float v = (float) (Math.sin(2 * Math.PI * freq * i / session.rate) * Math.exp(-i * 8.0 / click_len) * (accent ? 0.5 : 0.35));
                    for (int c = 0; c < int.min(ch, 2); c++) dest[f * ch + c] += v;
                }
            }
        }

        public void prepare_clips() throws Error {
            foreach (var t in session.tracks) {
                foreach (var c in t.clips) c.prepare_render();
            }
        }
    }

    public class AutomationRecorder : Object {
        public Gee.HashMap<string, double?> touched = new Gee.HashMap<string, double?>();
        public Gee.HashMap<string, double?> live_volume = new Gee.HashMap<string, double?>();
        public Gee.HashMap<string, double?> live_pan = new Gee.HashMap<string, double?>();
        private Mutex mutex;
        private Gee.ArrayList<string> pending = new Gee.ArrayList<string>();

        public void touch(Track t, string target, double value) {
            mutex.lock();
            if (target == "volume") live_volume[t.id] = value;
            else live_pan[t.id] = value;
            touched[t.id + ":" + target] = value;
            mutex.unlock();
        }

        public void release(Track t, string target) {
            mutex.lock();
            touched.unset(t.id + ":" + target);
            mutex.unlock();
        }

        public void capture(Track t, int64 frame, double volume, double pan) {
            if (t.automation == AutomationMode.OFF || t.automation == AutomationMode.READ) return;
            mutex.lock();
            foreach (string target in new string[] { "volume", "pan" }) {
                string key = t.id + ":" + target;
                bool active = touched.has_key(key);
                double? live = target == "volume" ? live_volume[t.id] : live_pan[t.id];
                bool write = t.automation == AutomationMode.WRITE || (t.automation == AutomationMode.TOUCH && active) || (t.automation == AutomationMode.LATCH && live != null);
                if (!write) continue;
                double v = live ?? (target == "volume" ? t.volume_db : t.pan);
                var lane = t.lane(target);
                lane.remove_range(frame, frame + 1023);
                lane.add(frame, v);
            }
            mutex.unlock();
        }
    }
}
