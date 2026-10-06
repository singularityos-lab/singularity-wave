namespace Singularity.Apps.Wave {

    public errordomain ZipError {
        FORMAT,
        UNSUPPORTED
    }

    public class ZipReader {
        private uint8[] data;
        private Gee.HashMap<string, Entry> entries = new Gee.HashMap<string, Entry> ();

        private class Entry {
            public uint16 method;
            public uint32 compressed;
            public uint32 size;
            public uint32 offset;
        }

        public ZipReader(uint8[] data) throws ZipError {
            this.data = data;
            int eocd = -1;
            for (int i = data.length - 22; i >= 0 && i >= data.length - 65557; i--) {
                if (u32(i) == 0x06054b50) {
                    eocd = i;
                    break;
                }
            }
            if (eocd < 0) throw new ZipError.FORMAT("not a zip file");
            int count = u16(eocd + 10);
            int pos = (int) u32(eocd + 16);
            for (int n = 0; n < count; n++) {
                if (pos + 46 > data.length || u32(pos) != 0x02014b50) throw new ZipError.FORMAT("bad central directory");
                var e = new Entry();
                e.method = u16(pos + 10);
                e.compressed = u32(pos + 20);
                e.size = u32(pos + 24);
                int name_len = u16(pos + 28);
                int extra_len = u16(pos + 30);
                int comment_len = u16(pos + 32);
                e.offset = u32(pos + 42);
                var nb = new StringBuilder();
                nb.append_len((string) ((uint8*) data + pos + 46), name_len);
                entries[nb.str] = e;
                pos += 46 + name_len + extra_len + comment_len;
            }
        }

        private uint16 u16(int i) {
            return (uint16) (data[i] | (data[i + 1] << 8));
        }

        private uint32 u32(int i) {
            return (uint32) data[i] | ((uint32) data[i + 1] << 8) | ((uint32) data[i + 2] << 16) | ((uint32) data[i + 3] << 24);
        }

        public bool has(string name) {
            return entries.has_key(name);
        }

        public Gee.Set<string> names() {
            return entries.keys;
        }

        public uint8[]? read(string name) throws Error {
            var e = entries[name];
            if (e == null) {
                foreach (var k in entries.keys) {
                    if (k.casefold() == name.casefold()) {
                        e = entries[k];
                        break;
                    }
                }
            }
            if (e == null) return null;
            int p = (int) e.offset;
            if (u32(p) != 0x04034b50) throw new ZipError.FORMAT("bad local header");
            int start = p + 30 + u16(p + 26) + u16(p + 28);
            int end = start + (int) e.compressed;
            if (end > data.length) throw new ZipError.FORMAT("truncated entry");
            uint8[] raw = data[start:end];
            if (e.method == 0) return raw;
            if (e.method != 8) throw new ZipError.UNSUPPORTED("compression method %d", e.method);
            var conv = new ZlibDecompressor(ZlibCompressorFormat.RAW);
            var input = new MemoryInputStream.from_data(raw);
            var stream = new ConverterInputStream(input, conv);
            var out_buf = new ByteArray.sized(e.size > 0 ? e.size : 4096);
            uint8[] chunk = new uint8[65536];
            ssize_t n;
            while ((n = stream.read(chunk)) > 0) out_buf.append(chunk[0:n]);
            return out_buf.steal();
        }

        public string? read_text(string name) throws Error {
            var b = read(name);
            if (b == null) return null;
            var sb = new StringBuilder.sized(b.length + 1);
            sb.append_len((string) b, b.length);
            return sb.str;
        }
    }

    public class ZipWriter {
        private ByteArray out_data = new ByteArray();
        private ByteArray central = new ByteArray();
        private int count = 0;

        private static void put16(ByteArray b, uint v) {
            uint8[] x = { (uint8) (v & 0xff), (uint8) ((v >> 8) & 0xff) };
            b.append(x);
        }

        private static void put32(ByteArray b, uint32 v) {
            uint8[] x = { (uint8) (v & 0xff), (uint8) ((v >> 8) & 0xff), (uint8) ((v >> 16) & 0xff), (uint8) ((v >> 24) & 0xff) };
            b.append(x);
        }

        public void add_text(string name, string text, bool compress = true) throws Error {
            add(name, text.data, compress);
        }

        public void add(string name, uint8[] content, bool compress = true) throws Error {
            uint32 crc = (uint32) ZLib.Utility.crc32(0, content);
            uint8[] payload = content;
            uint16 method = 0;
            if (compress && content.length > 0) {
                var conv = new ZlibCompressor(ZlibCompressorFormat.RAW, 6);
                var mem = new MemoryOutputStream.resizable();
                var stream = new ConverterOutputStream(mem, conv);
                size_t written;
                stream.write_all(content, out written);
                stream.close();
                payload = mem.steal_data();
                payload.length = (int) mem.get_data_size();
                method = 8;
            }
            uint32 offset = out_data.len;
            put32(out_data, 0x04034b50);
            put16(out_data, 20);
            put16(out_data, 0x0800);
            put16(out_data, method);
            put16(out_data, 0);
            put16(out_data, 0x21);
            put32(out_data, crc);
            put32(out_data, payload.length);
            put32(out_data, content.length);
            put16(out_data, name.length);
            put16(out_data, 0);
            out_data.append(name.data);
            out_data.append(payload);

            put32(central, 0x02014b50);
            put16(central, 20);
            put16(central, 20);
            put16(central, 0x0800);
            put16(central, method);
            put16(central, 0);
            put16(central, 0x21);
            put32(central, crc);
            put32(central, payload.length);
            put32(central, content.length);
            put16(central, name.length);
            put16(central, 0);
            put16(central, 0);
            put16(central, 0);
            put16(central, 0);
            put32(central, 0);
            put32(central, offset);
            central.append(name.data);
            count++;
        }

        public uint8[] finish() {
            uint32 cd_offset = out_data.len;
            uint32 cd_size = central.len;
            out_data.append(central.data);
            put32(out_data, 0x06054b50);
            put16(out_data, 0);
            put16(out_data, 0);
            put16(out_data, count);
            put16(out_data, count);
            put32(out_data, cd_size);
            put32(out_data, cd_offset);
            put16(out_data, 0);
            return out_data.steal();
        }
    }
}
