namespace Singularity.Apps.Wave {

    public class BatchJob : Object {
        public Gee.ArrayList<string> files { get; default = new Gee.ArrayList<string>(); }
        public Json.Object? rack { get; set; default = null; }
        public bool normalize { get; set; default = false; }
        public double target_lufs { get; set; default = -16; }
        public double ceiling { get; set; default = -1; }
        public string output_dir { get; set; default = ""; }
        public string suffix { get; set; default = ""; }
        public ExportOptions options { get; set; default = new ExportOptions(); }
        public bool overwrite { get; set; default = false; }

        public signal void progress(int index, double fraction, string file);
        public signal void file_done(string input, string? output, string? error);

        private Cancellable cancellable = new Cancellable();

        public void cancel() {
            cancellable.cancel();
        }

        public static Gee.List<string> collect(string folder, bool recursive) {
            var list = new Gee.ArrayList<string>();
            try {
                var d = Dir.open(folder);
                string? name;
                while ((name = d.read_name()) != null) {
                    string p = Path.build_filename(folder, name);
                    if (FileUtils.test(p, FileTest.IS_DIR)) {
                        if (recursive) list.add_all(collect(p, true));
                    } else if (Decoder.looks_like_media(p)) {
                        list.add(p);
                    }
                }
            } catch (Error e) {
            }
            list.sort();
            return list;
        }

        public string output_for(string input) {
            string name = Path.get_basename(input);
            int dot = name.last_index_of(".");
            if (dot > 0) name = name.substring(0, dot);
            string dir = output_dir != "" ? output_dir : Path.get_dirname(input);
            string candidate = Path.build_filename(dir, "%s%s.%s".printf(name, suffix, options.format.extension()));
            if (!overwrite && candidate == input) candidate = Path.build_filename(dir, "%s-processed.%s".printf(name, options.format.extension()));
            return candidate;
        }

        public int run_sync() {
            int ok = 0;
            for (int i = 0; i < files.size; i++) {
                if (cancellable.is_cancelled()) break;
                string input = files[i];
                string output = output_for(input);
                try {
                    process_one(input, output, i);
                    ok++;
                    file_done(input, output, null);
                } catch (Error e) {
                    file_done(input, null, e.message);
                }
            }
            return ok;
        }

        public async int run() {
            int result = 0;
            SourceFunc cb = run.callback;
            new Thread<void>("wave-batch", () => {
                result = run_sync();
                Idle.add((owned) cb);
            });
            yield;
            return result;
        }

        private void process_one(string input, string output, int index) throws Error {
            var media = Decoder.decode_sync(input, cancellable);
            var src = media.source;
            var buf = new float[src.frames * src.channels];
            src.read(0, src.frames, buf);
            if (rack != null) {
                var r = new EffectRack(src.rate, src.channels);
                r.isolate_plugins = true;
                r.load_json(rack);
                r.process_all(buf, src.frames);
            }
            if (normalize) Loudness.normalize(buf, src.frames, src.channels, src.rate, target_lufs, ceiling);
            var result = PcmSource.from_samples(buf, src.rate, src.channels);
            var doc = Document.from_source(result, Path.get_basename(input));
            var o = new ExportOptions();
            o.format = options.format;
            o.bits = options.bits;
            o.is_float = options.is_float;
            o.dither = options.dither;
            o.rate = options.rate;
            o.channels = options.channels;
            o.bitrate = options.bitrate;
            o.metadata = media.metadata;
            o.markers = media.markers;
            DirUtils.create_with_parents(Path.get_dirname(output), 0755);
            Exporter.export_sync(doc, output, o, cancellable, (f) => progress(index, f, input));
        }
    }

    public class MatchEntry : Object {
        public string path;
        public LoudnessResult before;
        public LoudnessResult? after = null;
        public double gain = 0;
        public string? output = null;
        public string? error = null;
    }

    namespace LoudnessMatch {
        public Gee.List<MatchEntry> analyze(Gee.List<string> files) {
            var list = new Gee.ArrayList<MatchEntry>();
            foreach (var f in files) {
                var e = new MatchEntry();
                e.path = f;
                try {
                    var media = Decoder.decode_sync(f);
                    var doc = Document.from_source(media.source, f);
                    e.before = Loudness.measure_renderable(doc);
                } catch (Error err) {
                    e.error = err.message;
                    e.before = new LoudnessResult();
                }
                list.add(e);
            }
            return list;
        }

        public void apply(Gee.List<MatchEntry> entries, double target, double ceiling, string output_dir, ExportFormat format) {
            foreach (var e in entries) {
                if (e.error != null) continue;
                try {
                    var job = new BatchJob();
                    job.normalize = true;
                    job.target_lufs = target;
                    job.ceiling = ceiling;
                    job.output_dir = output_dir;
                    job.suffix = output_dir == "" ? "-matched" : "";
                    job.options.format = format;
                    job.options.bits = 24;
                    string out_path = job.output_for(e.path);
                    job.files.add(e.path);
                    string? err = null;
                    job.file_done.connect((i, o, er) => err = er);
                    job.run_sync();
                    if (err != null) {
                        e.error = err;
                        continue;
                    }
                    e.output = out_path;
                    var m = Decoder.decode_sync(out_path);
                    e.after = Loudness.measure_renderable(Document.from_source(m.source, out_path));
                    e.gain = target - e.before.integrated;
                } catch (Error er) {
                    e.error = er.message;
                }
            }
        }

        public void match_clips(Session s, Gee.List<Clip> clips, double target) {
            foreach (var c in clips) {
                var buf = new float[c.length * c.source.channels];
                c.source.read(c.source_offset, c.length, buf);
                var r = Loudness.measure(buf, c.length, c.source.channels, c.source.rate);
                if (r.integrated.is_finite()) c.gain_db = target - r.integrated;
            }
            s.checkpoint(_("Match Clip Loudness"));
            s.changed();
        }
    }

    public enum SoundRole {
        DIALOGUE,
        MUSIC,
        EFFECTS,
        AMBIENCE;

        public string id() {
            switch (this) {
            case MUSIC: return "music";
            case EFFECTS: return "sfx";
            case AMBIENCE: return "ambience";
            default: return "dialogue";
            }
        }

        public string label() {
            switch (this) {
            case MUSIC: return _("Music");
            case EFFECTS: return _("Sound Effects");
            case AMBIENCE: return _("Ambience");
            default: return _("Dialogue");
            }
        }

        public static SoundRole from_id(string id) {
            switch (id) {
            case "music": return MUSIC;
            case "sfx": return EFFECTS;
            case "ambience": return AMBIENCE;
            default: return DIALOGUE;
            }
        }
    }

    namespace EssentialSound {
        public float[] classify_source(PcmSource s, int64 offset, int64 length) {
            int64 n = int64.min(length, (int64) s.rate * 120);
            var mono = new float[n];
            s.read(offset, n, mono, 0, 1);
            var scores = new float[4];
            WaveDsp.classify(mono, n, s.rate, scores);
            return scores;
        }

        public SoundRole best(float[] scores) {
            int best = 0;
            for (int i = 1; i < 4; i++) {
                if (scores[i] > scores[best]) best = i;
            }
            return (SoundRole) best;
        }

        private Effect? find(EffectRack rack, string kind) {
            foreach (var e in rack.effects) {
                if (e.kind == kind) return e;
            }
            return null;
        }

        private Effect ensure(EffectRack rack, string kind) {
            var e = find(rack, kind);
            if (e == null) {
                e = EffectRegistry.create(kind);
                rack.add(e);
            }
            return e;
        }

        private void drop(EffectRack rack, string kind) {
            var e = find(rack, kind);
            if (e != null) rack.remove(e);
        }

        public void set_noise(EffectRack rack, double amount) {
            if (amount <= 0) {
                drop(rack, "adaptive_denoise");
                return;
            }
            var e = ensure(rack, "adaptive_denoise");
            e.set_value("reduction", 4 + amount * 20);
        }

        public void set_rumble(EffectRack rack, double amount) {
            var eq = (EqEffect) ensure(rack, "eq");
            eq.set_value("b0_on", amount > 0 ? 1 : 0);
            eq.set_value("b0_type", 3);
            eq.set_value("b0_freq", 40 + amount * 80);
        }

        public void set_clarity(EffectRack rack, double amount) {
            var eq = (EqEffect) ensure(rack, "eq");
            eq.set_value("b1_on", amount > 0 ? 1 : 0);
            eq.set_value("b1_type", 0);
            eq.set_value("b1_freq", 300);
            eq.set_value("b1_gain", -3 * amount);
            eq.set_value("b1_q", 1);
            eq.set_value("b4_on", amount > 0 ? 1 : 0);
            eq.set_value("b4_type", 0);
            eq.set_value("b4_freq", 3500);
            eq.set_value("b4_gain", 4 * amount);
            eq.set_value("b4_q", 0.8);
            if (amount > 0) {
                var ds = ensure(rack, "deesser");
                ds.set_value("threshold", -26 - 6 * amount);
            } else {
                drop(rack, "deesser");
            }
        }

        public void set_reverb(EffectRack rack, double amount) {
            if (amount <= 0) {
                drop(rack, "reverb");
                return;
            }
            var r = ensure(rack, "reverb");
            r.set_value("wet", 0.05 + amount * 0.4);
            r.set_value("room", 0.3 + amount * 0.5);
        }

        public void set_width(EffectRack rack, double width) {
            var u = ensure(rack, "utility");
            u.set_value("width", width);
        }

        public void set_leveler(EffectRack rack, bool on) {
            if (!on) {
                drop(rack, "compressor");
                return;
            }
            var c = ensure(rack, "compressor");
            c.set_value("threshold", -24);
            c.set_value("ratio", 3);
            c.set_value("makeup", 4);
        }
    }

    namespace Ducking {
        public Gee.List<int64?> speech_spans(Session s, int frame_ms) {
            var spans = new Gee.ArrayList<int64?>();
            int64 len = s.length;
            int hop = s.rate * frame_ms / 1000;
            int count = (int) (len / hop) + 1;
            var active = new bool[count];
            foreach (var t in s.tracks) {
                if (t.kind != TrackKind.AUDIO || t.duck || (t.role != "dialogue" && t.role != "voice")) continue;
                foreach (var c in t.clips) {
                    if (c.muted) continue;
                    int64 n = c.length;
                    var mono = new float[n];
                    c.source.read(c.source_offset, n, mono, 0, 1);
                    int frames = (int) (n / hop) + 1;
                    var flags = new uint8[frames];
                    int got = WaveDsp.vad(mono, n, c.source.rate, frame_ms, flags, frames);
                    for (int i = 0; i < got; i++) {
                        if (flags[i] == 0) continue;
                        int idx = (int) ((c.position + (int64) i * hop) / hop);
                        if (idx >= 0 && idx < count) active[idx] = true;
                    }
                }
            }
            int i2 = 0;
            while (i2 < count) {
                if (!active[i2]) {
                    i2++;
                    continue;
                }
                int j = i2;
                while (j < count && active[j]) j++;
                spans.add((int64) i2 * hop);
                spans.add((int64) j * hop);
                i2 = j;
            }
            return spans;
        }

        public int apply(Session s, Track music, double duck_db, double fade_ms, double hold_ms) {
            var spans = speech_spans(s, 20);
            var merged = new Gee.ArrayList<int64?>();
            int64 hold = (int64) (hold_ms * s.rate / 1000);
            for (int i = 0; i + 1 < spans.size; i += 2) {
                if (merged.size > 0 && spans[i] - merged[merged.size - 1] < hold) {
                    merged[merged.size - 1] = spans[i + 1];
                } else {
                    merged.add(spans[i]);
                    merged.add(spans[i + 1]);
                }
            }
            var lane = music.lane("volume");
            lane.points.clear();
            double base_db = music.volume_db;
            int64 fade = (int64) (fade_ms * s.rate / 1000);
            lane.add(0, base_db);
            for (int i = 0; i + 1 < merged.size; i += 2) {
                int64 a = int64.max(0, merged[i] - fade);
                int64 b = merged[i + 1] + fade;
                lane.add(a, base_db, 2);
                lane.add(merged[i], base_db + duck_db, 0);
                lane.add(merged[i + 1], base_db + duck_db, 2);
                lane.add(b, base_db, 0);
            }
            music.duck = true;
            music.duck_db = duck_db;
            music.automation = AutomationMode.READ;
            s.checkpoint(_("Auto Ducking"));
            s.changed();
            return merged.size / 2;
        }
    }

    namespace Templates {
        public Session podcast(int rate, double target) {
            var s = new Session(rate, 2);
            s.title = _("Podcast");
            s.template = "podcast";
            s.loudness_target = target;
            string[] voices = { _("Host"), _("Guest") };
            foreach (string v in voices) {
                var t = s.add_track(v, TrackKind.AUDIO, 1);
                t.role = "dialogue";
                t.armed = v == voices[0];
                t.rack.load_json(Presets.factory_rack("voice"));
                var nr = EffectRegistry.create("adaptive_denoise");
                t.rack.add(nr, 0);
            }
            var music = s.add_track(_("Music"), TrackKind.AUDIO, 2);
            music.role = "music";
            music.duck = true;
            music.volume_db = -6;
            music.rack.load_json(Presets.factory_rack("music-bed"));
            var intro = s.add_track(_("Intro and Outro"), TrackKind.AUDIO, 2);
            intro.role = "music";
            var fx = s.add_track(_("Reverb Bus"), TrackKind.BUS, 2);
            fx.rack.add(EffectRegistry.create("reverb"));
            fx.volume_db = -8;
            s.master.rack.load_json(Presets.factory_rack("podcast-master"));
            s.markers.add(new Marker(_("Intro"), 0, 0, "chapter"));
            s.checkpoint(_("New Podcast"));
            s.modified = false;
            return s;
        }

        public Session empty(int rate, int channels) {
            var s = new Session(rate, channels);
            s.title = _("Untitled Session");
            for (int i = 0; i < 4; i++) s.add_track(_("Track %d").printf(i + 1), TrackKind.AUDIO, channels == 6 ? 1 : 2);
            s.checkpoint(_("New Session"));
            s.modified = false;
            return s;
        }

        public Session surround(int rate) {
            var s = new Session(rate, 6);
            s.title = _("5.1 Session");
            s.template = "surround";
            string[] names = { _("Dialogue"), _("Music"), _("Effects"), _("Ambience") };
            foreach (string n in names) {
                var t = s.add_track(n, TrackKind.AUDIO, n == names[0] ? 1 : 2);
                if (n == names[0]) t.azimuth = 0;
                if (n == names[3]) t.spread = 0.8;
            }
            var bus = s.add_track(_("5.1 Bus"), TrackKind.BUS, 6);
            bus.name = _("5.1 Bus");
            s.checkpoint(_("New 5.1 Session"));
            s.modified = false;
            return s;
        }
    }
}
