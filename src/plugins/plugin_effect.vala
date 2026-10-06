namespace Singularity.Apps.Wave {

    public class PluginEffect : Effect {
        public const int MAX_BLOCK = 4096;

        public PluginInfo info { get; construct; }
        public bool isolated { get; set; default = true; }
        public string? load_error { get; private set; default = null; }
        public bool native_ui_visible { get; private set; default = false; }

        public bool has_native_ui {
            get {
                return info.has_native_ui;
            }
        }

        public signal void crashed(string message);

        private WavePlug.Instance? instance = null;
        private uint8[]? pending_state = null;
        private bool syncing = false;
        private uint ui_timer = 0;

        public override string title {
            owned get {
                return info.name;
            }
        }

        public PluginEffect(PluginInfo info, bool isolated) {
            Object(kind: info.kind, info: info);
            this.isolated = isolated;
            foreach (var p in info.parameters) {
                if (p.toggle) {
                    add_toggle(p.id, p.label, p.fallback >= 0.5);
                } else if (p.choices.length > 0) {
                    add_choice(p.id, p.label, p.choices, choice_index(p, p.fallback));
                } else {
                    var ep = add_param(p.id, p.label, p.min, p.max, p.fallback);
                    ep.logarithmic = p.logarithmic;
                }
            }
        }

        public static PluginEffect? create(string kind, bool isolated) {
            var catalog = PluginCatalog.get_default();
            if (!catalog.scanned) catalog.rescan();
            var info = catalog.find(kind);
            if (info == null) return null;
            return new PluginEffect(info, isolated);
        }

        ~PluginEffect() {
            if (ui_timer != 0) GLib.Source.remove(ui_timer);
        }

        private static int choice_index(PluginParamInfo p, double value) {
            int best = 0;
            double distance = double.MAX;
            for (int i = 0; i < p.choice_values.length; i++) {
                double d = Math.fabs(p.choice_values[i] - value);
                if (d < distance) {
                    distance = d;
                    best = i;
                }
            }
            return best;
        }

        private double to_plugin(int index) {
            var p = info.parameters[index];
            double v = parameters[index].value;
            if (p.toggle) return v >= 0.5 ? 1 : 0;
            if (p.choices.length > 0) return p.choice_values[((int) Math.round(v)).clamp(0, p.choice_values.length - 1)];
            if (p.integer) return Math.round(v);
            return v;
        }

        private double from_plugin(int index, double value) {
            var p = info.parameters[index];
            if (p.toggle) return value >= 0.5 ? 1 : 0;
            if (p.choices.length > 0) return choice_index(p, value);
            return value.clamp(p.min, p.max);
        }

        public void set_plugin_value(string id, double value) {
            for (int i = 0; i < info.parameters.size; i++) {
                if (info.parameters[i].id == id) {
                    parameters[i].value = from_plugin(i, value);
                    return;
                }
            }
        }

        public double get_plugin_value(string id) {
            for (int i = 0; i < info.parameters.size; i++) {
                if (info.parameters[i].id == id) return to_plugin(i);
            }
            return 0;
        }

        public override void prepare(int rate, int channels) {
            bool same = instance != null && this.rate == rate && this.channels == channels;
            this.rate = rate;
            this.channels = channels;
            if (!same) open_instance();
            base.prepare(rate, channels);
        }

        private void open_instance() {
            if (ui_timer != 0) {
                GLib.Source.remove(ui_timer);
                ui_timer = 0;
            }
            native_ui_visible = false;
            instance = null;
            string? error;
            instance = WavePlug.Instance.open(info.kind, info.path, rate, channels, MAX_BLOCK, isolated, out error);
            load_error = instance == null ? (error ?? _("The plugin could not be loaded")) : null;
            if (instance == null) {
                warning("Plugin %s: %s", info.name, load_error);
                return;
            }
            if (pending_state != null) {
                instance.load_state(pending_state);
                pending_state = null;
            }
        }

        protected override void update() {
            if (instance == null || syncing) return;
            for (int i = 0; i < parameters.size && i < info.parameters.size; i++) instance.set_param(i, to_plugin(i));
        }

        public override int latency() {
            return instance != null ? instance.latency() : 0;
        }

        public override void reset() {
        }

        public override void process(float[] buf, int frames) {
            if (instance == null) return;
            instance.process(buf, frames);
            string? crash = instance.take_crash();
            if (crash != null) {
                string message = crash;
                Idle.add(() => {
                    crashed(message);
                    return GLib.Source.REMOVE;
                });
            }
        }

        public bool restart() {
            if (instance == null) {
                open_instance();
                update();
                return instance != null;
            }
            string? error;
            return instance.restart(out error) == 0;
        }

        public int host_pid() {
            return instance != null ? instance.pid() : 0;
        }

        public uint8[]? save_state() {
            if (instance == null) return null;
            uint8[] data;
            if (instance.save_state(out data) != 0) return null;
            return data;
        }

        public bool load_state(uint8[] data) {
            if (instance == null) {
                pending_state = data;
                return true;
            }
            bool ok = instance.load_state(data) == 0;
            if (ok) sync_params();
            return ok;
        }

        public void sync_params() {
            if (instance == null) return;
            int n = info.parameters.size;
            var values = new double[n > 0 ? n : 1];
            int got = instance.sync_params(values, n);
            syncing = true;
            for (int i = 0; i < got && i < parameters.size; i++) {
                double v = from_plugin(i, values[i]);
                if (parameters[i].value != v) parameters[i].value = v;
            }
            syncing = false;
            native_ui_visible = instance.native_ui_visible();
        }

        public bool show_native_ui(bool show) {
            if (instance == null || !has_native_ui) return false;
            string? error;
            if (instance.show_native_ui(show, out error) != 0) {
                if (error != null) warning("Plugin %s: %s", info.name, error);
                return false;
            }
            native_ui_visible = show;
            if (show && ui_timer == 0) {
                ui_timer = Timeout.add(50, () => {
                    if (instance == null) {
                        ui_timer = 0;
                        return GLib.Source.REMOVE;
                    }
                    instance.idle();
                    sync_params();
                    if (!native_ui_visible) {
                        ui_timer = 0;
                        return GLib.Source.REMOVE;
                    }
                    return GLib.Source.CONTINUE;
                });
            } else if (!show && ui_timer != 0) {
                GLib.Source.remove(ui_timer);
                ui_timer = 0;
            }
            return true;
        }

        public override Json.Object to_json() {
            var o = base.to_json();
            o.set_boolean_member("isolated", isolated);
            o.set_string_member("path", info.path);
            var state = save_state();
            if (state != null && state.length > 0) o.set_string_member("state", Base64.encode((uchar[]) state));
            return o;
        }

        public override void load_json(Json.Object o) {
            base.load_json(o);
            if (o.has_member("state")) {
                var data = Base64.decode(o.get_string_member("state"));
                if (data.length > 0) load_state((uint8[]) data);
            }
        }
    }
}
