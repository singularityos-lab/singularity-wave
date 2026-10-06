namespace Singularity.Apps.Wave {

    public abstract class AudioTarget : Object {
        public int rate { get; protected set; }
        public int channels { get; protected set; }
        public int bits { get; set; default = 24; }
        public bool is_float { get; set; default = false; }
        public bool dither { get; set; default = true; }
        public Metadata metadata { get; set; default = new Metadata(); }
        public Gee.List<Marker> markers { get; set; default = new Gee.ArrayList<Marker>(); }
        public int64 written { get; protected set; default = 0; }

        protected uint32 seed = 0x1234567;

        public abstract void open(string path, int rate, int channels) throws Error;
        public abstract void write(float[] interleaved, int frames) throws Error;
        public abstract void close() throws Error;

        protected uint8[] pcm_bytes(float[] interleaved, int frames, bool big_endian) {
            int samples = frames * channels;
            if (is_float) {
                var res = new uint8[samples * 4];
                for (int i = 0; i < samples; i++) {
                    uint32 v = *((uint32*) (&interleaved[i]));
                    put32(res, i * 4, v, big_endian);
                }
                return res;
            }
            int width = bits / 8;
            var raw = new uint8[samples * (bits == 24 ? 3 : width)];
            WaveDsp.quantize_frames(interleaved, frames, channels, bits, dither && bits < 32, dither && bits == 16, ref seed, raw);
            if (big_endian) {
                int w = bits == 24 ? 3 : width;
                for (int i = 0; i < samples; i++) {
                    for (int k = 0; k < w / 2; k++) {
                        uint8 t = raw[i * w + k];
                        raw[i * w + k] = raw[i * w + w - 1 - k];
                        raw[i * w + w - 1 - k] = t;
                    }
                }
            }
            return raw;
        }

        public static void put32(uint8[] b, int at, uint32 v, bool big_endian) {
            if (big_endian) {
                b[at] = (uint8) (v >> 24);
                b[at + 1] = (uint8) (v >> 16);
                b[at + 2] = (uint8) (v >> 8);
                b[at + 3] = (uint8) v;
            } else {
                b[at] = (uint8) v;
                b[at + 1] = (uint8) (v >> 8);
                b[at + 2] = (uint8) (v >> 16);
                b[at + 3] = (uint8) (v >> 24);
            }
        }
    }

    public class ByteWriter {
        public ByteArray data = new ByteArray();
        public bool big_endian = false;

        public void u8(uint8 v) {
            data.append({ v });
        }

        public void u16(uint16 v) {
            if (big_endian) data.append({ (uint8) (v >> 8), (uint8) v });
            else data.append({ (uint8) v, (uint8) (v >> 8) });
        }

        public void u32(uint32 v) {
            var b = new uint8[4];
            AudioTarget.put32(b, 0, v, big_endian);
            data.append(b);
        }

        public void u64(uint64 v) {
            if (big_endian) {
                u32((uint32) (v >> 32));
                u32((uint32) v);
            } else {
                u32((uint32) v);
                u32((uint32) (v >> 32));
            }
        }

        public void tag(string four) {
            data.append(four.data[0:4]);
        }

        public void fixed(string text, int size) {
            var b = new uint8[size];
            int n = int.min(text.length, size);
            Memory.copy(b, text.data, n);
            data.append(b);
        }

        public void bytes(uint8[] b) {
            data.append(b);
        }

        public void pad() {
            if (data.len % 2 == 1) u8(0);
        }
    }

    public class WavWriter : AudioTarget {
        public bool broadcast { get; set; default = false; }

        private FileOutputStream? stream;
        private string path;
        private int64 data_offset = 0;
        private bool extensible = false;

        public override void open(string path, int rate, int channels) throws Error {
            this.path = path;
            this.rate = rate;
            this.channels = channels;
            if (is_float) bits = 32;
            stream = File.new_for_path(path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION);
            extensible = channels > 2 || (bits == 24 && !is_float && channels > 2);
            var h = new ByteWriter();
            h.tag("RIFF");
            h.u32(0);
            h.tag("WAVE");
            h.tag("JUNK");
            h.u32(28);
            h.bytes(new uint8[28]);
            h.tag("fmt ");
            h.u32(extensible ? 40 : 16);
            h.u16(extensible ? 0xFFFE : (is_float ? 3 : 1));
            h.u16((uint16) channels);
            h.u32(rate);
            int block = channels * bits / 8;
            h.u32(rate * block);
            h.u16((uint16) block);
            h.u16((uint16) bits);
            if (extensible) {
                h.u16(22);
                h.u16((uint16) bits);
                h.u32(channel_mask(channels));
                h.u32(is_float ? 3 : 1);
                h.bytes({ 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 });
            }
            if (broadcast) write_bext(h);
            h.tag("data");
            h.u32(0);
            stream.write_all(h.data.data, null);
            data_offset = h.data.len;
        }

        public static uint32 channel_mask(int channels) {
            switch (channels) {
            case 1: return 0x4;
            case 2: return 0x3;
            case 3: return 0x7;
            case 4: return 0x33;
            case 5: return 0x37;
            case 6: return 0x3F;
            case 8: return 0x63F;
            default: return 0;
            }
        }

        private void write_bext(ByteWriter h) {
            var b = new ByteWriter();
            b.fixed(metadata.description != "" ? metadata.description : metadata.title, 256);
            b.fixed(metadata.originator, 32);
            b.fixed(metadata.originator_reference, 32);
            var now = new DateTime.now_local();
            b.fixed(metadata.origination_date != "" ? metadata.origination_date : now.format("%Y-%m-%d"), 10);
            b.fixed(metadata.origination_time != "" ? metadata.origination_time : now.format("%H:%M:%S"), 8);
            b.u64((uint64) metadata.time_reference);
            b.u16(1);
            b.bytes(new uint8[64]);
            b.bytes(new uint8[10]);
            b.bytes(new uint8[180]);
            string history = metadata.coding_history != "" ? metadata.coding_history :
                "A=PCM,F=%d,W=%d,M=%s,T=Singularity Wave\r\n".printf(rate, bits, channels == 1 ? "mono" : channels == 2 ? "stereo" : "multichannel");
            b.bytes(history.data);
            b.pad();
            h.tag("bext");
            h.u32(b.data.len);
            h.bytes(b.data.data);
        }

        public override void write(float[] interleaved, int frames) throws Error {
            var bytes = pcm_bytes(interleaved, frames, false);
            stream.write_all(bytes, null);
            written += frames;
        }

        public override void close() throws Error {
            int64 data_size = written * channels * (bits / 8);
            if (data_size % 2 == 1) stream.write_all({ 0 }, null);
            var tail = new ByteWriter();
            write_markers(tail);
            write_info(tail);
            stream.write_all(tail.data.data, null);
            int64 total = data_offset + data_size + (data_size % 2) + tail.data.len;
            bool rf64 = total > uint32.MAX;
            stream.seek(0, SeekType.SET);
            var h = new ByteWriter();
            h.tag(rf64 ? "RF64" : "RIFF");
            h.u32(rf64 ? uint32.MAX : (uint32) (total - 8));
            h.tag("WAVE");
            if (rf64) {
                h.tag("ds64");
                h.u32(28);
                h.u64((uint64) (total - 8));
                h.u64((uint64) data_size);
                h.u64((uint64) written);
                h.u32(0);
            }
            stream.write_all(h.data.data, null);
            stream.seek(data_offset - 4, SeekType.SET);
            var d = new ByteWriter();
            d.u32(rf64 ? uint32.MAX : (uint32) data_size);
            stream.write_all(d.data.data, null);
            stream.close();
            stream = null;
        }

        private void write_markers(ByteWriter w) {
            if (markers.size == 0) return;
            var cue = new ByteWriter();
            cue.u32(markers.size);
            int id = 1;
            foreach (var m in markers) {
                cue.u32(id++);
                cue.u32((uint32) m.start);
                cue.tag("data");
                cue.u32(0);
                cue.u32(0);
                cue.u32((uint32) m.start);
            }
            w.tag("cue ");
            w.u32(cue.data.len);
            w.bytes(cue.data.data);
            var adtl = new ByteWriter();
            adtl.tag("adtl");
            id = 1;
            foreach (var m in markers) {
                var text = new ByteWriter();
                text.u32(id);
                text.bytes(m.name.data);
                text.u8(0);
                adtl.tag("labl");
                adtl.u32(text.data.len);
                adtl.bytes(text.data.data);
                adtl.pad();
                if (m.length > 0) {
                    var lt = new ByteWriter();
                    lt.u32(id);
                    lt.u32((uint32) m.length);
                    lt.tag("rgn ");
                    lt.u16(0);
                    lt.u16(0);
                    lt.u16(0);
                    lt.u16(0);
                    adtl.tag("ltxt");
                    adtl.u32(lt.data.len);
                    adtl.bytes(lt.data.data);
                }
                id++;
            }
            w.tag("LIST");
            w.u32(adtl.data.len);
            w.bytes(adtl.data.data);
            w.pad();
        }

        private void write_info(ByteWriter w) {
            var info = new ByteWriter();
            info.tag("INFO");
            string[,] fields = {
                { "INAM", metadata.title }, { "IART", metadata.artist }, { "IPRD", metadata.album },
                { "IGNR", metadata.genre }, { "ICRD", metadata.year }, { "ICMT", metadata.comment },
                { "ICOP", metadata.copyright }, { "ITRK", metadata.track }, { "ISFT", "Singularity Wave" }
            };
            for (int i = 0; i < fields.length[0]; i++) {
                if (fields[i, 1] == "") continue;
                info.tag(fields[i, 0]);
                info.u32(fields[i, 1].length + 1);
                info.bytes(fields[i, 1].data);
                info.u8(0);
                info.pad();
            }
            w.tag("LIST");
            w.u32(info.data.len);
            w.bytes(info.data.data);
            w.pad();
        }
    }

    public class AiffWriter : AudioTarget {
        private FileOutputStream? stream;
        private int64 ssnd_offset = 0;

        public override void open(string path, int rate, int channels) throws Error {
            this.rate = rate;
            this.channels = channels;
            if (is_float) bits = 32;
            stream = File.new_for_path(path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION);
            var h = header(0);
            stream.write_all(h.data.data, null);
            ssnd_offset = h.data.len;
        }

        private ByteWriter header(int64 frames) {
            var h = new ByteWriter();
            h.big_endian = true;
            h.tag("FORM");
            h.u32(0);
            h.tag(is_float ? "AIFC" : "AIFF");
            if (is_float) {
                h.tag("FVER");
                h.u32(4);
                h.u32((uint32) 0xA2805140);
            }
            h.tag("COMM");
            h.u32(is_float ? 24 : 18);
            h.u16((uint16) channels);
            h.u32((uint32) frames);
            h.u16((uint16) bits);
            h.bytes(extended(rate));
            if (is_float) {
                h.tag("fl32");
                h.u8(0);
                h.u8(0);
            }
            h.tag("SSND");
            h.u32(0);
            h.u32(0);
            h.u32(0);
            return h;
        }

        public static uint8[] extended(double value) {
            var b = new uint8[10];
            if (value <= 0) return b;
            int exp;
            double mant = Math.frexp(value, out exp);
            int e = exp - 1 + 16383;
            uint64 m = (uint64) (mant * 18446744073709551616.0);
            b[0] = (uint8) (e >> 8);
            b[1] = (uint8) e;
            for (int i = 0; i < 8; i++) b[2 + i] = (uint8) (m >> (56 - i * 8));
            return b;
        }

        public static double read_extended(uint8[] b, int at) {
            int e = ((b[at] & 0x7f) << 8) | b[at + 1];
            uint64 m = 0;
            for (int i = 0; i < 8; i++) m = (m << 8) | b[at + 2 + i];
            if (e == 0 && m == 0) return 0;
            return Math.ldexp((double) m, e - 16383 - 63);
        }

        public override void write(float[] interleaved, int frames) throws Error {
            stream.write_all(pcm_bytes(interleaved, frames, true), null);
            written += frames;
        }

        public override void close() throws Error {
            int64 data_size = written * channels * (bits / 8);
            if (data_size % 2 == 1) stream.write_all({ 0 }, null);
            var tail = new ByteWriter();
            tail.big_endian = true;
            if (markers.size > 0) {
                var mk = new ByteWriter();
                mk.big_endian = true;
                mk.u16((uint16) markers.size);
                int id = 1;
                foreach (var m in markers) {
                    mk.u16((uint16) id++);
                    mk.u32((uint32) m.start);
                    string name = m.name.length > 254 ? m.name.substring(0, 254) : m.name;
                    mk.u8((uint8) name.length);
                    mk.bytes(name.data);
                    if ((name.length + 1) % 2 == 1) mk.u8(0);
                }
                tail.tag("MARK");
                tail.u32(mk.data.len);
                tail.bytes(mk.data.data);
            }
            string[,] texts = { { "NAME", metadata.title }, { "AUTH", metadata.artist }, { "(c) ", metadata.copyright }, { "ANNO", metadata.comment } };
            for (int i = 0; i < texts.length[0]; i++) {
                if (texts[i, 1] == "") continue;
                tail.tag(texts[i, 0]);
                tail.u32(texts[i, 1].length);
                tail.bytes(texts[i, 1].data);
                tail.pad();
            }
            stream.write_all(tail.data.data, null);
            var h = header(written);
            int64 total = h.data.len + data_size + (data_size % 2) + tail.data.len;
            var size = new ByteWriter();
            size.big_endian = true;
            size.u32((uint32) (total - 8));
            Memory.copy(&h.data.data[4], size.data.data, 4);
            size = new ByteWriter();
            size.big_endian = true;
            size.u32((uint32) (data_size + 8));
            Memory.copy(&h.data.data[h.data.len - 12], size.data.data, 4);
            stream.seek(0, SeekType.SET);
            stream.write_all(h.data.data, null);
            stream.close();
        }
    }

    public class CafWriter : AudioTarget {
        private FileOutputStream? stream;
        private int64 data_pos = 0;

        public override void open(string path, int rate, int channels) throws Error {
            this.rate = rate;
            this.channels = channels;
            if (is_float) bits = 32;
            stream = File.new_for_path(path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION);
            var h = new ByteWriter();
            h.big_endian = true;
            h.tag("caff");
            h.u16(1);
            h.u16(0);
            h.tag("desc");
            h.u64(32);
            double r = rate;
            h.u64(*((uint64*) (&r)));
            h.tag("lpcm");
            h.u32(is_float ? 1 : 0);
            h.u32((uint32) (channels * bits / 8));
            h.u32(1);
            h.u32((uint32) channels);
            h.u32((uint32) bits);
            if (markers.size > 0) {
                var mk = new ByteWriter();
                mk.big_endian = true;
                var strings = new ByteWriter();
                mk.u32(markers.size);
                int id = 1;
                foreach (var m in markers) {
                    mk.u32((uint32) id);
                    mk.u64((uint64) strings.data.len);
                    strings.bytes(m.name.data);
                    strings.u8(0);
                    id++;
                }
                h.tag("strg");
                h.u64(mk.data.len + strings.data.len);
                h.bytes(mk.data.data);
                h.bytes(strings.data.data);
                var mark = new ByteWriter();
                mark.big_endian = true;
                mark.u32(0);
                mark.u32(markers.size);
                id = 1;
                foreach (var m in markers) {
                    mark.u32(0);
                    double pos = m.start;
                    mark.u64(*((uint64*) (&pos)));
                    mark.u32((uint32) id++);
                    mark.u32(0);
                    mark.u32(0);
                    mark.u32(0);
                }
                h.tag("mark");
                h.u64(mark.data.len);
                h.bytes(mark.data.data);
            }
            h.tag("data");
            h.u64(uint64.MAX);
            h.u32(0);
            stream.write_all(h.data.data, null);
            data_pos = h.data.len - 12;
        }

        public override void write(float[] interleaved, int frames) throws Error {
            stream.write_all(pcm_bytes(interleaved, frames, true), null);
            written += frames;
        }

        public override void close() throws Error {
            var d = new ByteWriter();
            d.big_endian = true;
            d.u64((uint64) (written * channels * (bits / 8) + 4));
            stream.seek(data_pos, SeekType.SET);
            stream.write_all(d.data.data, null);
            stream.close();
        }
    }

    public class PcmFile : Object {
        public int rate;
        public int channels;
        public int bits;
        public bool is_float;
        public bool big_endian;
        public int64 data_offset;
        public int64 data_size;
        public Metadata metadata = new Metadata();
        public Gee.ArrayList<Marker> markers = new Gee.ArrayList<Marker>();

        public int64 frames {
            get { return channels > 0 && bits > 0 ? data_size / (channels * (bits / 8)) : 0; }
        }

        private static uint32 le32(uint8[] b, int64 at) {
            return (uint32) b[at] | ((uint32) b[at + 1] << 8) | ((uint32) b[at + 2] << 16) | ((uint32) b[at + 3] << 24);
        }

        private static uint16 le16(uint8[] b, int64 at) {
            return (uint16) (b[at] | (b[at + 1] << 8));
        }

        private static uint32 be32(uint8[] b, int64 at) {
            return ((uint32) b[at] << 24) | ((uint32) b[at + 1] << 16) | ((uint32) b[at + 2] << 8) | (uint32) b[at + 3];
        }

        private static uint64 be64(uint8[] b, int64 at) {
            return ((uint64) be32(b, at) << 32) | be32(b, at + 4);
        }

        private static string cstr(uint8[] b, int64 at, int64 max) {
            var s = new StringBuilder();
            for (int64 i = 0; i < max && at + i < b.length && b[at + i] != 0; i++) s.append_c((char) b[at + i]);
            return s.str.make_valid().strip();
        }

        private static string fourcc(uint8[] b, int64 at) {
            var s = new StringBuilder();
            for (int64 i = 0; i < 4 && at + i < b.length; i++) s.append_c((char) b[at + i]);
            return s.str;
        }

        public static PcmFile? probe(string path) {
            uint8[] head = new uint8[0];
            try {
                var f = File.new_for_path(path).read();
                head = new uint8[4 * 1024 * 1024];
                size_t got;
                f.read_all(head, out got);
                head.length = (int) got;
                f.close();
            } catch (Error e) {
                return null;
            }
            if (head.length < 12) return null;
            string magic = fourcc(head, 0);
            string kind = fourcc(head, 8);
            if ((magic == "RIFF" || magic == "RF64") && kind == "WAVE") return parse_wav(path, head, magic == "RF64");
            if (magic == "FORM" && (kind == "AIFF" || kind == "AIFC")) return parse_aiff(path, head, kind == "AIFC");
            if (magic == "caff") return parse_caf(path, head);
            return null;
        }

        private static uint8[] tail_bytes(string path, int64 offset) {
            try {
                var f = File.new_for_path(path).read();
                f.seek(offset, SeekType.SET);
                var b = new uint8[2 * 1024 * 1024];
                size_t got;
                f.read_all(b, out got);
                b.length = (int) got;
                return b;
            } catch (Error e) {
                return new uint8[0];
            }
        }

        private static PcmFile? parse_wav(string path, uint8[] head, bool rf64) {
            var p = new PcmFile();
            int64 pos = 12;
            int64 ds64_data = -1;
            uint8[] b = head;
            int64 base_offset = 0;
            var labels = new Gee.HashMap<uint32, string>();
            var lengths = new Gee.HashMap<uint32, int64?>();
            var cues = new Gee.ArrayList<uint32>();
            var cue_pos = new Gee.HashMap<uint32, int64?>();
            while (true) {
                if (pos - base_offset + 8 > b.length) {
                    if (p.data_offset > 0 && pos > p.data_offset) {
                        b = tail_bytes(path, pos);
                        base_offset = pos;
                        if (b.length < 8) break;
                    } else {
                        break;
                    }
                }
                int64 at = pos - base_offset;
                string id = fourcc(b, at);
                int64 size = le32(b, at + 4);
                if (id == "ds64") {
                    ds64_data = (int64) (le32(b, at + 16) | ((uint64) le32(b, at + 20) << 32));
                } else if (id == "fmt ") {
                    int fmt = le16(b, at + 8);
                    p.channels = le16(b, at + 10);
                    p.rate = (int) le32(b, at + 12);
                    p.bits = le16(b, at + 22);
                    if (fmt == 0xFFFE && size >= 40) fmt = le16(b, at + 32);
                    p.is_float = fmt == 3;
                    if (fmt != 1 && fmt != 3) return null;
                } else if (id == "data") {
                    p.data_offset = pos + 8;
                    p.data_size = rf64 && size == uint32.MAX && ds64_data >= 0 ? ds64_data : size;
                    size = p.data_size;
                } else if (id == "bext" && at + 8 + 346 <= b.length) {
                    p.metadata.description = cstr(b, at + 8, 256);
                    p.metadata.originator = cstr(b, at + 264, 32);
                    p.metadata.originator_reference = cstr(b, at + 296, 32);
                    p.metadata.origination_date = cstr(b, at + 328, 10);
                    p.metadata.origination_time = cstr(b, at + 338, 8);
                    p.metadata.time_reference = (int64) (le32(b, at + 346) | ((uint64) le32(b, at + 350) << 32));
                    if (size > 602) p.metadata.coding_history = cstr(b, at + 610, size - 602);
                } else if (id == "cue " && at + 12 <= b.length) {
                    uint32 n = le32(b, at + 8);
                    for (uint32 i = 0; i < n && at + 12 + i * 24 + 24 <= b.length; i++) {
                        int64 c = at + 12 + i * 24;
                        uint32 cid = le32(b, c);
                        cues.add(cid);
                        cue_pos[cid] = le32(b, c + 20);
                    }
                } else if (id == "LIST" && at + 12 <= b.length) {
                    string list = cstr(b, at + 8, 4);
                    int64 sub = at + 12;
                    int64 end = int64.min(at + 8 + size, b.length);
                    while (sub + 8 <= end) {
                        string sid = fourcc(b, sub);
                        int64 ssize = le32(b, sub + 4);
                        if (list == "adtl" && sid == "labl") labels[le32(b, sub + 8)] = cstr(b, sub + 12, ssize - 4);
                        else if (list == "adtl" && sid == "ltxt") lengths[le32(b, sub + 8)] = le32(b, sub + 12);
                        else if (list == "INFO") {
                            string v = cstr(b, sub + 8, ssize);
                            switch (sid) {
                            case "INAM": p.metadata.title = v; break;
                            case "IART": p.metadata.artist = v; break;
                            case "IPRD": p.metadata.album = v; break;
                            case "IGNR": p.metadata.genre = v; break;
                            case "ICRD": p.metadata.year = v; break;
                            case "ICMT": p.metadata.comment = v; break;
                            case "ICOP": p.metadata.copyright = v; break;
                            case "ITRK": p.metadata.track = v; break;
                            default: break;
                            }
                        }
                        sub += 8 + ssize + (ssize % 2);
                    }
                }
                pos += 8 + size + (size % 2);
            }
            if (p.data_offset == 0 || p.channels == 0) return null;
            foreach (var cid in cues) {
                int64? len = lengths[cid];
                p.markers.add(new Marker(labels[cid] ?? _("Marker %u").printf(cid), cue_pos[cid], len ?? 0));
            }
            p.markers.sort(Marker.compare);
            return p;
        }

        private static PcmFile? parse_aiff(string path, uint8[] b, bool aifc) {
            var p = new PcmFile();
            p.big_endian = true;
            int64 pos = 12;
            while (pos + 8 <= b.length) {
                string id = fourcc(b, pos);
                int64 size = be32(b, pos + 4);
                if (id == "COMM") {
                    p.channels = (int) ((b[pos + 8] << 8) | b[pos + 9]);
                    p.bits = (int) ((b[pos + 14] << 8) | b[pos + 15]);
                    p.rate = (int) Math.round(AiffWriter.read_extended(b, (int) pos + 16));
                    if (aifc && size >= 22) {
                        string comp = fourcc(b, pos + 26);
                        if (comp == "fl32" || comp == "FL32") p.is_float = true;
                        else if (comp == "sowt") p.big_endian = false;
                        else if (comp != "NONE" && comp != "twos") return null;
                    }
                } else if (id == "SSND") {
                    uint32 offset = be32(b, pos + 8);
                    p.data_offset = pos + 16 + offset;
                    p.data_size = size - 8 - offset;
                } else if (id == "MARK") {
                    int n = (b[pos + 8] << 8) | b[pos + 9];
                    int64 m = pos + 10;
                    for (int i = 0; i < n && m + 7 <= b.length; i++) {
                        uint32 mpos = be32(b, m + 2);
                        int len = b[m + 6];
                        string name = cstr(b, m + 7, len);
                        p.markers.add(new Marker(name, mpos));
                        m += 7 + len + ((len + 1) % 2);
                    }
                } else if (id == "NAME") {
                    p.metadata.title = cstr(b, pos + 8, size);
                } else if (id == "AUTH") {
                    p.metadata.artist = cstr(b, pos + 8, size);
                } else if (id == "ANNO") {
                    p.metadata.comment = cstr(b, pos + 8, size);
                }
                pos += 8 + size + (size % 2);
            }
            if (p.data_offset == 0 || p.channels == 0) return null;
            return p;
        }

        private static PcmFile? parse_caf(string path, uint8[] b) {
            var p = new PcmFile();
            p.big_endian = true;
            int64 pos = 8;
            var names = new Gee.HashMap<uint32, string>();
            var marks = new Gee.ArrayList<Marker>();
            var mark_ids = new Gee.ArrayList<uint32>();
            while (pos + 12 <= b.length) {
                string id = fourcc(b, pos);
                int64 size = (int64) be64(b, pos + 4);
                int64 body = pos + 12;
                if (id == "desc") {
                    uint64 r = be64(b, body);
                    double rate = *((double*) (&r));
                    p.rate = (int) Math.round(rate);
                    if (fourcc(b, body + 8) != "lpcm") return null;
                    uint32 flags = be32(b, body + 12);
                    p.is_float = (flags & 1) != 0;
                    p.big_endian = (flags & 2) == 0;
                    p.channels = (int) be32(b, body + 24);
                    p.bits = (int) be32(b, body + 28);
                } else if (id == "data") {
                    p.data_offset = body + 4;
                    p.data_size = size == -1 ? (int64) (FileUtils.test(path, FileTest.EXISTS) ? file_size(path) - p.data_offset : 0) : size - 4;
                    break;
                } else if (id == "strg") {
                    uint32 n = be32(b, body);
                    int64 strings = body + 4 + n * 12;
                    for (uint32 i = 0; i < n; i++) names[be32(b, body + 4 + i * 12)] = cstr(b, strings + (int64) be64(b, body + 8 + i * 12), 256);
                } else if (id == "mark") {
                    uint32 n = be32(b, body + 4);
                    for (uint32 i = 0; i < n; i++) {
                        int64 m = body + 8 + i * 28;
                        uint64 fp = be64(b, m + 4);
                        double frame = *((double*) (&fp));
                        mark_ids.add(be32(b, m + 12));
                        marks.add(new Marker("", (int64) frame));
                    }
                }
                pos = body + size;
            }
            for (int i = 0; i < marks.size; i++) marks[i].name = names[mark_ids[i]] ?? _("Marker %d").printf(i + 1);
            p.markers.add_all(marks);
            if (p.data_offset == 0 || p.channels == 0) return null;
            return p;
        }

        private static int64 file_size(string path) {
            Posix.Stat st;
            return Posix.stat(path, out st) == 0 ? (int64) st.st_size : 0;
        }

        public PcmSource decode(Cancellable? cancel, owned ProgressFunc? progress) throws Error {
            var w = new SourceWriter(rate, channels);
            var f = File.new_for_path(path_hint).read();
            f.seek(data_offset, SeekType.SET);
            int bps = bits / 8;
            int64 total = frames;
            int64 done = 0;
            int block = 65536;
            var raw = new uint8[block * channels * bps];
            var fbuf = new float[block * channels];
            while (done < total) {
                if (cancel != null && cancel.is_cancelled()) {
                    w.abort();
                    throw new IOError.CANCELLED(_("Cancelled"));
                }
                int n = (int) int64.min(block, total - done);
                size_t got;
                raw.length = n * channels * bps;
                f.read_all(raw, out got);
                n = (int) (got / (channels * bps));
                if (n <= 0) break;
                for (int i = 0; i < n * channels; i++) {
                    int o = i * bps;
                    float v = 0;
                    if (is_float && bits == 32) {
                        uint32 u = big_endian ? be32(raw, o) : le32(raw, o);
                        v = *((float*) (&u));
                    } else if (is_float && bits == 64) {
                        uint64 u = big_endian ? be64(raw, o) : ((uint64) le32(raw, o) | ((uint64) le32(raw, o + 4) << 32));
                        v = (float) (*((double*) (&u)));
                    } else if (bits == 8) {
                        v = big_endian ? ((int8) raw[o]) / 128.0f : (raw[o] - 128) / 128.0f;
                    } else if (bits == 16) {
                        int16 s = big_endian ? (int16) ((raw[o] << 8) | raw[o + 1]) : (int16) (raw[o] | (raw[o + 1] << 8));
                        v = s / 32768.0f;
                    } else if (bits == 24) {
                        int32 s = big_endian ? (int32) (((uint32) raw[o] << 24) | ((uint32) raw[o + 1] << 16) | ((uint32) raw[o + 2] << 8))
                            : (int32) (((uint32) raw[o + 2] << 24) | ((uint32) raw[o + 1] << 16) | ((uint32) raw[o] << 8));
                        v = (float) (s / 2147483648.0);
                    } else if (bits == 32) {
                        int32 s = (int32) (big_endian ? be32(raw, o) : le32(raw, o));
                        v = (float) (s / 2147483648.0);
                    }
                    fbuf[i] = v;
                }
                w.write(fbuf, n);
                done += n;
                if (progress != null) progress((double) done / total);
            }
            return w.finish();
        }

        public string path_hint = "";
    }

    public delegate void ProgressFunc(double fraction);
}
