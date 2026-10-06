namespace Singularity.Apps.Wave {

    public enum TrackKind {
        AUDIO,
        BUS,
        VIDEO;

        public string id() {
            return this == BUS ? "bus" : this == VIDEO ? "video" : "audio";
        }

        public static TrackKind from_id(string id) {
            return id == "bus" ? BUS : id == "video" ? VIDEO : AUDIO;
        }
    }

    public enum AutomationMode {
        OFF,
        READ,
        WRITE,
        TOUCH,
        LATCH;

        public string id() {
            switch (this) {
            case READ: return "read";
            case WRITE: return "write";
            case TOUCH: return "touch";
            case LATCH: return "latch";
            default: return "off";
            }
        }

        public string label() {
            switch (this) {
            case READ: return _("Read");
            case WRITE: return _("Write");
            case TOUCH: return _("Touch");
            case LATCH: return _("Latch");
            default: return _("Off");
            }
        }

        public static AutomationMode from_id(string id) {
            switch (id) {
            case "read": return READ;
            case "write": return WRITE;
            case "touch": return TOUCH;
            case "latch": return LATCH;
            default: return OFF;
            }
        }
    }

    public class AutomationPoint {
        public int64 frame;
        public double value;
        public int curve;

        public AutomationPoint(int64 frame, double value, int curve = 0) {
            this.frame = frame;
            this.value = value;
            this.curve = curve;
        }
    }

    public class AutomationLane : Object {
        public string target { get; set; }
        public bool visible { get; set; default = true; }
        public Gee.ArrayList<AutomationPoint> points { get; default = new Gee.ArrayList<AutomationPoint>(); }
        public double min_value { get; set; default = 0; }
        public double max_value { get; set; default = 1; }
        public double fallback { get; set; default = 0; }

        public AutomationLane(string target) {
            Object(target: target);
            if (target == "volume") {
                min_value = -60;
                max_value = 12;
            } else if (target == "pan") {
                min_value = -1;
                max_value = 1;
            }
        }

        public bool active {
            get { return points.size > 0; }
        }

        public void sort() {
            points.sort((a, b) => a.frame < b.frame ? -1 : a.frame > b.frame ? 1 : 0);
        }

        public void add(int64 frame, double value, int curve = 0) {
            foreach (var p in points) {
                if (p.frame == frame) {
                    p.value = value;
                    return;
                }
            }
            points.add(new AutomationPoint(frame, value.clamp(min_value, max_value), curve));
            sort();
        }

        public void remove_range(int64 a, int64 b) {
            var keep = new Gee.ArrayList<AutomationPoint>();
            foreach (var p in points) {
                if (p.frame < a || p.frame > b) keep.add(p);
            }
            points.clear();
            points.add_all(keep);
        }

        public double value_at(int64 frame) {
            if (points.size == 0) return fallback;
            if (frame <= points[0].frame) return points[0].value;
            var last = points[points.size - 1];
            if (frame >= last.frame) return last.value;
            int lo = 0, hi = points.size - 1;
            while (hi - lo > 1) {
                int mid = (lo + hi) / 2;
                if (points[mid].frame <= frame) lo = mid;
                else hi = mid;
            }
            var a = points[lo];
            var b = points[hi];
            double t = (double) (frame - a.frame) / (double) int64.max(1, b.frame - a.frame);
            switch (a.curve) {
            case 1:
                return a.value;
            case 2:
                t = 0.5 - 0.5 * Math.cos(Math.PI * t);
                break;
            default:
                break;
            }
            return a.value + (b.value - a.value) * t;
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("target", target);
            o.set_boolean_member("visible", visible);
            var a = new Json.Array();
            foreach (var p in points) {
                var po = new Json.Array();
                po.add_int_element(p.frame);
                po.add_double_element(p.value);
                po.add_int_element(p.curve);
                a.add_array_element(po);
            }
            o.set_array_member("points", a);
            return o;
        }

        public static AutomationLane from_json(Json.Object o) {
            var l = new AutomationLane(o.get_string_member("target"));
            l.visible = o.get_boolean_member_with_default("visible", true);
            foreach (var n in o.get_array_member("points").get_elements()) {
                var p = n.get_array();
                l.points.add(new AutomationPoint(p.get_int_element(0), p.get_double_element(1), (int) p.get_int_element(2)));
            }
            l.sort();
            return l;
        }
    }

    public class Send : Object {
        public string bus { get; set; }
        public double level_db { get; set; default = -6; }
        public bool pre_fader { get; set; default = false; }

        public Send(string bus) {
            Object(bus: bus);
        }
    }

    public class VideoSegment {
        public string uri;
        public int64 position;
        public int64 start_ms;
        public int64 end_ms;

        public VideoSegment(string uri, int64 position, int64 start_ms, int64 end_ms) {
            this.uri = uri;
            this.position = position;
            this.start_ms = start_ms;
            this.end_ms = end_ms;
        }
    }

    public class Take {
        public PcmSource source;
        public string path;
        public int64 offset;
        public string name;

        public Take(PcmSource source, string path, int64 offset, string name) {
            this.source = source;
            this.path = path;
            this.offset = offset;
            this.name = name;
        }
    }

    public class Clip : Object {
        public string id { get; set; default = Uuid.string_random(); }
        public string name { get; set; default = ""; }
        public string path { get; set; default = ""; }
        public PcmSource? source { get; set; }
        public int64 source_offset { get; set; default = 0; }
        public int64 length { get; set; default = 0; }
        public int64 position { get; set; default = 0; }
        public double gain_db { get; set; default = 0; }
        public int64 fade_in { get; set; default = 0; }
        public int64 fade_out { get; set; default = 0; }
        public int fade_in_curve { get; set; default = 2; }
        public int fade_out_curve { get; set; default = 2; }
        public double stretch { get; set; default = 1.0; }
        public double pitch { get; set; default = 0; }
        public bool muted { get; set; default = false; }
        public string role { get; set; default = ""; }
        public EffectRack rack { get; set; }
        public Gee.ArrayList<Take> takes { get; default = new Gee.ArrayList<Take>(); }
        public int active_take { get; set; default = -1; }
        public PcmSource? rendered = null;
        public string rendered_key = "";

        public int64 end {
            get { return position + length; }
        }

        public Clip(PcmSource source, string path, int64 position) {
            Object(source: source, path: path, position: position);
            length = source.frames;
            name = Path.get_basename(path) != "" ? Path.get_basename(path) : _("Clip");
            rack = new EffectRack(source.rate, source.channels);
        }

        public bool needs_render() {
            return stretch != 1.0 || pitch != 0 || rack.has_offline();
        }

        public string render_key() {
            string fx = rack.has_offline() ? Json.to_string(json_node(rack.to_json()), false) : "";
            return "%s:%lld:%lld:%g:%g:%u".printf(source.path, source_offset, length, stretch, pitch, fx.hash());
        }

        private static Json.Node json_node(Json.Object o) {
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(o);
            return n;
        }

        public void prepare_render() throws Error {
            if (!needs_render()) {
                rendered = null;
                rendered_key = "";
                return;
            }
            string key = render_key();
            if (key == rendered_key && rendered != null) return;
            int ch = source.channels;
            int64 src_len = (int64) Math.ceil(length / stretch);
            var buf = new float[src_len * ch];
            source.read(source_offset, src_len, buf);
            rack.configure(source.rate, ch);
            rack.process_offline(buf, (int) src_len);
            float[] data = buf;
            int64 frames = src_len;
            if (stretch != 1.0 || pitch != 0) {
                int64 cap = WaveDsp.stretch_frames(src_len, stretch) + 16;
                var res = new float[cap * ch];
                frames = WaveDsp.time_stretch(buf, src_len, ch, source.rate, stretch, pitch, res, cap);
                data = res;
            }
            rendered = PcmSource.from_samples(data, source.rate, ch);
            rendered_key = key;
        }

        public void read(int64 timeline_start, int frames, float[] dest, int dest_channels) {
            int64 local = timeline_start - position;
            if (rendered != null) rendered.read(local, frames, dest, 0, dest_channels);
            else source.read(source_offset + local, frames, dest, 0, dest_channels);
        }

        public double gain_at(int64 timeline_frame) {
            int64 local = timeline_frame - position;
            double g = 1;
            if (fade_in > 0 && local < fade_in) g *= WaveDsp.fade_gain((double) local / fade_in, fade_in_curve);
            if (fade_out > 0 && local > length - fade_out) g *= WaveDsp.fade_gain((double) (length - local) / fade_out, fade_out_curve);
            return g;
        }

        public void use_take(int index) {
            if (index < 0 || index >= takes.size) return;
            var t = takes[index];
            source = t.source;
            path = t.path;
            source_offset = t.offset;
            active_take = index;
            rendered = null;
        }

        public Clip duplicate() {
            var c = new Clip(source, path, position);
            c.name = name;
            c.source_offset = source_offset;
            c.length = length;
            c.gain_db = gain_db;
            c.fade_in = fade_in;
            c.fade_out = fade_out;
            c.fade_in_curve = fade_in_curve;
            c.fade_out_curve = fade_out_curve;
            c.stretch = stretch;
            c.pitch = pitch;
            c.muted = muted;
            c.role = role;
            c.rack = rack.copy();
            foreach (var t in takes) c.takes.add(t);
            c.active_take = active_take;
            return c;
        }
    }

    public class Track : Object {
        public string id { get; set; default = Uuid.string_random(); }
        public string name { get; set; default = ""; }
        public TrackKind kind { get; set; default = TrackKind.AUDIO; }
        public int channels { get; set; default = 2; }
        public Gee.ArrayList<Clip> clips { get; default = new Gee.ArrayList<Clip>(); }
        public double volume_db { get; set; default = 0; }
        public double pan { get; set; default = 0; }
        public double azimuth { get; set; default = 0; }
        public double spread { get; set; default = 0; }
        public double lfe { get; set; default = 0; }
        public bool mute { get; set; default = false; }
        public bool solo { get; set; default = false; }
        public bool armed { get; set; default = false; }
        public bool monitor { get; set; default = false; }
        public string input { get; set; default = ""; }
        public string output { get; set; default = "master"; }
        public Gee.ArrayList<Send> sends { get; default = new Gee.ArrayList<Send>(); }
        public EffectRack rack { get; set; }
        public Gee.ArrayList<AutomationLane> lanes { get; default = new Gee.ArrayList<AutomationLane>(); }
        public AutomationMode automation { get; set; default = AutomationMode.READ; }
        public string role { get; set; default = ""; }
        public bool duck { get; set; default = false; }
        public double duck_db { get; set; default = -15; }
        public string color { get; set; default = "#3584e4"; }
        public Gee.ArrayList<VideoSegment> video_segments { get; default = new Gee.ArrayList<VideoSegment>(); }

        public Track(string name, TrackKind kind, int channels, int rate) {
            Object(name: name, kind: kind, channels: channels);
            rack = new EffectRack(rate, channels);
        }

        public AutomationLane lane(string target, bool create = true) {
            foreach (var l in lanes) {
                if (l.target == target) return l;
            }
            var l = new AutomationLane(target);
            if (target == "volume") l.fallback = volume_db;
            if (create) lanes.add(l);
            return l;
        }

        public AutomationLane? find_lane(string target) {
            foreach (var l in lanes) {
                if (l.target == target) return l;
            }
            return null;
        }

        public int64 end {
            get {
                int64 e = 0;
                foreach (var c in clips) e = int64.max(e, c.end);
                return e;
            }
        }

        public void sort_clips() {
            clips.sort((a, b) => a.position < b.position ? -1 : a.position > b.position ? 1 : 0);
        }

        public Clip? clip_at(int64 frame) {
            Clip? found = null;
            foreach (var c in clips) {
                if (frame >= c.position && frame < c.end) found = c;
            }
            return found;
        }
    }

    public class Session : Object, Renderable {
        public string path { get; set; default = ""; }
        public string title { get; set; default = ""; }
        public int rate { get; set; default = 48000; }
        public int channels { get; set; default = 2; }
        public Gee.ArrayList<Track> tracks { get; default = new Gee.ArrayList<Track>(); }
        public Track master { get; set; }
        public double tempo { get; set; default = 120; }
        public int beats_per_bar { get; set; default = 4; }
        public bool metronome { get; set; default = false; }
        public bool snap_to_grid { get; set; default = false; }
        public Gee.ArrayList<Marker> markers { get; default = new Gee.ArrayList<Marker>(); }
        public Metadata metadata { get; set; default = new Metadata(); }
        public bool modified { get; set; default = false; }
        public string template { get; set; default = ""; }
        public double loudness_target { get; set; default = -16; }
        public Gee.ArrayList<string> history { get; default = new Gee.ArrayList<string>(); }
        public Gee.ArrayList<string> history_labels { get; default = new Gee.ArrayList<string>(); }
        public int history_index { get; private set; default = -1; }
        public SessionMixer mixer { get; private set; }
        public string transcript_json { get; set; default = ""; }

        public signal void changed();
        public signal void structure_changed();

        public int sample_rate { get { return rate; } }
        public int channel_count { get { return channels; } }
        public int64 total_frames { get { return length; } }

        public Session(int rate, int channels) {
            Object(rate: rate, channels: channels);
            master = new Track(_("Master"), TrackKind.BUS, channels, rate);
            master.id = "master";
            master.output = "";
            mixer = new SessionMixer(this);
        }

        public int64 length {
            get {
                int64 e = 0;
                foreach (var t in tracks) {
                    if (t.kind == TrackKind.AUDIO) e = int64.max(e, t.end);
                }
                return e;
            }
        }

        public Track add_track(string name, TrackKind kind = TrackKind.AUDIO, int ch = 0) {
            var t = new Track(name, kind, ch > 0 ? ch : (kind == TrackKind.BUS ? channels : 2), rate);
            string[] colors = { "#3584e4", "#2ec27e", "#e5a50a", "#c061cb", "#e66100", "#1c71d8", "#26a269", "#a51d2d" };
            t.color = colors[tracks.size % colors.length];
            tracks.add(t);
            structure_changed();
            return t;
        }

        public Track? find_track(string id) {
            if (id == "master") return master;
            foreach (var t in tracks) {
                if (t.id == id) return t;
            }
            return null;
        }

        public Gee.List<Track> buses() {
            var list = new Gee.ArrayList<Track>();
            foreach (var t in tracks) {
                if (t.kind == TrackKind.BUS) list.add(t);
            }
            return list;
        }

        public Track? video_track() {
            foreach (var t in tracks) {
                if (t.kind == TrackKind.VIDEO) return t;
            }
            return null;
        }

        public Clip add_clip(Track track, PcmSource source, string path, int64 position) {
            var c = new Clip(source, path, position);
            c.rack.configure(rate, source.channels);
            track.clips.add(c);
            track.sort_clips();
            return c;
        }

        public void render(int64 start, int frames, float[] dest) {
            mixer.render(start, frames, dest);
        }

        public void seek_hint(int64 frame) {
            mixer.reset();
        }

        public int64 grid_frames() {
            return (int64) (rate * 60.0 / tempo);
        }

        public int64 snap(int64 frame) {
            if (!snap_to_grid) return frame;
            int64 g = grid_frames();
            return ((frame + g / 2) / g) * g;
        }

        public void checkpoint(string label) {
            while (history.size > history_index + 1) {
                history.remove_at(history.size - 1);
                history_labels.remove_at(history_labels.size - 1);
            }
            history.add(SessionFile.to_string(this));
            history_labels.add(label);
            history_index = history.size - 1;
            if (history.size > 1) modified = true;
        }

        public bool can_undo {
            get { return history_index > 0; }
        }

        public bool can_redo {
            get { return history_index < history.size - 1; }
        }

        public void restore(int index) {
            if (index < 0 || index >= history.size) return;
            SessionFile.restore_into(this, history[index]);
            history_index = index;
            modified = true;
            structure_changed();
            changed();
        }

        public void undo() {
            if (can_undo) restore(history_index - 1);
        }

        public void redo() {
            if (can_redo) restore(history_index + 1);
        }

        public bool any_solo() {
            foreach (var t in tracks) {
                if (t.solo) return true;
            }
            return false;
        }

        public void clear_tracks() {
            tracks.clear();
        }
    }
}
