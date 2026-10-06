namespace Singularity.Apps.Wave {

    public const int PEAK_BASE = 256;
    public const int PEAK_FACTOR = 4;

    public class PeakLevel {
        public int block;
        public float[] data;
        public int64 count;
    }

    public class Peaks : Object {
        public int channels { get; construct; }
        public Gee.ArrayList<PeakLevel> levels = new Gee.ArrayList<PeakLevel>();

        public Peaks(int channels) {
            Object(channels: channels);
        }

        public static Peaks build(float* samples, int64 frames, int channels) {
            var p = new Peaks(channels);
            var first = new PeakLevel();
            first.block = PEAK_BASE;
            first.count = (frames + PEAK_BASE - 1) / PEAK_BASE;
            first.data = new float[first.count * channels * 2];
            for (int64 b = 0; b < first.count; b++) {
                int64 start = b * PEAK_BASE;
                int64 end = int64.min(start + PEAK_BASE, frames);
                for (int c = 0; c < channels; c++) {
                    float lo = 0, hi = 0;
                    for (int64 f = start; f < end; f++) {
                        float v = samples[f * channels + c];
                        if (v < lo) lo = v;
                        if (v > hi) hi = v;
                    }
                    first.data[(b * channels + c) * 2] = lo;
                    first.data[(b * channels + c) * 2 + 1] = hi;
                }
            }
            p.levels.add(first);
            p.extend();
            return p;
        }

        private void extend() {
            while (levels[levels.size - 1].count > 64) {
                var prev = levels[levels.size - 1];
                var next = new PeakLevel();
                next.block = prev.block * PEAK_FACTOR;
                next.count = (prev.count + PEAK_FACTOR - 1) / PEAK_FACTOR;
                next.data = new float[next.count * channels * 2];
                for (int64 b = 0; b < next.count; b++) {
                    for (int c = 0; c < channels; c++) {
                        float lo = float.MAX, hi = -float.MAX;
                        for (int64 k = b * PEAK_FACTOR; k < int64.min((b + 1) * PEAK_FACTOR, prev.count); k++) {
                            lo = float.min(lo, prev.data[(k * channels + c) * 2]);
                            hi = float.max(hi, prev.data[(k * channels + c) * 2 + 1]);
                        }
                        next.data[(b * channels + c) * 2] = lo;
                        next.data[(b * channels + c) * 2 + 1] = hi;
                    }
                }
                levels.add(next);
            }
        }

        public PeakLevel level_for(double frames_per_pixel) {
            PeakLevel best = levels[0];
            foreach (var l in levels) {
                if (l.block <= frames_per_pixel) best = l;
            }
            return best;
        }

        public void save(string path) throws Error {
            var os = new DataOutputStream(File.new_for_path(path).replace(null, false, FileCreateFlags.REPLACE_DESTINATION));
            os.byte_order = DataStreamByteOrder.LITTLE_ENDIAN;
            os.put_int32(0x57504b31);
            os.put_int32(channels);
            os.put_int32(levels.size);
            foreach (var l in levels) {
                os.put_int32(l.block);
                os.put_int64(l.count);
                uint8[] bytes = new uint8[l.data.length * 4];
                Memory.copy(bytes, l.data, bytes.length);
                os.write_all(bytes, null);
            }
            os.close();
        }

        public static Peaks? load(string path) {
            try {
                var ds = new DataInputStream(File.new_for_path(path).read());
                ds.byte_order = DataStreamByteOrder.LITTLE_ENDIAN;
                if (ds.read_int32() != 0x57504b31) return null;
                var p = new Peaks(ds.read_int32());
                int n = ds.read_int32();
                for (int i = 0; i < n; i++) {
                    var l = new PeakLevel();
                    l.block = ds.read_int32();
                    l.count = ds.read_int64();
                    l.data = new float[l.count * p.channels * 2];
                    uint8[] bytes = new uint8[l.data.length * 4];
                    size_t got;
                    ds.read_all(bytes, out got);
                    if (got != bytes.length) return null;
                    Memory.copy(l.data, bytes, bytes.length);
                    p.levels.add(l);
                }
                return p.levels.size > 0 ? p : null;
            } catch (Error e) {
                return null;
            }
        }
    }

    public class PcmSource : Object {
        public string id { get; construct; }
        public int rate { get; construct; }
        public int channels { get; construct; }
        public int64 frames { get; private set; }
        public string path { get; construct; }
        public bool temporary { get; set; default = true; }
        public string origin { get; set; default = ""; }
        public Peaks peaks { get; private set; }

        private void* map = null;
        private size_t map_size = 0;

        public float* data {
            get { return (float*) map; }
        }

        private PcmSource(string id, int rate, int channels, string path) {
            Object(id: id, rate: rate, channels: channels, path: path);
        }

        public static string cache_dir() {
            string dir = Path.build_filename(Environment.get_user_cache_dir(), "singularity-wave", "sources");
            DirUtils.create_with_parents(dir, 0700);
            return dir;
        }

        public static void prune_cache(int days) {
            string dir = cache_dir();
            int64 limit = get_real_time() - (int64) days * 86400 * 1000000;
            try {
                var d = Dir.open(dir);
                string? name;
                while ((name = d.read_name()) != null) {
                    string p = Path.build_filename(dir, name);
                    Posix.Stat st;
                    if (Posix.stat(p, out st) == 0 && (int64) st.st_mtime * 1000000 < limit) FileUtils.unlink(p);
                }
            } catch (Error e) {
            }
        }

        public static PcmSource open_raw(string path, int rate, int channels, bool temporary) throws Error {
            var s = new PcmSource(Uuid.string_random(), rate, channels, path);
            s.temporary = temporary;
            s.map_file();
            string peaks_path = path + ".peaks";
            Peaks? p = temporary ? null : Peaks.load(peaks_path);
            if (p == null || p.channels != channels) {
                p = Peaks.build(s.data, s.frames, channels);
                if (!temporary) {
                    try {
                        p.save(peaks_path);
                    } catch (Error e) {
                    }
                }
            }
            s.peaks = p;
            return s;
        }

        public static PcmSource from_samples(float[] samples, int rate, int channels) throws Error {
            var w = new SourceWriter(rate, channels);
            w.write(samples, samples.length / channels);
            return w.finish();
        }

        private void map_file() throws Error {
            int fd = Posix.open(path, Posix.O_RDONLY);
            if (fd < 0) throw new IOError.FAILED(_("Cannot open %s").printf(path));
            Posix.Stat st;
            Posix.fstat(fd, out st);
            map_size = (size_t) st.st_size;
            frames = (int64) map_size / (4 * channels);
            if (map_size > 0) {
                map = Posix.mmap(null, map_size, Posix.PROT_READ, Posix.MAP_SHARED, fd, 0);
                if (map == Posix.MAP_FAILED) {
                    map = null;
                    Posix.close(fd);
                    throw new IOError.FAILED(_("Cannot map %s").printf(path));
                }
            }
            Posix.close(fd);
        }

        ~PcmSource() {
            if (map != null) Posix.munmap(map, map_size);
            if (temporary) {
                FileUtils.unlink(path);
                FileUtils.unlink(path + ".peaks");
            }
        }

        public void read(int64 start, int64 count, float[] dest, int64 dest_frame = 0, int dest_channels = 0) {
            int dc = dest_channels > 0 ? dest_channels : channels;
            for (int64 i = 0; i < count; i++) {
                int64 f = start + i;
                int64 o = (dest_frame + i) * dc;
                if (f < 0 || f >= frames) {
                    for (int c = 0; c < dc; c++) dest[o + c] = 0;
                    continue;
                }
                float* row = data + f * channels;
                if (dc == channels) {
                    for (int c = 0; c < dc; c++) dest[o + c] = row[c];
                } else if (channels == 1) {
                    for (int c = 0; c < dc; c++) dest[o + c] = row[0];
                } else if (dc == 1) {
                    float sum = 0;
                    for (int c = 0; c < channels; c++) sum += row[c];
                    dest[o] = sum / channels;
                } else {
                    for (int c = 0; c < dc; c++) dest[o + c] = c < channels ? row[c] : 0;
                }
            }
        }

        public void copy_frames(int64 start, int64 count, float* dest) {
            int64 a = start.clamp(0, frames);
            int64 b = (start + count).clamp(0, frames);
            int64 lead = a - start;
            if (lead > 0) Memory.set(dest, 0, (size_t) (lead * channels * 4));
            if (b > a) Memory.copy(dest + lead * channels, data + a * channels, (size_t) ((b - a) * channels * 4));
            int64 tail = count - lead - int64.max(b - a, 0);
            if (tail > 0) Memory.set(dest + (count - tail) * channels, 0, (size_t) (tail * channels * 4));
        }
    }

    public class SourceWriter : Object {
        public int rate { get; construct; }
        public int channels { get; construct; }
        public string path { get; private set; }
        public int64 frames { get; private set; default = 0; }
        public bool keep { get; set; default = false; }

        private FileStream? stream;

        public SourceWriter(int rate, int channels, string? target = null) throws Error {
            Object(rate: rate, channels: channels);
            path = target ?? Path.build_filename(PcmSource.cache_dir(), Uuid.string_random() + ".f32");
            stream = FileStream.open(path, "wb");
            if (stream == null) throw new IOError.FAILED(_("Cannot write %s").printf(path));
        }

        public void write(float[] interleaved, int64 count) {
            write_ptr((float*) interleaved, count);
        }

        public void write_ptr(float* interleaved, int64 count) {
            if (count <= 0) return;
            unowned uint8[] bytes = (uint8[]) interleaved;
            bytes.length = (int) (count * channels * 4);
            stream.write(bytes);
            frames += count;
        }

        public PcmSource finish() throws Error {
            stream.flush();
            stream = null;
            return PcmSource.open_raw(path, rate, channels, !keep);
        }

        public void abort() {
            stream = null;
            FileUtils.unlink(path);
        }
    }
}
