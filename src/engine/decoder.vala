namespace Singularity.Apps.Wave {

    public class DecodedMedia : Object {
        public PcmSource source;
        public Metadata metadata = new Metadata();
        public Gee.ArrayList<Marker> markers = new Gee.ArrayList<Marker>();
        public string path = "";
        public bool has_video = false;
    }

    public class Decoder : Object {
        public signal void progress(double fraction);

        private Cancellable cancellable = new Cancellable();

        public void cancel() {
            cancellable.cancel();
        }

        public static string cache_key(string path) {
            Posix.Stat st;
            string stamp = Posix.stat(path, out st) == 0 ? "%lld:%lld".printf((int64) st.st_size, (int64) st.st_mtime) : "";
            return Checksum.compute_for_string(ChecksumType.SHA1, path + "|" + stamp);
        }

        public async DecodedMedia decode(string path) throws Error {
            DecodedMedia? result = null;
            Error? failure = null;
            SourceFunc callback = decode.callback;
            new Thread<void>("wave-decode", () => {
                try {
                    result = decode_sync(path, cancellable, (f) => {
                        Idle.add(() => {
                            progress(f);
                            return Source.REMOVE;
                        });
                    });
                } catch (Error e) {
                    failure = e;
                }
                Idle.add((owned) callback);
            });
            yield;
            if (failure != null) throw failure;
            return result;
        }

        public static DecodedMedia decode_sync(string path, Cancellable? cancel = null, owned ProgressFunc? report = null) throws Error {
            var media = new DecodedMedia();
            media.path = path;
            string key = cache_key(path);
            string raw = Path.build_filename(PcmSource.cache_dir(), key + ".f32");
            string meta = Path.build_filename(PcmSource.cache_dir(), key + ".json");
            var pcm = PcmFile.probe(path);
            if (pcm != null) {
                media.metadata = pcm.metadata;
                media.markers.add_all(pcm.markers);
            }
            if (FileUtils.test(raw, FileTest.EXISTS) && FileUtils.test(meta, FileTest.EXISTS)) {
                try {
                    var parser = new Json.Parser();
                    parser.load_from_file(meta);
                    var o = parser.get_root().get_object();
                    media.source = PcmSource.open_raw(raw, (int) o.get_int_member("rate"), (int) o.get_int_member("channels"), false);
                    media.source.origin = path;
                    if (pcm == null) media.metadata = Metadata.from_json(o.get_object_member("metadata"));
                    if (pcm == null && o.has_member("markers")) {
                        foreach (var mn in o.get_array_member("markers").get_elements()) media.markers.add(Marker.from_json(mn.get_object()));
                    }
                    media.has_video = o.get_boolean_member_with_default("video", false);
                    if (report != null) report(1.0);
                    return media;
                } catch (Error e) {
                }
            }
            PcmSource src;
            if (pcm != null) {
                pcm.path_hint = path;
                src = pcm.decode(cancel, (owned) report);
            } else {
                src = gst_decode(path, media, cancel, (owned) report);
            }
            if (pcm == null && media.markers.size == 0) {
                foreach (var m in Id3.read_chapters(path, src.rate)) media.markers.add(m);
            }
            FileUtils.rename(src.path, raw);
            src.temporary = false;
            var cached = PcmSource.open_raw(raw, src.rate, src.channels, false);
            cached.origin = path;
            media.source = cached;
            var o = new Json.Object();
            o.set_int_member("rate", src.rate);
            o.set_int_member("channels", src.channels);
            o.set_string_member("path", path);
            o.set_boolean_member("video", media.has_video);
            o.set_object_member("metadata", media.metadata.to_json());
            var ma = new Json.Array();
            foreach (var m in media.markers) ma.add_object_element(m.to_json());
            o.set_array_member("markers", ma);
            var root = new Json.Node(Json.NodeType.OBJECT);
            root.set_object(o);
            var gen = new Json.Generator();
            gen.root = root;
            gen.to_file(meta);
            return media;
        }

        private static PcmSource gst_decode(string path, DecodedMedia media, Cancellable? cancel, owned ProgressFunc? report) throws Error {
            var pipeline = (Gst.Pipeline) Gst.parse_launch(
                "uridecodebin name=dec ! audioconvert ! audio/x-raw,format=F32LE,layout=interleaved ! appsink name=sink sync=false max-buffers=64");
            var dec = ((Gst.Bin) pipeline).get_by_name("dec");
            dec.set("uri", File.new_for_path(path).get_uri());
            dec.pad_added.connect((pad) => {
                var caps = pad.get_current_caps() ?? pad.query_caps(null);
                if (caps != null && caps.get_size() > 0 && caps.get_structure(0).get_name().has_prefix("video/")) media.has_video = true;
            });
            var sink = (Gst.App.Sink) ((Gst.Bin) pipeline).get_by_name("sink");
            pipeline.set_state(Gst.State.PLAYING);
            SourceWriter? writer = null;
            var comments = new Gee.ArrayList<string>();
            int64 duration = 0;
            int64 done = 0;
            try {
                while (true) {
                    if (cancel != null && cancel.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
                    var sample = sink.try_pull_sample(100 * Gst.MSECOND);
                    var bus = pipeline.get_bus();
                    Gst.Message? msg;
                    while ((msg = bus.pop_filtered(Gst.MessageType.ERROR | Gst.MessageType.TAG)) != null) {
                        if (msg.type == Gst.MessageType.ERROR) {
                            Error e;
                            string dbg;
                            msg.parse_error(out e, out dbg);
                            throw new IOError.FAILED(_("This file cannot be opened: %s").printf(e.message));
                        }
                        Gst.TagList tags;
                        msg.parse_tag(out tags);
                        media.metadata.merge_tags(tags);
                        uint count = tags.get_tag_size(Gst.Tags.EXTENDED_COMMENT);
                        for (uint i = 0; i < count; i++) {
                            string ec;
                            if (tags.get_string_index(Gst.Tags.EXTENDED_COMMENT, i, out ec)) comments.add(ec);
                        }
                    }
                    if (sample == null) {
                        if (sink.is_eos()) break;
                        continue;
                    }
                    if (writer == null) {
                        unowned Gst.Structure s = sample.get_caps().get_structure(0);
                        int rate, channels;
                        s.get_int("rate", out rate);
                        s.get_int("channels", out channels);
                        writer = new SourceWriter(rate, channels);
                        pipeline.query_duration(Gst.Format.TIME, out duration);
                    }
                    var buffer = sample.get_buffer();
                    Gst.MapInfo info;
                    if (buffer.map(out info, Gst.MapFlags.READ)) {
                        int64 n = info.data.length / (4 * writer.channels);
                        writer.write_ptr((float*) info.data, n);
                        done += n;
                        buffer.unmap(info);
                    }
                    if (report != null && duration > 0) report(double.min(1.0, (double) done * Gst.SECOND / writer.rate / duration));
                }
            } catch (Error e) {
                pipeline.set_state(Gst.State.NULL);
                if (writer != null) writer.abort();
                throw e;
            }
            pipeline.set_state(Gst.State.NULL);
            if (writer == null) throw new IOError.FAILED(_("This file has no audio"));
            var times = new Gee.TreeMap<string, string>();
            var names = new Gee.HashMap<string, string>();
            foreach (string ec in comments) {
                int eq = ec.index_of("=");
                if (eq <= 0) continue;
                string key = ec.substring(0, eq).up();
                string val = ec.substring(eq + 1);
                if (!key.has_prefix("CHAPTER")) continue;
                if (key.has_suffix("NAME")) names[key.substring(0, key.length - 4)] = val;
                else times[key] = val;
            }
            foreach (var e in times.entries) {
                int64 at = Timecode.parse(e.value, writer.rate);
                if (at >= 0) media.markers.add(new Marker(names[e.key] ?? e.key, at, 0, "chapter"));
            }
            return writer.finish();
        }

        public static bool looks_like_media(string path) {
            string lower = path.down();
            foreach (string ext in new string[] { ".wav", ".bwf", ".flac", ".mp3", ".ogg", ".oga", ".opus", ".m4a", ".aac", ".aif", ".aiff", ".aifc", ".caf", ".mp4", ".mkv", ".mov", ".webm", ".wma", ".mka" }) {
                if (lower.has_suffix(ext)) return true;
            }
            return false;
        }
    }
}
