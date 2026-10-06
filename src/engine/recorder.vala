namespace Singularity.Apps.Wave {

    public class InputDevice : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public Gst.Device? device { get; construct; }
        public int channels { get; construct; }

        public InputDevice(string id, string label, Gst.Device? device, int channels) {
            Object(id: id, label: label, device: device, channels: channels);
        }
    }

    public class InputDevices : Object {
        public signal void changed();

        private Gst.DeviceMonitor? monitor = null;
        private Gee.ArrayList<InputDevice> list = new Gee.ArrayList<InputDevice>();

        public InputDevices() {
            if (TestInput.source() == null || Environment.get_variable("SINGULARITY_WAVE_DEVICE_MONITOR") == "1") {
                monitor = new Gst.DeviceMonitor();
                monitor.add_filter("Audio/PcmSource", null);
                monitor.get_bus().add_watch(Priority.DEFAULT, (bus, message) => {
                    if (message.type == Gst.MessageType.DEVICE_ADDED || message.type == Gst.MessageType.DEVICE_REMOVED) {
                        rebuild();
                        changed();
                    }
                    return true;
                });
                monitor.start();
            }
            rebuild();
        }

        public void stop() {
            if (monitor != null) monitor.stop();
        }

        private void rebuild() {
            list.clear();
            if (TestInput.source() != null) {
                list.add(new InputDevice("test", _("Test Input"), null, 2));
                list.add(new InputDevice("test-mono", _("Test Input (Mono)"), null, 1));
            }
            list.add(new InputDevice("", _("System Default"), null, 2));
            if (monitor == null) return;
            var seen = new Gee.HashSet<string>();
            foreach (var device in monitor.get_devices()) {
                var props = device.properties;
                if (props != null && props.has_field("device.class") && props.get_string("device.class") == "monitor") continue;
                string? node = props != null ? props.get_string("node.name") : null;
                if (node == null && props != null) node = props.get_string("device.name");
                string id = node ?? device.display_name;
                if (seen.contains(id)) continue;
                seen.add(id);
                int ch = 2;
                var caps = device.caps;
                if (caps != null && caps.get_size() > 0) {
                    int c;
                    if (caps.get_structure(0).get_int("channels", out c)) ch = c.clamp(1, 8);
                }
                list.add(new InputDevice(id, device.display_name, device, ch));
            }
        }

        public Gee.List<InputDevice> all() {
            return list.read_only_view;
        }

        public InputDevice find(string id) {
            foreach (var d in list) {
                if (d.id == id) return d;
            }
            return list[0];
        }
    }

    namespace TestInput {
        public string? source() {
            string? v = Environment.get_variable("SINGULARITY_WAVE_TEST_INPUT");
            return v != null && v != "" ? v : null;
        }
    }

    public class Recorder : Object {
        public bool recording { get; private set; default = false; }
        public int64 captured { get; private set; default = 0; }
        public float level { get; private set; default = 0; }
        public int rate { get; private set; default = 48000; }
        public int channels { get; private set; default = 2; }
        public int64 punch_in { get; set; default = -1; }
        public int64 punch_out { get; set; default = -1; }
        public int64 start_frame { get; set; default = 0; }
        public bool monitoring { get; private set; default = false; }

        public signal void finished(PcmSource? source, int64 timeline_start);
        public signal void failed(string message);
        public signal void peak(float value);

        private Gst.Pipeline? pipeline = null;
        private Gst.App.Sink? appsink = null;
        private SourceWriter? writer = null;
        private Gst.Pipeline? monitor_pipeline = null;
        private Mutex mutex;
        private float[] peaks = {};

        public float[] take_peaks() {
            mutex.lock();
            var p = peaks;
            mutex.unlock();
            return p;
        }

        public static Gst.Element make_source(InputDevice input, int rate) throws Error {
            string? test = TestInput.source();
            if (input.id.has_prefix("test") && test != null) {
                if (test == "tone") return Gst.parse_bin_from_description("audiotestsrc is-live=true wave=sine freq=440 volume=0.4", true);
                if (test == "voice") return Gst.parse_bin_from_description("audiotestsrc is-live=true wave=pink-noise volume=0.3", true);
                var bin = new Gst.Bin("wave-test-input");
                var file = Gst.ElementFactory.make("filesrc", null);
                var decode = Gst.ElementFactory.make("decodebin", null);
                var tail = Gst.parse_bin_from_description("audioconvert ! audioresample ! identity sync=true", true);
                file.set("location", test);
                bin.add_many(file, decode, tail);
                file.link(decode);
                decode.pad_added.connect((pad) => {
                    var sink = tail.get_static_pad("sink");
                    if (!sink.is_linked()) pad.link(sink);
                });
                bin.add_pad(new Gst.GhostPad("src", tail.get_static_pad("src")));
                return bin;
            }
            if (input.device != null) {
                var element = input.device.create_element(null);
                if (element != null) return element;
            }
            var auto = Gst.ElementFactory.make("autoaudiosrc", null);
            if (auto == null) throw new IOError.NOT_SUPPORTED(_("No audio input is available on this system"));
            return auto;
        }

        public void start(InputDevice input, int rate, int channels, string? target_path) throws Error {
            if (recording) return;
            this.rate = rate;
            this.channels = channels;
            var src = make_source(input, rate);
            var tail = Gst.parse_bin_from_description(
                "audioconvert ! audioresample ! audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d ! appsink name=sink sync=false emit-signals=true".printf(rate, channels), true);
            pipeline = new Gst.Pipeline("wave-recorder");
            pipeline.add_many(src, tail);
            var bin = (Gst.Bin) tail;
            if (!src.link(tail)) throw new IOError.FAILED(_("The audio input cannot be used"));
            appsink = (Gst.App.Sink) bin.get_by_name("sink");
            appsink.new_sample.connect(on_sample);
            writer = new SourceWriter(rate, channels, target_path);
            writer.keep = target_path != null;
            captured = 0;
            peaks = {};
            pipeline.get_bus().add_watch(Priority.DEFAULT, (b, msg) => {
                if (msg.type == Gst.MessageType.ERROR) {
                    Error e;
                    string d;
                    msg.parse_error(out e, out d);
                    abort();
                    failed(e.message);
                    return false;
                }
                return true;
            });
            if (pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                abort();
                throw new IOError.FAILED(_("The audio input cannot be opened"));
            }
            recording = true;
        }

        private Gst.FlowReturn on_sample(Gst.App.Sink sink) {
            var sample = sink.pull_sample();
            if (sample == null) return Gst.FlowReturn.EOS;
            var buffer = sample.get_buffer();
            Gst.MapInfo info;
            if (!buffer.map(out info, Gst.MapFlags.READ)) return Gst.FlowReturn.OK;
            int64 n = info.data.length / (4 * channels);
            float* data = (float*) info.data;
            float p = 0;
            for (int64 i = 0; i < n * channels; i++) p = float.max(p, Math.fabsf(data[i]));
            mutex.lock();
            if (writer != null) {
                int64 tl = start_frame + captured;
                int64 a = 0, b = n;
                if (punch_in >= 0 && tl + n <= punch_in) b = 0;
                else if (punch_in >= 0 && tl < punch_in) a = punch_in - tl;
                if (punch_out >= 0 && tl >= punch_out) b = 0;
                else if (punch_out >= 0 && tl + n > punch_out) b = int64.min(b, punch_out - tl);
                if (b > a) writer.write_ptr(data + a * channels, b - a);
            }
            captured += n;
            peaks += p;
            mutex.unlock();
            buffer.unmap(info);
            Idle.add(() => {
                level = p;
                peak(p);
                return Source.REMOVE;
            });
            return Gst.FlowReturn.OK;
        }

        public int64 timeline_start() {
            return punch_in >= 0 ? int64.max(punch_in, start_frame) : start_frame;
        }

        public void stop() {
            if (!recording) return;
            if (pipeline != null) pipeline.set_state(Gst.State.NULL);
            pipeline = null;
            recording = false;
            mutex.lock();
            var w = writer;
            writer = null;
            mutex.unlock();
            PcmSource? result = null;
            try {
                if (w != null && w.frames > 0) result = w.finish();
                else if (w != null) w.abort();
            } catch (Error e) {
                failed(e.message);
            }
            finished(result, timeline_start());
        }

        public void abort() {
            if (pipeline != null) pipeline.set_state(Gst.State.NULL);
            pipeline = null;
            recording = false;
            mutex.lock();
            if (writer != null) writer.abort();
            writer = null;
            mutex.unlock();
        }

        public void start_monitor(InputDevice input, int rate, int channels, int latency_samples) throws Error {
            stop_monitor();
            var src = make_source(input, rate);
            var p = new Gst.Pipeline("wave-monitor");
            var conv = Gst.ElementFactory.make("audioconvert", null);
            var res = Gst.ElementFactory.make("audioresample", null);
            var caps = Gst.ElementFactory.make("capsfilter", null);
            caps.set("caps", Gst.Caps.from_string("audio/x-raw,format=F32LE,layout=interleaved,rate=%d,channels=%d".printf(rate, channels)));
            var sink = AudioOutput.make_sink(latency_samples, rate);
            AudioOutput.tune(src, latency_samples, rate);
            p.add_many(src, conv, res, caps, sink);
            src.link_many(conv, res, caps, sink);
            if (p.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE) {
                p.set_state(Gst.State.NULL);
                throw new IOError.FAILED(_("Monitoring cannot start"));
            }
            monitor_pipeline = p;
            monitoring = true;
        }

        public int64 monitor_latency_ns() {
            if (monitor_pipeline == null) return -1;
            var q = new Gst.Query.latency();
            if (!monitor_pipeline.query(q)) return -1;
            bool live;
            Gst.ClockTime min, max;
            q.parse_latency(out live, out min, out max);
            return (int64) min;
        }

        public void stop_monitor() {
            if (monitor_pipeline != null) monitor_pipeline.set_state(Gst.State.NULL);
            monitor_pipeline = null;
            monitoring = false;
        }
    }
}
