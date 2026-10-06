namespace Singularity.Apps.Wave {

    [CCode (cname = "WAVE_SYSCONFDIR")]
    extern const string SYSCONFDIR;

    public class TranscriptWord {
        public string text;
        public int64 start;
        public int64 end;
        public bool deleted = false;

        public TranscriptWord(string text, int64 start, int64 end) {
            this.text = text;
            this.start = start;
            this.end = end;
        }
    }

    public class Transcript : Object {
        public Gee.ArrayList<TranscriptWord> words { get; default = new Gee.ArrayList<TranscriptWord>(); }
        public int rate { get; set; default = 48000; }
        public string engine { get; set; default = ""; }

        public string text() {
            var sb = new StringBuilder();
            foreach (var w in words) {
                if (w.deleted) continue;
                if (sb.len > 0) sb.append_c(' ');
                sb.append(w.text);
            }
            return sb.str;
        }

        public string to_json() {
            var o = new Json.Object();
            o.set_int_member("rate", rate);
            o.set_string_member("engine", engine);
            var a = new Json.Array();
            foreach (var w in words) {
                var wo = new Json.Object();
                wo.set_string_member("t", w.text);
                wo.set_int_member("s", w.start);
                wo.set_int_member("e", w.end);
                if (w.deleted) wo.set_boolean_member("d", true);
                a.add_object_element(wo);
            }
            o.set_array_member("words", a);
            var n = new Json.Node(Json.NodeType.OBJECT);
            n.set_object(o);
            return Json.to_string(n, false);
        }

        public static Transcript? from_json(string text) {
            if (text == "") return null;
            try {
                var p = new Json.Parser();
                p.load_from_data(text);
                var o = p.get_root().get_object();
                var t = new Transcript();
                t.rate = (int) o.get_int_member_with_default("rate", 48000);
                t.engine = o.get_string_member_with_default("engine", "");
                foreach (var n in o.get_array_member("words").get_elements()) {
                    var wo = n.get_object();
                    var w = new TranscriptWord(wo.get_string_member("t"), wo.get_int_member("s"), wo.get_int_member("e"));
                    w.deleted = wo.get_boolean_member_with_default("d", false);
                    t.words.add(w);
                }
                return t;
            } catch (Error e) {
                return null;
            }
        }

        public string srt() {
            var sb = new StringBuilder();
            int n = 1;
            int i = 0;
            while (i < words.size) {
                int j = i;
                int chars = 0;
                while (j < words.size && chars < 70 && (j == i || words[j].start - words[j - 1].end < rate / 2)) {
                    if (!words[j].deleted) chars += words[j].text.length + 1;
                    j++;
                }
                var line = new StringBuilder();
                for (int k = i; k < j; k++) {
                    if (words[k].deleted) continue;
                    if (line.len > 0) line.append_c(' ');
                    line.append(words[k].text);
                }
                if (line.len > 0) {
                    sb.append("%d\n%s --> %s\n%s\n\n".printf(n++, srt_time(words[i].start), srt_time(words[j - 1].end), line.str));
                }
                i = j;
            }
            return sb.str;
        }

        private string srt_time(int64 f) {
            int64 ms = f * 1000 / rate;
            return "%02lld:%02lld:%02lld,%03lld".printf(ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000);
        }

        public Gee.List<int64?> deleted_ranges(int64 pad) {
            var list = new Gee.ArrayList<int64?>();
            int i = 0;
            while (i < words.size) {
                if (!words[i].deleted) {
                    i++;
                    continue;
                }
                int j = i;
                while (j + 1 < words.size && words[j + 1].deleted) j++;
                int64 a = i > 0 ? (words[i - 1].end + words[i].start) / 2 : int64.max(0, words[i].start - pad);
                int64 b = j + 1 < words.size ? (words[j].end + words[j + 1].start) / 2 : words[j].end + pad;
                list.add(a);
                list.add(b);
                i = j + 1;
            }
            return list;
        }
    }

    public abstract class TranscriptionBackend : Object {
        public abstract string name { get; }
        public abstract async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error;
    }

    public class DictationBackend : TranscriptionBackend {
        public const string BUS_NAME = "dev.sinty.Dictation";
        private DBusConnection connection;

        public override string name { get { return "dictation"; } }

        public DictationBackend(DBusConnection connection) {
            this.connection = connection;
        }

        public static bool present(DBusConnection connection) {
            try {
                var reply = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "NameHasOwner", new Variant("(s)", BUS_NAME), null, DBusCallFlags.NONE, 2000, null);
                bool owned;
                reply.get("(b)", out owned);
                if (owned) return true;
                reply = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                    "ListActivatableNames", null, null, DBusCallFlags.NONE, 2000, null);
                var names = reply.get_child_value(0);
                for (size_t i = 0; i < names.n_children(); i++) {
                    if (names.get_child_value(i).get_string() == BUS_NAME) return true;
                }
            } catch (Error e) {
            }
            return false;
        }

        public override async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error {
            Variant reply;
            try {
                reply = yield connection.call(BUS_NAME, "/dev/sinty/Dictation", BUS_NAME, "TranscribeFile",
                    new Variant("(ss)", wav_path, language), new VariantType("(s)"), DBusCallFlags.NONE, 30 * 60 * 1000, cancellable);
            } catch (Error e) {
                DBusError.strip_remote_error(e);
                throw e;
            }
            string text;
            reply.get("(s)", out text);
            return text.strip();
        }
    }

    public class CommandTranscriber : TranscriptionBackend {
        public string[] argv { get; construct; }

        public override string name { get { return "command"; } }

        public CommandTranscriber(string[] argv) {
            Object(argv: argv);
        }

        public static string? config_value(string group, string key) {
            string[] dirs = { Environment.get_user_config_dir() };
            foreach (string dir in Environment.get_system_config_dirs()) dirs += dir;
            dirs += SYSCONFDIR;
            foreach (string dir in dirs) {
                foreach (string file in new string[] { "wave.conf", "recorder.conf" }) {
                    string path = Path.build_filename(dir, "singularity", file);
                    if (!FileUtils.test(path, FileTest.IS_REGULAR)) continue;
                    try {
                        var kf = new KeyFile();
                        kf.load_from_file(path, KeyFileFlags.NONE);
                        if (kf.has_key(group, key)) return kf.get_string(group, key);
                    } catch (Error e) {
                    }
                }
            }
            return null;
        }

        public static CommandTranscriber? from_config() {
            string? cmd = config_value("Transcription", "Command");
            if (cmd == null) return null;
            try {
                string[] argv;
                GLib.Shell.parse_argv(cmd, out argv);
                return argv.length > 0 ? new CommandTranscriber(argv) : null;
            } catch (Error e) {
                return null;
            }
        }

        public override async string transcribe(string wav_path, string language, Cancellable? cancellable) throws Error {
            string[] command = {};
            foreach (string arg in argv) command += arg.replace("%f", wav_path).replace("%l", language == "" ? "auto" : language);
            var process = new Subprocess.newv(command, SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string? output = null;
            yield process.communicate_utf8_async(null, cancellable, out output, null);
            if (!process.get_successful()) throw new IOError.FAILED(_("The speech engine stopped unexpectedly"));
            return (output ?? "").strip();
        }
    }

    public class Transcriber : Object {
        public signal void progress(double fraction);

        public TranscriptionBackend? backend { get; private set; }

        public static TranscriptionBackend? locate() {
            try {
                var c = Bus.get_sync(BusType.SESSION);
                if (DictationBackend.present(c)) return new DictationBackend(c);
            } catch (Error e) {
            }
            return CommandTranscriber.from_config();
        }

        public Transcriber() {
            backend = locate();
        }

        public static Gee.List<int64?> utterances(float[] mono, int64 frames, int rate) {
            int frame_ms = 20;
            int hop = rate * frame_ms / 1000;
            int count = (int) (frames / hop) + 1;
            var flags = new uint8[count];
            int got = WaveDsp.vad(mono, frames, rate, frame_ms, flags, count);
            var spans = new Gee.ArrayList<int64?>();
            int i = 0;
            int merge = 300 / frame_ms;
            int max_len = 25000 / frame_ms;
            while (i < got) {
                if (flags[i] == 0) {
                    i++;
                    continue;
                }
                int j = i;
                int gap = 0;
                while (j < got && (j - i) < max_len) {
                    if (flags[j] != 0) gap = 0;
                    else if (++gap > merge) break;
                    j++;
                }
                int end = j - gap;
                if (end - i >= 4) {
                    spans.add(int64.max(0, (int64) i * hop - hop * 5));
                    spans.add(int64.min(frames, (int64) end * hop + hop * 5));
                }
                i = j;
            }
            return spans;
        }

        public static void align(Gee.List<TranscriptWord> out_words, string text, float[] mono, int64 a, int64 b, int rate) {
            string[] parts = {};
            foreach (string w in Regex.split_simple("\\s+", text.strip())) {
                if (w != "") parts += w;
            }
            if (parts.length == 0) return;
            int total_chars = 0;
            foreach (string w in parts) total_chars += w.char_count() + 1;
            int hop = rate / 100;
            int64 len = b - a;
            int64 cursor = a;
            for (int k = 0; k < parts.length; k++) {
                int64 span = len * (parts[k].char_count() + 1) / total_chars;
                int64 end = k == parts.length - 1 ? b : cursor + span;
                if (k < parts.length - 1) {
                    int64 best = end;
                    double best_e = double.MAX;
                    for (int64 c = int64.max(cursor + hop, end - rate / 8); c < int64.min(b - hop, end + rate / 8); c += hop) {
                        double e = 0;
                        for (int64 s = c - hop / 2; s < c + hop / 2; s++) {
                            if (s >= 0 && s < mono.length) e += mono[s] * mono[s];
                        }
                        if (e < best_e) {
                            best_e = e;
                            best = c;
                        }
                    }
                    end = best;
                }
                out_words.add(new TranscriptWord(parts[k], cursor, end));
                cursor = end;
            }
        }

        public async Transcript transcribe(Renderable src, string language, Cancellable? cancel) throws Error {
            if (backend == null) throw new IOError.NOT_SUPPORTED(_("No speech engine is available. Install the desktop dictation models or configure a transcription command."));
            int rate = src.sample_rate;
            int64 frames = src.total_frames;
            float[] mono = new float[frames];
            int ch = src.channel_count;
            int block = 65536;
            var tmp = new float[block * ch];
            for (int64 pos = 0; pos < frames; pos += block) {
                int n = (int) int64.min(block, frames - pos);
                src.render(pos, n, tmp);
                for (int f = 0; f < n; f++) {
                    float sum = 0;
                    for (int c = 0; c < ch; c++) sum += tmp[f * ch + c];
                    mono[pos + f] = sum / ch;
                }
            }
            var spans = utterances(mono, frames, rate);
            var t = new Transcript();
            t.rate = rate;
            t.engine = backend.name;
            string dir = DirUtils.make_tmp("wave-transcribe-XXXXXX");
            try {
                for (int i = 0; i + 1 < spans.size; i += 2) {
                    if (cancel != null && cancel.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
                    int64 a = spans[i], b = spans[i + 1];
                    string wav = Path.build_filename(dir, "u%d.wav".printf(i / 2));
                    var piece = new float[b - a];
                    Memory.copy(piece, &mono[a], (size_t) ((b - a) * sizeof(float)));
                    int64 n16 = WaveDsp.resample_frames(b - a, rate, 16000);
                    var r16 = new float[n16];
                    n16 = WaveDsp.resample(piece, b - a, 1, rate, 16000, r16, n16);
                    var w = new WavWriter();
                    w.bits = 16;
                    w.dither = false;
                    w.open(wav, 16000, 1);
                    w.write(r16, (int) n16);
                    w.close();
                    string text = yield backend.transcribe(wav, language, cancel);
                    FileUtils.unlink(wav);
                    align(t.words, text, mono, a, b, rate);
                    progress((double) (i + 2) / spans.size);
                }
            } finally {
                DirUtils.remove(dir);
            }
            return t;
        }
    }

    namespace TextEdit {
        public int apply_document(Document doc, Transcript t) {
            var ranges = t.deleted_ranges(doc.rate / 50);
            int cuts = 0;
            for (int i = ranges.size - 2; i >= 0; i -= 2) {
                int64 a = doc.snap_zero(ranges[i]);
                int64 b = doc.snap_zero(ranges[i + 1]);
                if (b <= a) continue;
                doc.replace(a, b, {}, _("Delete Words"));
                int64 removed = b - a;
                var keep = new Gee.ArrayList<TranscriptWord>();
                foreach (var w in t.words) {
                    if (w.deleted && w.start >= a - doc.rate && w.end <= b + doc.rate) continue;
                    if (w.start >= b) {
                        w.start -= removed;
                        w.end -= removed;
                    }
                    keep.add(w);
                }
                t.words.clear();
                t.words.add_all(keep);
                cuts++;
            }
            doc.transcript_json = t.to_json();
            return cuts;
        }

        public int apply_session(Session s, Transcript t) {
            var ranges = t.deleted_ranges(s.rate / 50);
            int cuts = 0;
            for (int i = ranges.size - 2; i >= 0; i -= 2) {
                int64 a = ranges[i], b = ranges[i + 1];
                if (b <= a) continue;
                ripple_delete(s, a, b);
                int64 removed = b - a;
                var keep = new Gee.ArrayList<TranscriptWord>();
                foreach (var w in t.words) {
                    if (w.deleted && w.start >= a && w.end <= b) continue;
                    if (w.start >= b) {
                        w.start -= removed;
                        w.end -= removed;
                    }
                    keep.add(w);
                }
                t.words.clear();
                t.words.add_all(keep);
                cuts++;
            }
            s.transcript_json = t.to_json();
            s.checkpoint(_("Delete Words"));
            s.changed();
            return cuts;
        }

        public void ripple_delete(Session s, int64 a, int64 b) {
            int64 removed = b - a;
            foreach (var t in s.tracks) {
                if (t.kind != TrackKind.AUDIO) continue;
                var next = new Gee.ArrayList<Clip>();
                foreach (var c in t.clips) {
                    if (c.end <= a) {
                        next.add(c);
                    } else if (c.position >= b) {
                        c.position -= removed;
                        next.add(c);
                    } else {
                        if (c.position < a) {
                            var left = c.duplicate();
                            left.length = a - c.position;
                            left.fade_out = int64.min(left.fade_out, left.length);
                            next.add(left);
                        }
                        if (c.end > b) {
                            var right = c.duplicate();
                            int64 skip = b - c.position;
                            right.source_offset = c.source_offset + (int64) (skip / c.stretch);
                            right.length = c.end - b;
                            right.position = a;
                            right.fade_in = int64.min(s.rate / 200, right.length);
                            next.add(right);
                        }
                    }
                }
                t.clips.clear();
                t.clips.add_all(next);
                t.sort_clips();
                foreach (var l in t.lanes) {
                    l.remove_range(a, b);
                    foreach (var p in l.points) {
                        if (p.frame >= b) p.frame -= removed;
                    }
                }
            }
            foreach (var m in s.markers) {
                if (m.start >= b) m.start -= removed;
                else if (m.start > a) m.start = a;
            }
        }
    }
}
