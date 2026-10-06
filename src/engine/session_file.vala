namespace Singularity.Apps.Wave {

    public class MediaPool : Object {
        public Gee.HashMap<string, PcmSource> by_id = new Gee.HashMap<string, PcmSource>();
        public Gee.HashMap<string, string> paths = new Gee.HashMap<string, string>();

        public string id_for(PcmSource s, string path) {
            foreach (var e in by_id.entries) {
                if (e.value == s) return e.key;
            }
            string id = "m%d".printf(by_id.size + 1);
            while (by_id.has_key(id)) id += "x";
            by_id[id] = s;
            paths[id] = path;
            return id;
        }
    }

    namespace SessionFile {
        private static Gee.HashMap<Session, MediaPool>? pools = null;

        public MediaPool pool(Session s) {
            if (pools == null) pools = new Gee.HashMap<Session, MediaPool>();
            var p = pools[s];
            if (p == null) {
                p = new MediaPool();
                pools[s] = p;
            }
            return p;
        }

        private Json.Object rack_json(EffectRack r) {
            return r.to_json();
        }

        public Json.Object to_json(Session s, string? base_dir = null) {
            var pool = pool(s);
            var o = new Json.Object();
            o.set_string_member("format", "singularity-wave-session");
            o.set_int_member("version", 1);
            o.set_string_member("title", s.title);
            o.set_int_member("rate", s.rate);
            o.set_int_member("channels", s.channels);
            o.set_double_member("tempo", s.tempo);
            o.set_int_member("beats_per_bar", s.beats_per_bar);
            o.set_boolean_member("metronome", s.metronome);
            o.set_boolean_member("snap", s.snap_to_grid);
            o.set_string_member("template", s.template);
            o.set_double_member("loudness_target", s.loudness_target);
            o.set_object_member("metadata", s.metadata.to_json());
            if (s.transcript_json != "") o.set_string_member("transcript", s.transcript_json);
            var markers = new Json.Array();
            foreach (var m in s.markers) markers.add_object_element(m.to_json());
            o.set_array_member("markers", markers);
            var tracks = new Json.Array();
            foreach (var t in s.tracks) tracks.add_object_element(track_json(t, pool));
            o.set_array_member("tracks", tracks);
            o.set_object_member("master", track_json(s.master, pool));
            var media = new Json.Array();
            foreach (var e in pool.by_id.entries) {
                var mo = new Json.Object();
                mo.set_string_member("id", e.key);
                string p = pool.paths[e.key] ?? "";
                mo.set_string_member("path", p);
                if (base_dir != null && p != "") {
                    string? rel = relative(base_dir, p);
                    if (rel != null) mo.set_string_member("relative", rel);
                }
                mo.set_int_member("rate", e.value.rate);
                mo.set_int_member("channels", e.value.channels);
                mo.set_int_member("frames", e.value.frames);
                media.add_object_element(mo);
            }
            o.set_array_member("media", media);
            return o;
        }

        public string? relative(string base_dir, string path) {
            var b = File.new_for_path(base_dir);
            var f = File.new_for_path(path);
            string? rel = b.get_relative_path(f);
            if (rel != null) return rel;
            var parent = b.get_parent();
            if (parent != null) {
                string? up = parent.get_relative_path(f);
                if (up != null) return "../" + up;
            }
            return null;
        }

        private Json.Object track_json(Track t, MediaPool pool) {
            var o = new Json.Object();
            o.set_string_member("id", t.id);
            o.set_string_member("name", t.name);
            o.set_string_member("kind", t.kind.id());
            o.set_int_member("channels", t.channels);
            o.set_double_member("volume", t.volume_db);
            o.set_double_member("pan", t.pan);
            o.set_double_member("azimuth", t.azimuth);
            o.set_double_member("spread", t.spread);
            o.set_double_member("lfe", t.lfe);
            o.set_boolean_member("mute", t.mute);
            o.set_boolean_member("solo", t.solo);
            o.set_boolean_member("armed", t.armed);
            o.set_boolean_member("monitor", t.monitor);
            o.set_string_member("input", t.input);
            o.set_string_member("output", t.output);
            o.set_string_member("role", t.role);
            o.set_boolean_member("duck", t.duck);
            o.set_double_member("duck_db", t.duck_db);
            o.set_string_member("color", t.color);
            o.set_string_member("automation", t.automation.id());
            if (t.video_segments.size > 0) {
                var va = new Json.Array();
                foreach (var v in t.video_segments) {
                    var vo = new Json.Object();
                    vo.set_string_member("uri", v.uri);
                    vo.set_int_member("position", v.position);
                    vo.set_int_member("start_ms", v.start_ms);
                    vo.set_int_member("end_ms", v.end_ms);
                    va.add_object_element(vo);
                }
                o.set_array_member("video", va);
            }
            o.set_object_member("rack", rack_json(t.rack));
            var sends = new Json.Array();
            foreach (var s in t.sends) {
                var so = new Json.Object();
                so.set_string_member("bus", s.bus);
                so.set_double_member("level", s.level_db);
                so.set_boolean_member("pre", s.pre_fader);
                sends.add_object_element(so);
            }
            o.set_array_member("sends", sends);
            var lanes = new Json.Array();
            foreach (var l in t.lanes) lanes.add_object_element(l.to_json());
            o.set_array_member("lanes", lanes);
            var clips = new Json.Array();
            foreach (var c in t.clips) {
                var co = new Json.Object();
                co.set_string_member("id", c.id);
                co.set_string_member("name", c.name);
                co.set_string_member("media", pool.id_for(c.source, c.path));
                co.set_int_member("offset", c.source_offset);
                co.set_int_member("length", c.length);
                co.set_int_member("position", c.position);
                co.set_double_member("gain", c.gain_db);
                co.set_int_member("fade_in", c.fade_in);
                co.set_int_member("fade_out", c.fade_out);
                co.set_int_member("fade_in_curve", c.fade_in_curve);
                co.set_int_member("fade_out_curve", c.fade_out_curve);
                co.set_double_member("stretch", c.stretch);
                co.set_double_member("pitch", c.pitch);
                co.set_boolean_member("muted", c.muted);
                co.set_string_member("role", c.role);
                co.set_object_member("rack", rack_json(c.rack));
                var takes = new Json.Array();
                foreach (var tk in c.takes) {
                    var to = new Json.Object();
                    to.set_string_member("media", pool.id_for(tk.source, tk.path));
                    to.set_int_member("offset", tk.offset);
                    to.set_string_member("name", tk.name);
                    takes.add_object_element(to);
                }
                co.set_array_member("takes", takes);
                co.set_int_member("active_take", c.active_take);
                clips.add_object_element(co);
            }
            o.set_array_member("clips", clips);
            return o;
        }

        public string to_string(Session s) {
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(to_json(s));
            return Json.to_string(n, false);
        }

        public void restore_into(Session s, string text) {
            try {
                var p = new Json.Parser();
                p.load_from_data(text);
                apply(s, p.get_root().get_object(), pool(s));
            } catch (Error e) {
                warning("Wave: history: %s", e.message);
            }
        }

        private void apply(Session s, Json.Object o, MediaPool pool) {
            s.title = o.get_string_member_with_default("title", s.title);
            s.tempo = o.get_double_member_with_default("tempo", 120);
            s.beats_per_bar = (int) o.get_int_member_with_default("beats_per_bar", 4);
            s.metronome = o.get_boolean_member_with_default("metronome", false);
            s.snap_to_grid = o.get_boolean_member_with_default("snap", false);
            s.template = o.get_string_member_with_default("template", "");
            s.loudness_target = o.get_double_member_with_default("loudness_target", -16);
            s.metadata = Metadata.from_json(o.has_member("metadata") ? o.get_object_member("metadata") : null);
            s.transcript_json = o.get_string_member_with_default("transcript", "");
            s.markers.clear();
            if (o.has_member("markers")) {
                foreach (var n in o.get_array_member("markers").get_elements()) s.markers.add(Marker.from_json(n.get_object()));
            }
            s.tracks.clear();
            foreach (var n in o.get_array_member("tracks").get_elements()) {
                var t = load_track(s, n.get_object(), pool);
                if (t != null) s.tracks.add(t);
            }
            if (o.has_member("master")) {
                var mo = o.get_object_member("master");
                s.master.volume_db = mo.get_double_member_with_default("volume", 0);
                s.master.mute = mo.get_boolean_member_with_default("mute", false);
                s.master.rack.load_json(mo.get_object_member("rack"));
                s.master.lanes.clear();
                if (mo.has_member("lanes")) {
                    foreach (var n in mo.get_array_member("lanes").get_elements()) s.master.lanes.add(AutomationLane.from_json(n.get_object()));
                }
            }
        }

        private Track? load_track(Session s, Json.Object o, MediaPool pool) {
            var kind = TrackKind.from_id(o.get_string_member_with_default("kind", "audio"));
            var t = new Track(o.get_string_member_with_default("name", ""), kind, (int) o.get_int_member_with_default("channels", 2), s.rate);
            t.id = o.get_string_member_with_default("id", t.id);
            t.volume_db = o.get_double_member_with_default("volume", 0);
            t.pan = o.get_double_member_with_default("pan", 0);
            t.azimuth = o.get_double_member_with_default("azimuth", 0);
            t.spread = o.get_double_member_with_default("spread", 0);
            t.lfe = o.get_double_member_with_default("lfe", 0);
            t.mute = o.get_boolean_member_with_default("mute", false);
            t.solo = o.get_boolean_member_with_default("solo", false);
            t.armed = o.get_boolean_member_with_default("armed", false);
            t.monitor = o.get_boolean_member_with_default("monitor", false);
            t.input = o.get_string_member_with_default("input", "");
            t.output = o.get_string_member_with_default("output", "master");
            t.role = o.get_string_member_with_default("role", "");
            t.duck = o.get_boolean_member_with_default("duck", false);
            t.duck_db = o.get_double_member_with_default("duck_db", -15);
            t.color = o.get_string_member_with_default("color", t.color);
            t.automation = AutomationMode.from_id(o.get_string_member_with_default("automation", "read"));
            if (o.has_member("video")) {
                foreach (var vn in o.get_array_member("video").get_elements()) {
                    var vo = vn.get_object();
                    t.video_segments.add(new VideoSegment(vo.get_string_member("uri"), vo.get_int_member_with_default("position", 0),
                        vo.get_int_member_with_default("start_ms", 0), vo.get_int_member_with_default("end_ms", 0)));
                }
            }
            t.rack.load_json(o.has_member("rack") ? o.get_object_member("rack") : null);
            if (o.has_member("sends")) {
                foreach (var n in o.get_array_member("sends").get_elements()) {
                    var so = n.get_object();
                    var send = new Send(so.get_string_member("bus"));
                    send.level_db = so.get_double_member_with_default("level", -6);
                    send.pre_fader = so.get_boolean_member_with_default("pre", false);
                    t.sends.add(send);
                }
            }
            if (o.has_member("lanes")) {
                foreach (var n in o.get_array_member("lanes").get_elements()) t.lanes.add(AutomationLane.from_json(n.get_object()));
            }
            if (o.has_member("clips")) {
                foreach (var n in o.get_array_member("clips").get_elements()) {
                    var co = n.get_object();
                    string mid = co.get_string_member("media");
                    var src = pool.by_id[mid];
                    if (src == null) continue;
                    var c = new Clip(src, pool.paths[mid] ?? "", co.get_int_member_with_default("position", 0));
                    c.id = co.get_string_member_with_default("id", c.id);
                    c.name = co.get_string_member_with_default("name", c.name);
                    c.source_offset = co.get_int_member_with_default("offset", 0);
                    c.length = co.get_int_member_with_default("length", src.frames);
                    c.gain_db = co.get_double_member_with_default("gain", 0);
                    c.fade_in = co.get_int_member_with_default("fade_in", 0);
                    c.fade_out = co.get_int_member_with_default("fade_out", 0);
                    c.fade_in_curve = (int) co.get_int_member_with_default("fade_in_curve", 2);
                    c.fade_out_curve = (int) co.get_int_member_with_default("fade_out_curve", 2);
                    c.stretch = co.get_double_member_with_default("stretch", 1);
                    c.pitch = co.get_double_member_with_default("pitch", 0);
                    c.muted = co.get_boolean_member_with_default("muted", false);
                    c.role = co.get_string_member_with_default("role", "");
                    c.rack.configure(s.rate, src.channels);
                    c.rack.load_json(co.has_member("rack") ? co.get_object_member("rack") : null);
                    if (co.has_member("takes")) {
                        foreach (var tn in co.get_array_member("takes").get_elements()) {
                            var to = tn.get_object();
                            var ts = pool.by_id[to.get_string_member("media")];
                            if (ts != null) c.takes.add(new Take(ts, pool.paths[to.get_string_member("media")] ?? "", to.get_int_member_with_default("offset", 0), to.get_string_member_with_default("name", "")));
                        }
                    }
                    c.active_take = (int) co.get_int_member_with_default("active_take", -1);
                    t.clips.add(c);
                }
            }
            t.sort_clips();
            return t;
        }

        public string media_dir(string session_path) {
            string base_name = Path.get_basename(session_path);
            if (base_name.has_suffix(".wave")) base_name = base_name.substring(0, base_name.length - 5);
            return Path.build_filename(Path.get_dirname(session_path), base_name + " Media");
        }

        public void save(Session s, string path) throws Error {
            var pool = pool(s);
            foreach (var t in s.tracks) {
                foreach (var c in t.clips) {
                    pool.id_for(c.source, c.path);
                    foreach (var tk in c.takes) pool.id_for(tk.source, tk.path);
                }
            }
            string mdir = media_dir(path);
            foreach (var e in pool.by_id.entries) {
                string p = pool.paths[e.key] ?? "";
                if (p != "" && FileUtils.test(p, FileTest.EXISTS)) continue;
                DirUtils.create_with_parents(mdir, 0755);
                string target = Path.build_filename(mdir, "%s.wav".printf(e.key));
                var w = new WavWriter();
                w.is_float = true;
                w.open(target, e.value.rate, e.value.channels);
                int block = 65536;
                var buf = new float[block * e.value.channels];
                for (int64 pos = 0; pos < e.value.frames; pos += block) {
                    int n = (int) int64.min(block, e.value.frames - pos);
                    e.value.read(pos, n, buf);
                    w.write(buf, n);
                }
                w.close();
                pool.paths[e.key] = target;
                foreach (var t in s.tracks) {
                    foreach (var c in t.clips) {
                        if (c.source == e.value) c.path = target;
                        foreach (var tk in c.takes) {
                            if (tk.source == e.value) tk.path = target;
                        }
                    }
                }
            }
            var o = to_json(s, Path.get_dirname(path));
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(o);
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.root = n;
            var zip = new ZipWriter();
            zip.add_text("mimetype", "application/x-wave-session", false);
            zip.add_text("session.json", gen.to_data(null));
            zip.add_text("README.txt", "Wave session. session.json lists tracks, clips, effects and automation; media entries point to audio files by absolute and relative path. Sample positions are in frames at the session rate.\n");
            FileUtils.set_data(path, zip.finish());
            s.path = path;
            s.modified = false;
        }

        public Session load(string path, owned ProgressFunc? report = null) throws Error {
            uint8[] data;
            FileUtils.get_data(path, out data);
            var zip = new ZipReader(data);
            string? text = zip.read_text("session.json");
            if (text == null) throw new IOError.INVALID_DATA(_("This is not a Wave session"));
            var p = new Json.Parser();
            p.load_from_data(text);
            var o = p.get_root().get_object();
            return from_json(o, Path.get_dirname(path), path, (owned) report);
        }

        public Session from_json(Json.Object o, string base_dir, string path, owned ProgressFunc? report = null) throws Error {
            var s = new Session((int) o.get_int_member_with_default("rate", 48000), (int) o.get_int_member_with_default("channels", 2));
            s.path = path;
            var pool = pool(s);
            var media = o.get_array_member("media");
            uint i = 0;
            foreach (var n in media.get_elements()) {
                var mo = n.get_object();
                string mp = mo.get_string_member_with_default("path", "");
                if (!FileUtils.test(mp, FileTest.EXISTS) && mo.has_member("relative")) {
                    string rel = Path.build_filename(base_dir, mo.get_string_member("relative"));
                    if (FileUtils.test(rel, FileTest.EXISTS)) mp = rel;
                }
                if (!FileUtils.test(mp, FileTest.EXISTS)) {
                    string guess = Path.build_filename(base_dir, Path.get_basename(mp));
                    if (FileUtils.test(guess, FileTest.EXISTS)) mp = guess;
                }
                if (!FileUtils.test(mp, FileTest.EXISTS)) {
                    warning("Wave: missing media %s", mp);
                    continue;
                }
                var dec = Decoder.decode_sync(mp);
                pool.by_id[mo.get_string_member("id")] = dec.source;
                pool.paths[mo.get_string_member("id")] = mp;
                i++;
                if (report != null) report((double) i / media.get_length());
            }
            apply(s, o, pool);
            s.checkpoint(_("Open"));
            s.modified = false;
            return s;
        }
    }
}
