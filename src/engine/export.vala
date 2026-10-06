namespace Singularity.Apps.Wave {

    public enum ExportFormat {
        WAV,
        BWF,
        AIFF,
        CAF,
        FLAC,
        MP3,
        OGG,
        OPUS,
        M4A;

        public string extension() {
            switch (this) {
            case BWF: return "wav";
            case AIFF: return "aiff";
            case CAF: return "caf";
            case FLAC: return "flac";
            case MP3: return "mp3";
            case OGG: return "ogg";
            case OPUS: return "opus";
            case M4A: return "m4a";
            default: return "wav";
            }
        }

        public string label() {
            switch (this) {
            case BWF: return _("Broadcast Wave (BWF)");
            case AIFF: return "AIFF";
            case CAF: return _("Core Audio (CAF)");
            case FLAC: return "FLAC";
            case MP3: return "MP3";
            case OGG: return "Ogg Vorbis";
            case OPUS: return "Opus";
            case M4A: return _("AAC (M4A)");
            default: return "WAV";
            }
        }

        public string id() {
            switch (this) {
            case BWF: return "bwf";
            case AIFF: return "aiff";
            case CAF: return "caf";
            case FLAC: return "flac";
            case MP3: return "mp3";
            case OGG: return "ogg";
            case OPUS: return "opus";
            case M4A: return "m4a";
            default: return "wav";
            }
        }

        public static ExportFormat from_id(string id) {
            foreach (var f in all()) {
                if (f.id() == id) return f;
            }
            return WAV;
        }

        public static ExportFormat[] all() {
            return { WAV, BWF, AIFF, CAF, FLAC, MP3, OGG, OPUS, M4A };
        }

        public bool lossless() {
            return this == WAV || this == BWF || this == AIFF || this == CAF || this == FLAC;
        }

        public bool available() {
            switch (this) {
            case FLAC: return Gst.ElementFactory.find("flacenc") != null;
            case MP3: return Gst.ElementFactory.find("lamemp3enc") != null;
            case OGG: return Gst.ElementFactory.find("vorbisenc") != null && Gst.ElementFactory.find("oggmux") != null;
            case OPUS: return Gst.ElementFactory.find("opusenc") != null && Gst.ElementFactory.find("oggmux") != null;
            case M4A: return aac_encoder() != null && Gst.ElementFactory.find("mp4mux") != null;
            default: return true;
            }
        }

        public static string? aac_encoder() {
            foreach (string e in new string[] { "fdkaacenc", "avenc_aac", "voaacenc", "faac" }) {
                if (Gst.ElementFactory.find(e) != null) return e;
            }
            return null;
        }
    }

    public class ExportOptions : Object {
        public ExportFormat format { get; set; default = ExportFormat.WAV; }
        public int bits { get; set; default = 24; }
        public bool is_float { get; set; default = false; }
        public bool dither { get; set; default = true; }
        public int rate { get; set; default = 0; }
        public int channels { get; set; default = 0; }
        public int bitrate { get; set; default = 192; }
        public Metadata metadata { get; set; default = new Metadata(); }
        public Gee.List<Marker> markers { get; set; default = new Gee.ArrayList<Marker>(); }
        public bool chapters { get; set; default = true; }
        public bool cue_sheet { get; set; default = false; }
        public bool chapters_json { get; set; default = false; }
        public int64 start { get; set; default = 0; }
        public int64 end { get; set; default = -1; }
    }

    public class Exporter : Object {
        public signal void progress(double fraction);

        private Cancellable cancellable = new Cancellable();

        public void cancel() {
            cancellable.cancel();
        }

        public async void export(Renderable src, string path, ExportOptions options) throws Error {
            Error? failure = null;
            SourceFunc callback = export.callback;
            new Thread<void>("wave-export", () => {
                try {
                    export_sync(src, path, options, cancellable, (f) => {
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
        }

        private static Gee.List<Marker> chapter_list(ExportOptions o, int src_rate, int out_rate) {
            var list = new Gee.ArrayList<Marker>();
            foreach (var m in o.markers) {
                if (m.start < o.start || (o.end >= 0 && m.start >= o.end)) continue;
                var c = m.copy();
                c.start = (m.start - o.start) * out_rate / src_rate;
                c.length = m.length * out_rate / src_rate;
                list.add(c);
            }
            list.sort(Marker.compare);
            return list;
        }

        public static void export_sync(Renderable src, string path, ExportOptions o, Cancellable? cancel = null, owned ProgressFunc? report = null) throws Error {
            int in_rate = src.sample_rate;
            int in_ch = src.channel_count;
            int out_rate = o.rate > 0 ? o.rate : in_rate;
            int out_ch = o.channels > 0 ? o.channels : in_ch;
            int64 a = o.start.clamp(0, src.total_frames);
            int64 b = o.end < 0 ? src.total_frames : o.end.clamp(a, src.total_frames);
            var markers = chapter_list(o, in_rate, out_rate);
            int64 total_out = (b - a) * out_rate / in_rate;
            var feed = new BlockFeed(src, a, b, out_rate, out_ch);
            AudioTarget? target = null;
            switch (o.format) {
            case ExportFormat.WAV:
            case ExportFormat.BWF:
                var w = new WavWriter();
                w.broadcast = o.format == ExportFormat.BWF;
                target = w;
                break;
            case ExportFormat.AIFF:
                target = new AiffWriter();
                break;
            case ExportFormat.CAF:
                target = new CafWriter();
                break;
            default:
                break;
            }
            try {
                if (target != null) {
                    target.bits = o.is_float ? 32 : o.bits;
                    target.is_float = o.is_float;
                    target.dither = o.dither;
                    target.metadata = o.metadata;
                    target.markers = o.chapters ? markers : new Gee.ArrayList<Marker>();
                    target.open(path, out_rate, out_ch);
                    float[] block;
                    int n;
                    while ((n = feed.next(out block)) > 0) {
                        if (cancel != null && cancel.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
                        target.write(block, n);
                        if (report != null) report((double) target.written / int64.max(1, total_out));
                    }
                    target.close();
                } else {
                    encode_gst(feed, path, o, out_rate, out_ch, markers, total_out, cancel, report);
                }
            } catch (Error e) {
                feed.stop();
                FileUtils.unlink(path);
                throw e;
            }
            feed.stop();
            if (o.cue_sheet) Interchange.write_cue(path, Path.get_basename(path), o.format, o.metadata, markers, out_rate);
            if (o.chapters_json) Interchange.write_chapters_json(path + ".chapters.json", markers, out_rate);
            if (report != null) report(1.0);
        }

        private static void encode_gst(BlockFeed feed, string path, ExportOptions o, int rate, int channels, Gee.List<Marker> markers, int64 total, Cancellable? cancel, ProgressFunc? report) throws Error {
            string chain;
            string mp3_tmp = path + ".part";
            switch (o.format) {
            case ExportFormat.FLAC:
                chain = "audioconvert dithering=none noise-shaping=none ! audio/x-raw,format=%s ! flacenc name=enc quality=8 ! filesink name=out".printf(o.bits == 16 ? "S16LE" : "S24_32LE");
                break;
            case ExportFormat.MP3:
                chain = "audioconvert ! lamemp3enc name=enc target=bitrate cbr=false bitrate=%d ! %sfilesink name=out".printf(o.bitrate, Gst.ElementFactory.find("xingmux") != null ? "xingmux ! " : "");
                break;
            case ExportFormat.OGG:
                chain = "audioconvert ! vorbisenc name=enc bitrate=%d ! oggmux ! filesink name=out".printf(o.bitrate * 1000);
                break;
            case ExportFormat.OPUS:
                chain = "audioconvert ! audioresample ! audio/x-raw,rate=48000 ! opusenc name=enc bitrate=%d ! oggmux ! filesink name=out".printf(o.bitrate * 1000);
                break;
            default:
                chain = "audioconvert ! %s name=enc bitrate=%d ! mp4mux name=mux ! filesink name=out".printf(ExportFormat.aac_encoder() ?? "voaacenc", o.bitrate * 1000);
                break;
            }
            if (!o.format.available()) throw new IOError.NOT_SUPPORTED(_("%s export needs an encoder that is not installed").printf(o.format.label()));
            var pipeline = (Gst.Pipeline) Gst.parse_launch("appsrc name=src format=time ! " + chain);
            var bin = (Gst.Bin) pipeline;
            var appsrc = (Gst.App.Src) bin.get_by_name("src");
            appsrc.caps = Gst.Caps.from_string("audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d%s".printf(rate, channels,
                channels > 2 ? ",channel-mask=(bitmask)0x%x".printf(WavWriter.channel_mask(channels)) : ""));
            appsrc.set("block", true);
            appsrc.set("max-bytes", (uint64) (rate * channels * 4));
            bin.get_by_name("out").set("location", o.format == ExportFormat.MP3 ? mp3_tmp : path);
            var tags = o.metadata.to_tags();
            if (o.chapters && (o.format == ExportFormat.FLAC || o.format == ExportFormat.OGG || o.format == ExportFormat.OPUS)) {
                int i = 1;
                foreach (var m in markers) {
                    tags.add(Gst.TagMergeMode.APPEND, Gst.Tags.EXTENDED_COMMENT, "CHAPTER%03d=%s".printf(i, Timecode.clock(m.start, rate)));
                    tags.add(Gst.TagMergeMode.APPEND, Gst.Tags.EXTENDED_COMMENT, "CHAPTER%03dNAME=%s".printf(i, m.name));
                    i++;
                }
            }
            if (o.format != ExportFormat.MP3) {
                var it = bin.iterate_all_by_interface(typeof(Gst.TagSetter));
                Value v = Value(typeof(Gst.Element));
                while (it.next(out v) == Gst.IteratorResult.OK) {
                    var setter = (Gst.TagSetter) v.get_object();
                    setter.merge_tags(tags, Gst.TagMergeMode.REPLACE);
                }
            }
            pipeline.set_state(Gst.State.PLAYING);
            int64 pushed = 0;
            float[] block;
            int n;
            try {
                while ((n = feed.next(out block)) > 0) {
                    if (cancel != null && cancel.is_cancelled()) throw new IOError.CANCELLED(_("Cancelled"));
                    var bytes = new uint8[n * channels * 4];
                    Memory.copy(bytes, block, bytes.length);
                    var buffer = new Gst.Buffer.wrapped((owned) bytes);
                    buffer.pts = pushed * Gst.SECOND / rate;
                    buffer.duration = (pushed + n) * Gst.SECOND / rate - buffer.pts;
                    pushed += n;
                    if (appsrc.push_buffer((owned) buffer) != Gst.FlowReturn.OK) break;
                    if (report != null) report(double.min(0.99, (double) pushed / int64.max(1, total)));
                    var err = pipeline.get_bus().pop_filtered(Gst.MessageType.ERROR);
                    if (err != null) {
                        Error e;
                        string d;
                        err.parse_error(out e, out d);
                        throw e;
                    }
                }
                appsrc.end_of_stream();
                var msg = pipeline.get_bus().timed_pop_filtered(120 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR);
                if (msg == null) throw new IOError.TIMED_OUT(_("The encoder did not finish"));
                if (msg.type == Gst.MessageType.ERROR) {
                    Error e;
                    string d;
                    msg.parse_error(out e, out d);
                    throw e;
                }
            } finally {
                pipeline.set_state(Gst.State.NULL);
            }
            if (o.format == ExportFormat.MP3) {
                uint8[] mp3;
                FileUtils.get_data(mp3_tmp, out mp3);
                FileUtils.unlink(mp3_tmp);
                var tag = Id3.build(o.metadata, o.chapters ? markers : new Gee.ArrayList<Marker>(), rate, pushed);
                var outf = File.new_for_path(path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION);
                outf.write_all(tag, null);
                outf.write_all(mp3, null);
                outf.close();
            }
        }
    }

    public class BlockFeed : Object {
        public const int BLOCK = 8192;
        private Renderable src;
        private int64 pos;
        private int64 end;
        private int out_rate;
        private int out_ch;
        private Gst.Pipeline? conv = null;
        private Gst.App.Src? csrc = null;
        private Gst.App.Sink? csink = null;
        private bool fed_eos = false;
        private int64 fed = 0;
        private float[] tmp;

        public BlockFeed(Renderable src, int64 start, int64 end, int out_rate, int out_ch) throws Error {
            this.src = src;
            this.pos = start;
            this.end = end;
            this.out_rate = out_rate;
            this.out_ch = out_ch;
            tmp = new float[BLOCK * src.channel_count];
            src.seek_hint(start);
            if (out_rate != src.sample_rate || out_ch != src.channel_count) {
                conv = (Gst.Pipeline) Gst.parse_launch(
                    "appsrc name=src format=time block=true ! audioconvert ! audioresample quality=10 ! audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d ! appsink name=sink sync=false".printf(out_rate, out_ch));
                csrc = (Gst.App.Src) ((Gst.Bin) conv).get_by_name("src");
                csrc.caps = Gst.Caps.from_string("audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d".printf(src.sample_rate, src.channel_count));
                csrc.set("max-bytes", (uint64) (BLOCK * src.channel_count * 4 * 4));
                csink = (Gst.App.Sink) ((Gst.Bin) conv).get_by_name("sink");
                conv.set_state(Gst.State.PLAYING);
            }
        }

        private int render_next(float[] dest) {
            if (pos >= end) return 0;
            int n = (int) int64.min(BLOCK, end - pos);
            src.render(pos, n, dest);
            pos += n;
            return n;
        }

        public int next(out float[] block) {
            if (conv == null) {
                int n = render_next(tmp);
                block = tmp;
                return n;
            }
            while (true) {
                var sample = csink.try_pull_sample(fed_eos ? 2 * Gst.SECOND : 0);
                if (sample != null) {
                    var buffer = sample.get_buffer();
                    Gst.MapInfo info;
                    buffer.map(out info, Gst.MapFlags.READ);
                    int n = (int) (info.data.length / (4 * out_ch));
                    block = new float[n * out_ch];
                    Memory.copy(block, info.data, info.data.length);
                    buffer.unmap(info);
                    if (n > 0) return n;
                    continue;
                }
                if (fed_eos) {
                    block = new float[0];
                    return 0;
                }
                int n = render_next(tmp);
                if (n == 0) {
                    csrc.end_of_stream();
                    fed_eos = true;
                    continue;
                }
                var bytes = new uint8[n * src.channel_count * 4];
                Memory.copy(bytes, tmp, bytes.length);
                var gb = new Gst.Buffer.wrapped((owned) bytes);
                gb.pts = fed * Gst.SECOND / src.sample_rate;
                gb.duration = (fed + n) * Gst.SECOND / src.sample_rate - gb.pts;
                fed += n;
                csrc.push_buffer((owned) gb);
            }
        }

        public void stop() {
            if (conv != null) conv.set_state(Gst.State.NULL);
            conv = null;
        }
    }

    namespace Id3 {
        private void syncsafe(ByteWriter w, uint32 v) {
            w.u8((uint8) ((v >> 21) & 0x7f));
            w.u8((uint8) ((v >> 14) & 0x7f));
            w.u8((uint8) ((v >> 7) & 0x7f));
            w.u8((uint8) (v & 0x7f));
        }

        private uint8[] frame(string id, uint8[] body) {
            var w = new ByteWriter();
            w.big_endian = true;
            w.tag(id);
            syncsafe(w, body.length);
            w.u16(0);
            w.bytes(body);
            return w.data.data;
        }

        private uint8[] text(string id, string value) {
            var b = new ByteWriter();
            b.u8(3);
            b.bytes(value.data);
            return frame(id, b.data.data);
        }

        public uint8[] build(Metadata m, Gee.List<Marker> chapters, int rate, int64 total_frames) {
            var frames = new ByteWriter();
            string[,] fields = {
                { "TIT2", m.title }, { "TPE1", m.artist }, { "TALB", m.album }, { "TCON", m.genre },
                { "TDRC", m.year }, { "TRCK", m.track }, { "TCOP", m.copyright }, { "TSRC", m.isrc }, { "TSSE", "Singularity Wave" }
            };
            for (int i = 0; i < fields.length[0]; i++) {
                if (fields[i, 1] != "") frames.bytes(text(fields[i, 0], fields[i, 1]));
            }
            if (m.comment != "") {
                var c = new ByteWriter();
                c.u8(3);
                c.bytes("eng".data);
                c.u8(0);
                c.bytes(m.comment.data);
                frames.bytes(frame("COMM", c.data.data));
            }
            if (chapters.size > 0) {
                var toc = new ByteWriter();
                toc.big_endian = true;
                toc.bytes("toc".data);
                toc.u8(0);
                toc.u8(0x03);
                toc.u8((uint8) int.min(chapters.size, 255));
                for (int i = 0; i < chapters.size && i < 255; i++) {
                    toc.bytes("chp%d".printf(i).data);
                    toc.u8(0);
                }
                frames.bytes(frame("CTOC", toc.data.data));
                for (int i = 0; i < chapters.size && i < 255; i++) {
                    var ch = chapters[i];
                    int64 end_frame = ch.length > 0 ? ch.end : (i + 1 < chapters.size ? chapters[i + 1].start : total_frames);
                    var c = new ByteWriter();
                    c.big_endian = true;
                    c.bytes("chp%d".printf(i).data);
                    c.u8(0);
                    c.u32((uint32) (ch.start * 1000 / rate));
                    c.u32((uint32) (end_frame * 1000 / rate));
                    c.u32(uint32.MAX);
                    c.u32(uint32.MAX);
                    c.bytes(text("TIT2", ch.name));
                    frames.bytes(frame("CHAP", c.data.data));
                }
            }
            var h = new ByteWriter();
            h.bytes("ID3".data);
            h.u8(4);
            h.u8(0);
            h.u8(0);
            syncsafe(h, frames.data.len + 512);
            h.bytes(frames.data.data);
            h.bytes(new uint8[512]);
            return h.data.data;
        }

        private string four(uint8[] d, int at) {
            var sb = new StringBuilder();
            for (int i = 0; i < 4 && at + i < d.length; i++) sb.append_c(d[at + i] >= 32 && d[at + i] < 127 ? (char) d[at + i] : '?');
            return sb.str;
        }

        public Gee.List<Marker> read_chapters(string path, int rate) {
            var list = new Gee.ArrayList<Marker>();
            uint8[] data;
            try {
                FileUtils.get_data(path, out data);
            } catch (Error e) {
                return list;
            }
            if (data.length < 10 || data[0] != 'I' || data[1] != 'D' || data[2] != '3') return list;
            int version = data[3];
            int size = (data[6] << 21) | (data[7] << 14) | (data[8] << 7) | data[9];
            int pos = 10;
            int end = int.min(10 + size, data.length);
            while (pos + 10 <= end) {
                string id = four(data, pos);
                if (data[pos] == 0) break;
                int fs = version >= 4 ? (data[pos + 4] << 21) | (data[pos + 5] << 14) | (data[pos + 6] << 7) | data[pos + 7]
                    : (data[pos + 4] << 24) | (data[pos + 5] << 16) | (data[pos + 6] << 8) | data[pos + 7];
                int body = pos + 10;
                if (id.has_prefix("CHAP") && body + fs <= end) {
                    int p = body;
                    while (p < body + fs && data[p] != 0) p++;
                    p++;
                    uint32 start_ms = ((uint32) data[p] << 24) | ((uint32) data[p + 1] << 16) | ((uint32) data[p + 2] << 8) | data[p + 3];
                    uint32 end_ms = ((uint32) data[p + 4] << 24) | ((uint32) data[p + 5] << 16) | ((uint32) data[p + 6] << 8) | data[p + 7];
                    p += 16;
                    string name = "";
                    while (p + 10 <= body + fs) {
                        string sid = four(data, p);
                        int ss = version >= 4 ? (data[p + 4] << 21) | (data[p + 5] << 14) | (data[p + 6] << 7) | data[p + 7]
                            : (data[p + 4] << 24) | (data[p + 5] << 16) | (data[p + 6] << 8) | data[p + 7];
                        if (sid.has_prefix("TIT2") && ss > 1) {
                            var sb = new StringBuilder();
                            for (int k = p + 11; k < p + 10 + ss && data[k] != 0; k++) sb.append_c((char) data[k]);
                            name = sb.str.make_valid();
                        }
                        p += 10 + ss;
                    }
                    var m = new Marker(name, (int64) start_ms * rate / 1000, (int64) (end_ms - start_ms) * rate / 1000, "chapter");
                    list.add(m);
                }
                pos = body + fs;
            }
            return list;
        }
    }
}
