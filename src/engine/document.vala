namespace Singularity.Apps.Wave {

    public interface Renderable : Object {
        public abstract int sample_rate { get; }
        public abstract int channel_count { get; }
        public abstract int64 total_frames { get; }
        public abstract void render(int64 start, int frames, float[] dest);
        public virtual void seek_hint(int64 frame) {
        }
    }

    public class Segment {
        public PcmSource? source;
        public int64 offset;
        public int64 length;

        public Segment(PcmSource? source, int64 offset, int64 length) {
            this.source = source;
            this.offset = offset;
            this.length = length;
        }

        public Segment slice(int64 from, int64 count) {
            return new Segment(source, offset + from, count);
        }
    }

    public class Snapshot {
        public string label;
        public Segment[] segments;
        public Marker[] markers;
        public int64 time;
    }

    public class Document : Object, Renderable {
        public string path { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public int rate { get; private set; }
        public int channels { get; private set; }
        public int64 length { get; private set; default = 0; }
        public Metadata metadata { get; set; default = new Metadata(); }
        public bool modified { get; set; default = false; }
        public EffectRack rack { get; private set; }
        public Gee.ArrayList<Marker> markers { get; default = new Gee.ArrayList<Marker>(); }
        public Gee.ArrayList<Snapshot> history { get; default = new Gee.ArrayList<Snapshot>(); }
        public int history_index { get; private set; default = -1; }
        public NoiseCapture noise { get; default = new NoiseCapture(); }
        public string transcript_json { get; set; default = ""; }
        public bool has_video { get; set; default = false; }

        public signal void changed();
        public signal void markers_changed();

        private Segment[] segments = {};

        public int sample_rate { get { return rate; } }
        public int channel_count { get { return channels; } }
        public int64 total_frames { get { return length; } }

        public Document(int rate, int channels) {
            this.rate = rate;
            this.channels = channels;
            rack = new EffectRack(rate, channels);
        }

        public static Document from_media(DecodedMedia media) {
            var d = new Document(media.source.rate, media.source.channels);
            d.path = media.path;
            d.title = Path.get_basename(media.path);
            d.metadata = media.metadata;
            d.has_video = media.has_video;
            d.segments = { new Segment(media.source, 0, media.source.frames) };
            d.length = media.source.frames;
            foreach (var m in media.markers) d.markers.add(m);
            d.checkpoint(_("Open"));
            return d;
        }

        public static Document from_source(PcmSource source, string title) {
            var d = new Document(source.rate, source.channels);
            d.title = title;
            d.segments = { new Segment(source, 0, source.frames) };
            d.length = source.frames;
            d.checkpoint(_("New"));
            return d;
        }

        public Segment[] get_segments() {
            return segments;
        }

        private void recount() {
            int64 n = 0;
            foreach (var s in segments) n += s.length;
            length = n;
        }

        public void render(int64 start, int frames, float[] dest) {
            for (int i = 0; i < frames * channels; i++) dest[i] = 0;
            int64 pos = 0;
            int64 end = start + frames;
            foreach (var s in segments) {
                if (pos >= end) break;
                int64 s_end = pos + s.length;
                if (s_end > start && s.source != null) {
                    int64 a = int64.max(start, pos);
                    int64 b = int64.min(end, s_end);
                    s.source.read(s.offset + (a - pos), b - a, dest, a - start, channels);
                }
                pos = s_end;
            }
        }

        public float[] read(int64 start, int64 frames) {
            var buf = new float[frames * channels];
            int64 done = 0;
            while (done < frames) {
                int n = (int) int64.min(frames - done, 1 << 20);
                var block = new float[n * channels];
                render(start + done, n, block);
                Memory.copy(&buf[done * channels], block, n * channels * sizeof(float));
                done += n;
            }
            return buf;
        }

        private Segment[] cut_segments(int64 from, int64 to) {
            Segment[] result = {};
            int64 pos = 0;
            foreach (var s in segments) {
                int64 s_end = pos + s.length;
                if (s_end > from && pos < to) {
                    int64 a = int64.max(from, pos);
                    int64 b = int64.min(to, s_end);
                    result += s.slice(a - pos, b - a);
                }
                pos = s_end;
            }
            return result;
        }

        public Segment[] copy_range(int64 from, int64 to) {
            return cut_segments(from.clamp(0, length), to.clamp(0, length));
        }

        public void replace(int64 from, int64 to, Segment[] with, string label) {
            from = from.clamp(0, length);
            to = to.clamp(from, length);
            Segment[] next = {};
            foreach (var s in cut_segments(0, from)) next += s;
            int64 inserted = 0;
            foreach (var s in with) {
                if (s.length <= 0) continue;
                next += s;
                inserted += s.length;
            }
            foreach (var s in cut_segments(to, length)) next += s;
            segments = merge(next);
            shift_markers(from, to, inserted);
            recount();
            modified = true;
            checkpoint(label);
            changed();
        }

        private static Segment[] merge(Segment[] list) {
            Segment[] out_list = {};
            foreach (var s in list) {
                if (out_list.length > 0) {
                    var last = out_list[out_list.length - 1];
                    if (last.source == s.source && (s.source == null || last.offset + last.length == s.offset)) {
                        out_list[out_list.length - 1] = new Segment(last.source, last.offset, last.length + s.length);
                        continue;
                    }
                }
                out_list += s;
            }
            return out_list;
        }

        private void shift_markers(int64 from, int64 to, int64 inserted) {
            int64 delta = inserted - (to - from);
            if (delta == 0) return;
            var keep = new Gee.ArrayList<Marker>();
            foreach (var m in markers) {
                if (m.start >= to) {
                    m.start += delta;
                } else if (m.start >= from && delta < 0 && m.start < to) {
                    if (inserted == 0 && !m.is_range) continue;
                    m.start = from;
                }
                if (m.is_range && m.end > from && m.start < from) m.length = int64.max(0, m.length + (m.end >= to ? delta : from - m.end));
                keep.add(m);
            }
            markers.clear();
            markers.add_all(keep);
            markers_changed();
        }

        public void delete_range(int64 from, int64 to) {
            replace(from, to, {}, _("Delete"));
        }

        public void insert(int64 at, Segment[] clip, string label = _("Paste")) {
            replace(at, at, clip, label);
        }

        public void silence(int64 from, int64 to) {
            replace(from, to, { new Segment(null, 0, to - from) }, _("Silence"));
        }

        public void insert_silence(int64 at, int64 frames) {
            replace(at, at, { new Segment(null, 0, frames) }, _("Insert Silence"));
        }

        public void trim_to(int64 from, int64 to) {
            var keep = copy_range(from, to);
            segments = keep;
            var moved = new Gee.ArrayList<Marker>();
            foreach (var m in markers) {
                if (m.start >= from && m.start < to) {
                    m.start -= from;
                    moved.add(m);
                }
            }
            markers.clear();
            markers.add_all(moved);
            recount();
            modified = true;
            checkpoint(_("Crop"));
            changed();
            markers_changed();
        }

        public delegate void BlockFunc(float[] buf, int frames, int channels, int rate) throws Error;

        public void process(int64 from, int64 to, string label, BlockFunc func) throws Error {
            from = from.clamp(0, length);
            to = to.clamp(from, length);
            if (to <= from) {
                from = 0;
                to = length;
            }
            var buf = read(from, to - from);
            func(buf, (int) (to - from), channels, rate);
            var src = PcmSource.from_samples(buf, rate, channels);
            replace(from, to, { new Segment(src, 0, src.frames) }, label);
        }

        public void process_replace(int64 from, int64 to, string label, float[] result, int64 result_frames) throws Error {
            var src = PcmSource.from_samples(result, rate, channels);
            replace(from, to, { new Segment(src, 0, int64.min(src.frames, result_frames)) }, label);
        }

        public void convert(int new_rate, int new_channels, string label) throws Error {
            var buf = read(0, length);
            float[] data = buf;
            int64 frames = length;
            if (new_channels != channels) {
                var mixed = new float[frames * new_channels];
                for (int64 f = 0; f < frames; f++) {
                    if (new_channels == 1) {
                        float sum = 0;
                        for (int c = 0; c < channels; c++) sum += data[f * channels + c];
                        mixed[f] = sum / channels;
                    } else {
                        for (int c = 0; c < new_channels; c++) mixed[f * new_channels + c] = channels == 1 ? data[f] : (c < channels ? data[f * channels + c] : 0);
                    }
                }
                data = mixed;
            }
            if (new_rate != rate) {
                int64 n = WaveDsp.resample_frames(frames, rate, new_rate);
                var res = new float[n * new_channels];
                frames = WaveDsp.resample(data, frames, new_channels, rate, new_rate, res, n);
                data = res;
            }
            var src = PcmSource.from_samples(data, new_rate, new_channels);
            foreach (var m in markers) {
                m.start = m.start * new_rate / int64.max(1, rate);
                m.length = m.length * new_rate / int64.max(1, rate);
            }
            rate = new_rate;
            channels = new_channels;
            rack.configure(rate, channels);
            segments = { new Segment(src, 0, frames) };
            recount();
            modified = true;
            checkpoint(label);
            changed();
        }

        public void checkpoint(string label) {
            while (history.size > history_index + 1) history.remove_at(history.size - 1);
            var snap = new Snapshot();
            snap.label = label;
            snap.segments = segments;
            Marker[] ms = {};
            foreach (var m in markers) ms += m.copy();
            snap.markers = ms;
            snap.time = get_real_time();
            history.add(snap);
            history_index = history.size - 1;
        }

        public void marker_checkpoint(string label) {
            modified = true;
            checkpoint(label);
            markers_changed();
        }

        public bool can_undo {
            get { return history_index > 0; }
        }

        public bool can_redo {
            get { return history_index < history.size - 1; }
        }

        public void restore(int index) {
            if (index < 0 || index >= history.size) return;
            var snap = history[index];
            segments = snap.segments;
            markers.clear();
            foreach (var m in snap.markers) markers.add(m.copy());
            history_index = index;
            recount();
            modified = true;
            changed();
            markers_changed();
        }

        public void undo() {
            if (can_undo) restore(history_index - 1);
        }

        public void redo() {
            if (can_redo) restore(history_index + 1);
        }

        public int64 snap_zero(int64 frame, int64 radius = -1) {
            if (radius < 0) radius = rate / 100;
            int64 a = int64.max(0, frame - radius);
            int64 b = int64.min(length - 1, frame + radius);
            if (b <= a) return frame.clamp(0, length);
            var buf = read(a, b - a + 1);
            int64 best = frame;
            int64 best_dist = int64.MAX;
            for (int64 i = 0; i < b - a; i++) {
                float s0 = 0, s1 = 0;
                for (int c = 0; c < channels; c++) {
                    s0 += buf[i * channels + c];
                    s1 += buf[(i + 1) * channels + c];
                }
                bool crossing = (s0 <= 0 && s1 > 0) || (s0 >= 0 && s1 < 0) || s0 == 0;
                if (!crossing) continue;
                int64 at = Math.fabsf(s0) <= Math.fabsf(s1) ? a + i : a + i + 1;
                int64 dist = (at - frame).abs();
                if (dist < best_dist) {
                    best_dist = dist;
                    best = at;
                }
            }
            return best.clamp(0, length);
        }

        public void add_marker(Marker m) {
            markers.add(m);
            markers.sort(Marker.compare);
            marker_checkpoint(_("Add Marker"));
        }

        public void remove_marker(Marker m) {
            markers.remove(m);
            marker_checkpoint(_("Remove Marker"));
        }

        public int64[] split_points() {
            int64[] points = {};
            foreach (var m in markers) {
                if (m.start > 0 && m.start < length) points += m.start;
            }
            return points;
        }

        public void peaks(int64 start, double frames_per_pixel, int pixels, int channel, float[] lo, float[] hi) {
            for (int px = 0; px < pixels; px++) {
                lo[px] = 0;
                hi[px] = 0;
            }
            if (frames_per_pixel < PEAK_BASE) {
                int64 count = (int64) Math.ceil(frames_per_pixel * pixels) + 2;
                int64 first = start;
                var buf = new float[count * channels];
                render(first, (int) count, buf);
                for (int px = 0; px < pixels; px++) {
                    int64 a = (int64) Math.floor(px * frames_per_pixel);
                    int64 b = int64.max(a + 1, (int64) Math.floor((px + 1) * frames_per_pixel));
                    float l = float.MAX, h = -float.MAX;
                    for (int64 f = a; f < b && f < count; f++) {
                        if (first + f < 0 || first + f >= length) continue;
                        float v = buf[f * channels + channel];
                        l = float.min(l, v);
                        h = float.max(h, v);
                    }
                    if (l <= h) {
                        lo[px] = l;
                        hi[px] = h;
                    }
                }
                return;
            }
            int64 pos = 0;
            foreach (var s in segments) {
                int64 s_end = pos + s.length;
                double first_px = (pos - start) / frames_per_pixel;
                double last_px = (s_end - start) / frames_per_pixel;
                if (last_px >= 0 && first_px < pixels && s.source != null) {
                    var level = s.source.peaks.level_for(frames_per_pixel);
                    int ch = int.min(channel, s.source.channels - 1);
                    int px_a = (int) double.max(0, Math.floor(first_px));
                    int px_b = (int) double.min(pixels, Math.ceil(last_px));
                    for (int px = px_a; px < px_b; px++) {
                        int64 fa = int64.max(pos, start + (int64) (px * frames_per_pixel));
                        int64 fb = int64.min(s_end, start + (int64) ((px + 1) * frames_per_pixel));
                        if (fb <= fa) continue;
                        int64 ba = (s.offset + fa - pos) / level.block;
                        int64 bb = (s.offset + fb - pos + level.block - 1) / level.block;
                        float l = lo[px], h = hi[px];
                        for (int64 bi = ba; bi < bb && bi < level.count; bi++) {
                            l = float.min(l, level.data[(bi * s.source.channels + ch) * 2]);
                            h = float.max(h, level.data[(bi * s.source.channels + ch) * 2 + 1]);
                        }
                        lo[px] = l;
                        hi[px] = h;
                    }
                }
                pos = s_end;
                if (first_px >= pixels) break;
            }
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("title", title);
            o.set_int_member("rate", rate);
            o.set_int_member("channels", channels);
            o.set_object_member("metadata", metadata.to_json());
            var ms = new Json.Array();
            foreach (var m in markers) ms.add_object_element(m.to_json());
            o.set_array_member("markers", ms);
            o.set_object_member("rack", rack.to_json());
            return o;
        }
    }

    public class NoiseCapture : Object {
        public WaveDsp.NoiseProfile? profile = null;
        public int fft_size = 4096;
        public bool ready { get { return profile != null && profile.ready(); } }

        public void learn(float[] buf, int64 frames, int channels) {
            profile = new WaveDsp.NoiseProfile(fft_size);
            profile.learn(buf, frames, channels);
        }

        public float[] curve() {
            if (profile == null) return new float[0];
            var c = new float[profile.size()];
            profile.get(c);
            return c;
        }
    }
}
