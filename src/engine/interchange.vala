namespace Singularity.Apps.Wave {

    namespace Interchange {
        public string cue_time(int64 frame, int rate) {
            int64 total = frame * 75 / rate;
            return "%02lld:%02lld:%02lld".printf(total / (75 * 60), (total / 75) % 60, total % 75);
        }

        private string quote(string s) {
            return s.replace("\"", "'");
        }

        public void write_cue(string audio_path, string audio_name, ExportFormat format, Metadata meta, Gee.List<Marker> markers, int rate) throws Error {
            string base_path = audio_path;
            int dot = base_path.last_index_of(".");
            if (dot > 0) base_path = base_path.substring(0, dot);
            var sb = new StringBuilder();
            if (meta.artist != "") sb.append("PERFORMER \"%s\"\n".printf(quote(meta.artist)));
            if (meta.title != "") sb.append("TITLE \"%s\"\n".printf(quote(meta.title)));
            string kind = format == ExportFormat.MP3 ? "MP3" : format == ExportFormat.AIFF ? "AIFF" : "WAVE";
            sb.append("FILE \"%s\" %s\n".printf(quote(audio_name), kind));
            var list = new Gee.ArrayList<Marker>();
            list.add_all(markers);
            if (list.size == 0 || list[0].start > 0) list.insert(0, new Marker(meta.title != "" ? meta.title : _("Track 1"), 0));
            int n = 1;
            foreach (var m in list) {
                sb.append("  TRACK %02d AUDIO\n".printf(n++));
                sb.append("    TITLE \"%s\"\n".printf(quote(m.name)));
                if (meta.artist != "") sb.append("    PERFORMER \"%s\"\n".printf(quote(meta.artist)));
                sb.append("    INDEX 01 %s\n".printf(cue_time(m.start, rate)));
            }
            FileUtils.set_contents(base_path + ".cue", sb.str);
        }

        public Gee.List<Marker> read_cue(string path, int rate, out string? audio_file) {
            var list = new Gee.ArrayList<Marker>();
            audio_file = null;
            string text;
            try {
                FileUtils.get_contents(path, out text);
            } catch (Error e) {
                return list;
            }
            string title = "";
            foreach (string raw in text.split("\n")) {
                string line = raw.strip();
                if (line.has_prefix("FILE ")) {
                    int a = line.index_of("\"");
                    int b = line.last_index_of("\"");
                    if (a >= 0 && b > a) audio_file = Path.build_filename(Path.get_dirname(path), line.substring(a + 1, b - a - 1));
                } else if (line.has_prefix("TRACK ")) {
                    title = "";
                } else if (line.has_prefix("TITLE ")) {
                    title = line.substring(6).strip().replace("\"", "");
                } else if (line.has_prefix("INDEX 01 ")) {
                    string[] t = line.substring(9).strip().split(":");
                    if (t.length == 3) {
                        int64 frames75 = int64.parse(t[0]) * 60 * 75 + int64.parse(t[1]) * 75 + int64.parse(t[2]);
                        list.add(new Marker(title != "" ? title : _("Track %d").printf(list.size + 1), frames75 * rate / 75, 0, "chapter"));
                    }
                }
            }
            return list;
        }

        public void write_chapters_json(string path, Gee.List<Marker> markers, int rate) throws Error {
            var o = new Json.Object();
            o.set_string_member("version", "1.2.0");
            var a = new Json.Array();
            foreach (var m in markers) {
                var c = new Json.Object();
                c.set_double_member("startTime", Math.round((double) m.start / rate * 1000) / 1000);
                if (m.length > 0) c.set_double_member("endTime", Math.round((double) m.end / rate * 1000) / 1000);
                c.set_string_member("title", m.name);
                a.add_object_element(c);
            }
            o.set_array_member("chapters", a);
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(o);
            var g = new Json.Generator();
            g.pretty = true;
            g.root = n;
            g.to_file(path);
        }

        public Gee.List<Marker> read_chapters_json(string path, int rate) {
            var list = new Gee.ArrayList<Marker>();
            try {
                var p = new Json.Parser();
                p.load_from_file(path);
                foreach (var n in p.get_root().get_object().get_array_member("chapters").get_elements()) {
                    var c = n.get_object();
                    int64 start = (int64) Math.round(c.get_double_member_with_default("startTime", 0) * rate);
                    int64 end = c.has_member("endTime") ? (int64) Math.round(c.get_double_member("endTime") * rate) : start;
                    list.add(new Marker(c.get_string_member_with_default("title", ""), start, end - start, "chapter"));
                }
            } catch (Error e) {
            }
            return list;
        }

        private string? attr(Xml.Node* n, string name) {
            return n->get_prop(name);
        }

        private int64 attr_int(Xml.Node* n, string name, int64 fallback = 0) {
            string? v = n->get_prop(name);
            return v != null ? (int64) double.parse(v) : fallback;
        }

        private Xml.Node* child(Xml.Node* n, string name) {
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE && c->name == name) return c;
            }
            return null;
        }

        public Session import_sesx(string path) throws Error {
            Xml.Doc* doc = Xml.Parser.read_file(path, null, Xml.ParserOption.NONET);
            if (doc == null) throw new IOError.INVALID_DATA(_("This Audition session cannot be read"));
            Xml.Node* root = doc->get_root_element();
            Xml.Node* sess = child(root, "session");
            if (sess == null) {
                delete doc;
                throw new IOError.INVALID_DATA(_("This Audition session cannot be read"));
            }
            int rate = (int) attr_int(sess, "sampleRate", 48000);
            var s = new Session(rate, 2);
            s.title = Path.get_basename(path).replace(".sesx", "");
            var files = new Gee.HashMap<string, string>();
            Xml.Node* fnode = child(root, "files");
            if (fnode != null) {
                for (Xml.Node* f = fnode->children; f != null; f = f->next) {
                    if (f->type != Xml.ElementType.ELEMENT_NODE || f->name != "file") continue;
                    string? abs = attr(f, "absolutePath");
                    string? rel = attr(f, "relativePath");
                    string? chosen = null;
                    if (rel != null) {
                        string r = Path.build_filename(Path.get_dirname(path), rel);
                        if (FileUtils.test(r, FileTest.EXISTS)) chosen = r;
                    }
                    if (chosen == null && abs != null && FileUtils.test(abs, FileTest.EXISTS)) chosen = abs;
                    if (chosen == null && abs != null) {
                        string g = Path.build_filename(Path.get_dirname(path), Path.get_basename(abs.replace("\\", "/")));
                        if (FileUtils.test(g, FileTest.EXISTS)) chosen = g;
                    }
                    if (chosen != null) files[attr(f, "id") ?? ""] = chosen;
                }
            }
            var pool = SessionFile.pool(s);
            var decoded = new Gee.HashMap<string, PcmSource>();
            Xml.Node* tracks = child(sess, "tracks");
            if (tracks != null) {
                for (Xml.Node* t = tracks->children; t != null; t = t->next) {
                    if (t->type != Xml.ElementType.ELEMENT_NODE) continue;
                    if (t->name != "audioTrack" && t->name != "busTrack") continue;
                    string name = _("Track %d").printf(s.tracks.size + 1);
                    Xml.Node* tp = child(t, "trackParameters");
                    if (tp != null) {
                        Xml.Node* nm = child(tp, "name");
                        if (nm != null) name = nm->get_content();
                    }
                    var track = s.add_track(name, t->name == "busTrack" ? TrackKind.BUS : TrackKind.AUDIO);
                    Xml.Node* ap = child(t, "trackAudioParameters");
                    if (ap != null) {
                        string? ch = attr(ap, "audioChannelType");
                        if (ch == "mono") track.channels = 1;
                        else if (ch == "5.1") track.channels = 6;
                        for (Xml.Node* p = ap->children; p != null; p = p->next) {
                            if (p->type != Xml.ElementType.ELEMENT_NODE || p->name != "parameter") continue;
                            string? pname = attr(p, "name");
                            string? val = attr(p, "parameterValue");
                            if (pname == null || val == null) continue;
                            if (pname == "volume") track.volume_db = 20 * Math.log10(double.max(1e-6, double.parse(val)));
                            if (pname == "pan") track.pan = (double.parse(val) / 100).clamp(-1, 1);
                            if (pname == "mute") track.mute = val == "1" || val == "true";
                            if (pname == "solo") track.solo = val == "1" || val == "true";
                        }
                    }
                    for (Xml.Node* c = t->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE || c->name != "audioClip") continue;
                        string fid = attr(c, "fileID") ?? "";
                        string? fp = files[fid];
                        if (fp == null) continue;
                        PcmSource? src = decoded[fp];
                        if (src == null) {
                            src = Decoder.decode_sync(fp).source;
                            decoded[fp] = src;
                        }
                        int64 start = attr_int(c, "startPoint");
                        int64 end = attr_int(c, "endPoint", start + src.frames);
                        int64 in_point = attr_int(c, "sourceInPoint");
                        var clip = s.add_clip(track, src, fp, start);
                        pool.id_for(src, fp);
                        clip.name = attr(c, "name") ?? clip.name;
                        clip.source_offset = in_point;
                        clip.length = int64.max(1, end - start);
                        Xml.Node* fi = child(c, "fadeIn");
                        if (fi != null) clip.fade_in = attr_int(fi, "endPoint") - attr_int(fi, "startPoint");
                        Xml.Node* fo = child(c, "fadeOut");
                        if (fo != null) clip.fade_out = attr_int(fo, "endPoint") - attr_int(fo, "startPoint");
                        string? gain = attr(c, "volume");
                        if (gain != null) clip.gain_db = 20 * Math.log10(double.max(1e-6, double.parse(gain)));
                    }
                }
            }
            Xml.Node* markers = child(sess, "markers");
            if (markers == null) markers = child(root, "markers");
            if (markers != null) {
                for (Xml.Node* m = markers->children; m != null; m = m->next) {
                    if (m->type != Xml.ElementType.ELEMENT_NODE || m->name != "marker") continue;
                    s.markers.add(new Marker(attr(m, "name") ?? "", attr_int(m, "startSample", attr_int(m, "start")), attr_int(m, "durationSamples", attr_int(m, "duration"))));
                }
            }
            delete doc;
            s.checkpoint(_("Import"));
            return s;
        }

        private Json.Object rational(double value, double rate) {
            var o = new Json.Object();
            o.set_string_member("OTIO_SCHEMA", "RationalTime.1");
            o.set_double_member("rate", rate);
            o.set_double_member("value", value);
            return o;
        }

        private Json.Object range(double start, double duration, double rate) {
            var o = new Json.Object();
            o.set_string_member("OTIO_SCHEMA", "TimeRange.1");
            o.set_object_member("start_time", rational(start, rate));
            o.set_object_member("duration", rational(duration, rate));
            return o;
        }

        public string export_otio(Session s) {
            var tl = new Json.Object();
            tl.set_string_member("OTIO_SCHEMA", "Timeline.1");
            tl.set_string_member("name", s.title != "" ? s.title : _("Wave Session"));
            tl.set_object_member("metadata", new Json.Object());
            var stack = new Json.Object();
            stack.set_string_member("OTIO_SCHEMA", "Stack.1");
            stack.set_string_member("name", "tracks");
            var children = new Json.Array();
            foreach (var t in s.tracks) {
                if (t.kind == TrackKind.BUS) continue;
                var tr = new Json.Object();
                tr.set_string_member("OTIO_SCHEMA", "Track.1");
                tr.set_string_member("name", t.name);
                tr.set_string_member("kind", t.kind == TrackKind.VIDEO ? "Video" : "Audio");
                var items = new Json.Array();
                int64 cursor = 0;
                if (t.kind == TrackKind.VIDEO) {
                    foreach (var v in t.video_segments) {
                        double vr = 1000;
                        if (v.position > cursor) {
                            var gap = new Json.Object();
                            gap.set_string_member("OTIO_SCHEMA", "Gap.1");
                            gap.set_object_member("source_range", range(0, (v.position - cursor) * vr / s.rate, vr));
                            items.add_object_element(gap);
                        }
                        items.add_object_element(otio_clip(Path.get_basename(v.uri), v.uri, v.start_ms, v.end_ms - v.start_ms, vr));
                        cursor = v.position + (v.end_ms - v.start_ms) * s.rate / 1000;
                    }
                } else {
                    t.sort_clips();
                    foreach (var c in t.clips) {
                        if (c.position > cursor) {
                            var gap = new Json.Object();
                            gap.set_string_member("OTIO_SCHEMA", "Gap.1");
                            gap.set_object_member("source_range", range(0, c.position - cursor, s.rate));
                            items.add_object_element(gap);
                        }
                        int64 len = c.position < cursor ? c.end - cursor : c.length;
                        int64 off = c.source_offset + (c.position < cursor ? cursor - c.position : 0);
                        if (len <= 0) continue;
                        items.add_object_element(otio_clip(c.name, File.new_for_path(c.path).get_uri(), off, len, s.rate));
                        cursor = int64.max(cursor, c.end);
                    }
                }
                tr.set_array_member("children", items);
                children.add_object_element(tr);
            }
            stack.set_array_member("children", children);
            tl.set_object_member("tracks", stack);
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(tl);
            var g = new Json.Generator();
            g.pretty = true;
            g.root = n;
            return g.to_data(null);
        }

        private Json.Object otio_clip(string name, string uri, double start, double duration, double rate) {
            var clip = new Json.Object();
            clip.set_string_member("OTIO_SCHEMA", "Clip.2");
            clip.set_string_member("name", name);
            clip.set_object_member("source_range", range(start, duration, rate));
            var refs = new Json.Object();
            var ext = new Json.Object();
            ext.set_string_member("OTIO_SCHEMA", "ExternalReference.1");
            ext.set_string_member("target_url", uri);
            refs.set_object_member("DEFAULT_MEDIA", ext);
            clip.set_object_member("media_references", refs);
            clip.set_string_member("active_media_reference_key", "DEFAULT_MEDIA");
            return clip;
        }

        private double rt_seconds(Json.Object o) {
            double rate = o.get_double_member_with_default("rate", 1);
            return o.get_double_member_with_default("value", 0) / (rate > 0 ? rate : 1);
        }

        public Session import_otio(string path, int rate) throws Error {
            var p = new Json.Parser();
            p.load_from_file(path);
            var tl = p.get_root().get_object();
            var s = new Session(rate, 2);
            s.title = tl.get_string_member_with_default("name", Path.get_basename(path));
            var pool = SessionFile.pool(s);
            var decoded = new Gee.HashMap<string, PcmSource>();
            foreach (var tn in tl.get_object_member("tracks").get_array_member("children").get_elements()) {
                var to = tn.get_object();
                bool video = to.get_string_member_with_default("kind", "Audio") == "Video";
                var track = s.add_track(to.get_string_member_with_default("name", ""), video ? TrackKind.VIDEO : TrackKind.AUDIO);
                double cursor = 0;
                foreach (var cn in to.get_array_member("children").get_elements()) {
                    var co = cn.get_object();
                    string schema = co.get_string_member_with_default("OTIO_SCHEMA", "");
                    var sr = co.has_member("source_range") && co.get_member("source_range").get_node_type() == Json.NodeType.OBJECT ? co.get_object_member("source_range") : null;
                    double start = sr != null ? rt_seconds(sr.get_object_member("start_time")) : 0;
                    double dur = sr != null ? rt_seconds(sr.get_object_member("duration")) : 0;
                    if (schema.has_prefix("Gap")) {
                        cursor += dur;
                        continue;
                    }
                    if (!schema.has_prefix("Clip")) continue;
                    string? url = null;
                    if (co.has_member("media_references")) {
                        var refs = co.get_object_member("media_references");
                        string key = co.get_string_member_with_default("active_media_reference_key", "DEFAULT_MEDIA");
                        if (refs.has_member(key)) url = refs.get_object_member(key).get_string_member_with_default("target_url", "");
                    } else if (co.has_member("media_reference")) {
                        url = co.get_object_member("media_reference").get_string_member_with_default("target_url", "");
                    }
                    if (url == null || url == "") {
                        cursor += dur;
                        continue;
                    }
                    string fp = url.has_prefix("file://") ? File.new_for_uri(url).get_path() : (Path.is_absolute(url) ? url : Path.build_filename(Path.get_dirname(path), url));
                    if (video) {
                        track.video_segments.add(new VideoSegment(File.new_for_path(fp).get_uri(), (int64) (cursor * rate), (int64) (start * 1000), (int64) ((start + dur) * 1000)));
                    } else if (FileUtils.test(fp, FileTest.EXISTS)) {
                        PcmSource? src = decoded[fp];
                        if (src == null) {
                            src = Decoder.decode_sync(fp).source;
                            decoded[fp] = src;
                        }
                        var clip = s.add_clip(track, src, fp, (int64) Math.round(cursor * rate));
                        pool.id_for(src, fp);
                        clip.name = co.get_string_member_with_default("name", clip.name);
                        clip.source_offset = (int64) Math.round(start * src.rate);
                        clip.length = int64.max(1, (int64) Math.round(dur * rate));
                    }
                    cursor += dur;
                }
            }
            s.checkpoint(_("Import"));
            return s;
        }

        public Session import_montage(string path, int rate) throws Error {
            var p = new Json.Parser();
            p.load_from_file(path);
            var root = p.get_root().get_object();
            var s = new Session(rate, 2);
            s.title = Path.get_basename(path).replace(".montage", "");
            s.template = "montage:" + path;
            var pool = SessionFile.pool(s);
            var tracks = new Gee.HashMap<string, Track>();
            var muted = new Gee.HashSet<string>();
            Track? vtrack = null;
            Track? from_video = null;
            foreach (var tn in root.get_array_member("tracks").get_elements()) {
                var to = tn.get_object();
                if (to.get_boolean_member_with_default("muted", false)) muted.add(to.get_string_member("id"));
                if (to.get_string_member_with_default("kind", "video") == "audio") {
                    tracks[to.get_string_member("id")] = s.add_track(to.get_string_member_with_default("name", _("Audio")), TrackKind.AUDIO);
                }
            }
            var decoded = new Gee.HashMap<string, PcmSource?>();
            foreach (var cn in root.get_array_member("clips").get_elements()) {
                var co = cn.get_object();
                string uri = co.get_string_member("uri");
                string tid = co.get_string_member_with_default("track", "video-1");
                int64 pos_ns = co.get_int_member_with_default("position", 0);
                int64 start_ns = co.get_int_member_with_default("start", 0);
                int64 end_ns = co.get_int_member_with_default("end", 0);
                var t = tracks[tid];
                if (t == null) {
                    if (vtrack == null) {
                        vtrack = s.add_track(_("Video"), TrackKind.VIDEO);
                        s.tracks.remove(vtrack);
                        s.tracks.insert(0, vtrack);
                    }
                    vtrack.video_segments.add(new VideoSegment(uri, pos_ns * rate / Gst.SECOND, start_ns / Gst.MSECOND, end_ns / Gst.MSECOND));
                    if (muted.contains(tid)) continue;
                    if (from_video == null) {
                        from_video = s.add_track(_("Video Sound"), TrackKind.AUDIO);
                        from_video.role = "dialogue";
                    }
                    t = from_video;
                }
                string fp = File.new_for_uri(uri).get_path() ?? uri;
                if (!decoded.has_key(fp)) {
                    try {
                        decoded[fp] = Decoder.decode_sync(fp).source;
                    } catch (Error e) {
                        decoded[fp] = null;
                    }
                }
                var src = decoded[fp];
                if (src == null) continue;
                var clip = s.add_clip(t, src, fp, pos_ns * rate / Gst.SECOND);
                pool.id_for(src, fp);
                clip.source_offset = start_ns * src.rate / Gst.SECOND;
                clip.length = int64.max(1, (end_ns - start_ns) * rate / Gst.SECOND);
            }
            s.checkpoint(_("Import"));
            return s;
        }

        public void return_to_montage(string montage_path, string mix_path, int64 duration_ns) throws Error {
            var p = new Json.Parser();
            p.load_from_file(montage_path);
            var root = p.get_root().get_object();
            var tracks = root.get_array_member("tracks");
            var keep = new Json.Array();
            string mix_id = "wave-mix";
            foreach (var tn in tracks.get_elements()) {
                var to = tn.get_object();
                if (to.get_string_member("id") == mix_id) continue;
                to.set_boolean_member("muted", true);
                keep.add_object_element(to);
            }
            foreach (var tn in keep.get_elements()) {
                var to = tn.get_object();
                if (to.get_string_member_with_default("kind", "video") == "video") to.set_boolean_member("muted", false);
            }
            var mix = new Json.Object();
            mix.set_string_member("id", mix_id);
            mix.set_string_member("name", _("Wave Mix"));
            mix.set_string_member("kind", "audio");
            mix.set_boolean_member("locked", false);
            mix.set_boolean_member("muted", false);
            mix.set_boolean_member("visible", true);
            keep.add_object_element(mix);
            root.set_array_member("tracks", keep);
            var clips = new Json.Array();
            foreach (var cn in root.get_array_member("clips").get_elements()) {
                if (cn.get_object().get_string_member_with_default("track", "") != mix_id) clips.add_element(cn.copy());
            }
            var c = new Json.Object();
            c.set_string_member("id", Uuid.string_random());
            c.set_string_member("uri", File.new_for_path(mix_path).get_uri());
            c.set_string_member("track", mix_id);
            c.set_int_member("position", 0);
            c.set_int_member("start", 0);
            c.set_int_member("end", duration_ns);
            clips.add_object_element(c);
            root.set_array_member("clips", clips);
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(root);
            var g = new Json.Generator();
            g.pretty = true;
            g.root = n;
            g.to_file(montage_path);
        }
    }
}
