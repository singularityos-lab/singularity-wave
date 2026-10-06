namespace Singularity.Apps.Wave {

    namespace AudioOutput {
        public string? override_sink() {
            string? v = Environment.get_variable("SINGULARITY_WAVE_AUDIO_SINK");
            return v != null && v != "" ? v : null;
        }

        public Gst.Element make_sink(int latency_samples = 0, int rate = 48000) throws Error {
            string? desc = override_sink();
            if (desc != null) return Gst.parse_bin_from_description(desc, true);
            var sink = Gst.ElementFactory.make("autoaudiosink", null);
            if (sink == null) throw new IOError.NOT_SUPPORTED(_("No audio output is available on this system"));
            if (latency_samples > 0) {
                ((Gst.Bin) sink).element_added.connect((el) => tune(el, latency_samples, rate));
            }
            return sink;
        }

        public void tune(Gst.Element el, int latency_samples, int rate) {
            int64 us = (int64) latency_samples * 1000000 / rate;
            unowned ObjectClass klass = el.get_class();
            if (klass.find_property("buffer-time") != null) el.set("buffer-time", us * 2);
            if (klass.find_property("latency-time") != null) el.set("latency-time", us);
            if (klass.find_property("stream-properties") != null) {
                var props = new Gst.Structure.empty("props");
                props.set_value("node.latency", "%d/%d".printf(latency_samples, rate));
                el.set("stream-properties", props);
            }
        }
    }

    public class Player : Object {
        public bool playing { get; private set; default = false; }
        public int64 position { get; private set; default = 0; }
        public bool looping { get; set; default = false; }
        public int64 loop_start { get; set; default = 0; }
        public int64 loop_end { get; set; default = 0; }
        public int64 stop_at { get; set; default = -1; }
        public bool endless { get; set; default = false; }
        public LiveMeter meter { get; private set; }

        public signal void ended();
        public signal void tick(int64 frame);

        public delegate void BlockHook(float[] buf, int frames, int64 frame);

        private Renderable? source = null;
        private Gst.Pipeline? pipeline = null;
        private Gst.App.Src? appsrc = null;
        private int64 cursor = 0;
        private int64 pushed = 0;
        private int rate = 48000;
        private int channels = 2;
        private Mutex mutex;
        private int64[] map_pts = {};
        private int64[] map_frame = {};
        private uint timer = 0;
        private bool finished_feed = false;
        private BlockHook? hook = null;
        private BlockHook? post_hook = null;

        public Player() {
            meter = new LiveMeter(48000, 2);
        }

        public void set_hook(owned BlockHook? h) {
            mutex.lock();
            hook = (owned) h;
            mutex.unlock();
        }

        public void set_post_hook(owned BlockHook? h) {
            mutex.lock();
            post_hook = (owned) h;
            mutex.unlock();
        }

        public void open(Renderable r) {
            stop();
            source = r;
            rate = r.sample_rate;
            channels = r.channel_count;
            meter.configure(rate, channels);
        }

        public Renderable? current {
            get { return source; }
        }

        public void play(int64 from) {
            if (source == null) return;
            stop_pipeline();
            cursor = from.clamp(0, int64.max(0, source.total_frames));
            if (looping && loop_end > loop_start && (cursor < loop_start || cursor >= loop_end)) cursor = loop_start;
            source.seek_hint(cursor);
            pushed = 0;
            map_pts = {};
            map_frame = {};
            finished_feed = false;
            position = cursor;
            try {
                pipeline = new Gst.Pipeline("wave-player");
                appsrc = (Gst.App.Src) Gst.ElementFactory.make("appsrc", "src");
                appsrc.caps = Gst.Caps.from_string("audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d%s".printf(rate, channels,
                    channels > 2 ? ",channel-mask=(bitmask)0x%x".printf(WavWriter.channel_mask(channels)) : ""));
                appsrc.set("format", Gst.Format.TIME);
                appsrc.set("is-live", false);
                appsrc.set("max-bytes", (uint64) (rate * channels * 4 / 5));
                appsrc.set("block", false);
                appsrc.need_data.connect(feed);
                var conv = Gst.ElementFactory.make("audioconvert", null);
                var res = Gst.ElementFactory.make("audioresample", null);
                var sink = AudioOutput.make_sink();
                pipeline.add_many(appsrc, conv, res, sink);
                appsrc.link_many(conv, res, sink);
                pipeline.get_bus().add_watch(Priority.DEFAULT, on_bus);
                pipeline.set_state(Gst.State.PLAYING);
                playing = true;
                timer = Timeout.add(30, () => {
                    update_position();
                    return Source.CONTINUE;
                });
            } catch (Error e) {
                warning("Wave: playback: %s", e.message);
                stop_pipeline();
            }
        }

        private void feed(Gst.App.Src src, uint length) {
            mutex.lock();
            if (finished_feed || source == null) {
                mutex.unlock();
                return;
            }
            int block = 2048;
            int64 limit = endless ? int64.MAX : source.total_frames;
            if (stop_at >= 0) limit = int64.min(limit, stop_at);
            if (looping && loop_end > loop_start) limit = loop_end;
            int n = (int) int64.min(block, limit - cursor);
            if (n <= 0) {
                if (looping && loop_end > loop_start) {
                    cursor = loop_start;
                    source.seek_hint(cursor);
                    n = (int) int64.min(block, loop_end - cursor);
                } else {
                    finished_feed = true;
                    mutex.unlock();
                    src.end_of_stream();
                    return;
                }
            }
            var buf = new float[n * channels];
            source.render(cursor, n, buf);
            if (hook != null) hook(buf, n, cursor);
            meter.feed(buf, n);
            if (post_hook != null) post_hook(buf, n, cursor);
            map_pts += pushed * Gst.SECOND / rate;
            map_frame += cursor;
            if (map_pts.length > 512) {
                map_pts = map_pts[256:map_pts.length];
                map_frame = map_frame[256:map_frame.length];
            }
            var bytes = new uint8[n * channels * 4];
            Memory.copy(bytes, buf, bytes.length);
            var buffer = new Gst.Buffer.wrapped((owned) bytes);
            buffer.pts = pushed * Gst.SECOND / rate;
            buffer.duration = (pushed + n) * Gst.SECOND / rate - buffer.pts;
            pushed += n;
            cursor += n;
            mutex.unlock();
            src.push_buffer((owned) buffer);
        }

        private void update_position() {
            if (pipeline == null) return;
            int64 pos;
            if (!pipeline.query_position(Gst.Format.TIME, out pos)) return;
            mutex.lock();
            int64 frame = position;
            for (int i = map_pts.length - 1; i >= 0; i--) {
                if (map_pts[i] <= pos) {
                    frame = map_frame[i] + (pos - map_pts[i]) * rate / Gst.SECOND;
                    break;
                }
            }
            mutex.unlock();
            position = frame;
            tick(frame);
        }

        private bool on_bus(Gst.Bus bus, Gst.Message msg) {
            if (msg.type == Gst.MessageType.EOS) {
                update_position();
                stop_pipeline();
                ended();
                return false;
            }
            if (msg.type == Gst.MessageType.ERROR) {
                Error e;
                string d;
                msg.parse_error(out e, out d);
                warning("Wave: playback: %s", e.message);
                stop_pipeline();
                ended();
                return false;
            }
            return true;
        }

        private void stop_pipeline() {
            if (timer != 0) Source.remove(timer);
            timer = 0;
            if (pipeline != null) {
                pipeline.set_state(Gst.State.NULL);
                pipeline = null;
                appsrc = null;
            }
            playing = false;
        }

        public void stop() {
            stop_pipeline();
        }

        public void seek(int64 frame) {
            if (playing) play(frame);
            else position = frame;
        }
    }
}
