namespace Singularity.Apps.Wave {

    public class EffectRack : Object {
        public Gee.ArrayList<Effect> effects { get; default = new Gee.ArrayList<Effect>(); }
        public int rate { get; private set; }
        public int channels { get; private set; }
        public bool bypass { get; set; default = false; }
        public bool isolate_plugins { get; set; default = true; }

        public signal void changed();
        public signal void plugin_crashed(Effect effect, string message);

        private Mutex mutex;

        public EffectRack(int rate, int channels) {
            this.rate = rate;
            this.channels = channels;
        }

        public void configure(int rate, int channels) {
            mutex.lock();
            this.rate = rate;
            this.channels = channels;
            foreach (var e in effects) e.prepare(rate, channels);
            mutex.unlock();
        }

        private void watch(Effect e) {
            e.changed.connect(() => changed());
            e.notify["bypass"].connect(() => changed());
            var p = e as PluginEffect;
            if (p != null) p.crashed.connect((msg) => plugin_crashed(e, msg));
        }

        public void add(Effect e, int index = -1) {
            mutex.lock();
            e.prepare(rate, channels);
            if (index < 0 || index > effects.size) effects.add(e);
            else effects.insert(index, e);
            mutex.unlock();
            watch(e);
            changed();
        }

        public void remove(Effect e) {
            mutex.lock();
            effects.remove(e);
            mutex.unlock();
            changed();
        }

        public void move(Effect e, int index) {
            mutex.lock();
            effects.remove(e);
            effects.insert(index.clamp(0, effects.size), e);
            mutex.unlock();
            changed();
        }

        public void clear() {
            mutex.lock();
            effects.clear();
            mutex.unlock();
            changed();
        }

        public bool has_realtime() {
            foreach (var e in effects) {
                if (!e.bypass && !e.offline_only()) return true;
            }
            return false;
        }

        public bool has_offline() {
            foreach (var e in effects) {
                if (!e.bypass && e.offline_only()) return true;
            }
            return false;
        }

        public void reset() {
            mutex.lock();
            foreach (var e in effects) e.reset();
            mutex.unlock();
        }

        public int latency() {
            int total = 0;
            foreach (var e in effects) {
                if (!e.bypass) total += e.latency();
            }
            return total;
        }

        public void process(float[] buf, int frames) {
            if (bypass) return;
            mutex.lock();
            foreach (var e in effects) {
                if (!e.offline_only()) e.run(buf, frames);
            }
            mutex.unlock();
        }

        public void process_offline(float[] buf, int frames) {
            if (bypass) return;
            mutex.lock();
            foreach (var e in effects) {
                if (e.offline_only()) e.run(buf, frames);
            }
            mutex.unlock();
        }

        public void process_all(float[] buf, int64 frames) {
            mutex.lock();
            foreach (var e in effects) e.reset();
            mutex.unlock();
            process_offline(buf, (int) frames);
            int block = 4096;
            var tmp = new float[block * channels];
            int lat = latency();
            int64 total = frames + lat;
            var out_buf = lat > 0 ? new float[total * channels] : buf;
            for (int64 pos = 0; pos < total; pos += block) {
                int n = (int) int64.min(block, total - pos);
                for (int i = 0; i < n * channels; i++) {
                    int64 idx = pos * channels + i;
                    tmp[i] = idx < frames * channels ? buf[idx] : 0;
                }
                process(tmp, n);
                for (int i = 0; i < n * channels; i++) out_buf[pos * channels + i] = tmp[i];
            }
            if (lat > 0) {
                for (int64 i = 0; i < frames * channels; i++) buf[i] = out_buf[i + (int64) lat * channels];
            }
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_boolean_member("bypass", bypass);
            var a = new Json.Array();
            foreach (var e in effects) a.add_object_element(e.to_json());
            o.set_array_member("effects", a);
            return o;
        }

        public void load_json(Json.Object? o) {
            mutex.lock();
            effects.clear();
            mutex.unlock();
            if (o == null) {
                changed();
                return;
            }
            bypass = o.get_boolean_member_with_default("bypass", false);
            if (o.has_member("effects")) {
                foreach (var n in o.get_array_member("effects").get_elements()) {
                    var e = EffectRegistry.from_json(n.get_object(), isolate_plugins);
                    if (e == null) continue;
                    e.prepare(rate, channels);
                    mutex.lock();
                    effects.add(e);
                    mutex.unlock();
                    watch(e);
                }
            }
            changed();
        }

        public EffectRack copy() {
            var r = new EffectRack(rate, channels);
            r.isolate_plugins = isolate_plugins;
            r.load_json(to_json());
            return r;
        }
    }

    namespace Presets {
        public string dir(string group) {
            string d = Path.build_filename(Environment.get_user_data_dir(), "singularity-wave", "presets", group.replace(":", "_").replace("/", "_"));
            DirUtils.create_with_parents(d, 0700);
            return d;
        }

        public Gee.List<string> list(string group) {
            var names = new Gee.ArrayList<string>();
            try {
                var d = Dir.open(dir(group));
                string? name;
                while ((name = d.read_name()) != null) {
                    if (name.has_suffix(".json")) names.add(name.substring(0, name.length - 5));
                }
            } catch (Error e) {
            }
            names.sort();
            return names;
        }

        public void save(string group, string name, Json.Object o) throws Error {
            var root = new Json.Node(Json.NodeType.OBJECT);
            root.set_object(o);
            var gen = new Json.Generator();
            gen.pretty = true;
            gen.root = root;
            gen.to_file(Path.build_filename(dir(group), name.replace("/", "-") + ".json"));
        }

        public Json.Object? load(string group, string name) {
            try {
                var p = new Json.Parser();
                p.load_from_file(Path.build_filename(dir(group), name + ".json"));
                return p.get_root().get_object();
            } catch (Error e) {
                return null;
            }
        }

        public void remove(string group, string name) {
            FileUtils.unlink(Path.build_filename(dir(group), name + ".json"));
        }

        public Json.Object? factory_rack(string name) {
            var o = new Json.Object();
            var a = new Json.Array();
            switch (name) {
            case "voice":
                a.add_object_element(fx("eq", { "b0_on", "1", "b0_type", "3", "b0_freq", "80", "b1_on", "1", "b1_type", "0", "b1_freq", "250", "b1_gain", "-2", "b1_q", "1", "b4_on", "1", "b4_freq", "3500", "b4_gain", "2.5", "b4_q", "0.8" }));
                a.add_object_element(fx("deesser", { "threshold", "-30" }));
                a.add_object_element(fx("compressor", { "threshold", "-22", "ratio", "3", "attack", "8", "release", "120", "makeup", "4" }));
                break;
            case "podcast-master":
                a.add_object_element(fx("compressor", { "threshold", "-18", "ratio", "2", "attack", "20", "release", "200", "makeup", "2" }));
                a.add_object_element(fx("limiter", { "threshold", "-1", "true_peak", "1" }));
                break;
            case "telephone":
                a.add_object_element(fx("eq", { "b0_on", "1", "b0_type", "3", "b0_freq", "400", "b7_on", "1", "b7_type", "4", "b7_freq", "3200" }));
                a.add_object_element(fx("saturation", { "drive", "8" }));
                break;
            case "music-bed":
                a.add_object_element(fx("eq", { "b3_on", "1", "b3_freq", "2500", "b3_gain", "-3", "b3_q", "0.7" }));
                break;
            default:
                return null;
            }
            o.set_array_member("effects", a);
            return o;
        }

        private Json.Object fx(string kind, string[] kv) {
            var o = new Json.Object();
            o.set_string_member("kind", kind);
            var p = new Json.Object();
            for (int i = 0; i + 1 < kv.length; i += 2) p.set_double_member(kv[i], double.parse(kv[i + 1]));
            o.set_object_member("params", p);
            return o;
        }
    }
}
