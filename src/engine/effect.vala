namespace Singularity.Apps.Wave {

    public class EffectParam : Object {
        public string id { get; construct; }
        public string label { get; construct; }
        public double min { get; construct; }
        public double max { get; construct; }
        public double fallback { get; construct; }
        public string unit { get; set; default = ""; }
        public bool toggle { get; set; default = false; }
        public bool logarithmic { get; set; default = false; }
        public string[] choices { get; set; default = {}; }
        public double value { get; set; }

        public EffectParam(string id, string label, double min, double max, double fallback) {
            Object(id: id, label: label, min: min, max: max, fallback: fallback);
            value = fallback;
        }

        public string format_value(double v) {
            if (toggle) return v >= 0.5 ? _("On") : _("Off");
            if (choices.length > 0) {
                int i = ((int) Math.round(v)).clamp(0, choices.length - 1);
                return choices[i];
            }
            double a = Math.fabs(v);
            string text = a >= 1000 ? "%.0f".printf(v) : a >= 100 ? "%.0f".printf(v) : a >= 10 ? "%.1f".printf(v) : "%.2f".printf(v);
            return unit == "" ? text : "%s %s".printf(text, unit);
        }
    }

    public abstract class Effect : Object {
        public string kind { get; construct; }
        public bool bypass { get; set; default = false; }
        public int rate { get; protected set; default = 48000; }
        public int channels { get; protected set; default = 2; }
        public Gee.ArrayList<EffectParam> parameters { get; default = new Gee.ArrayList<EffectParam>(); }

        public signal void changed();

        public abstract string title { owned get; }

        protected EffectParam add_param(string id, string label, double min, double max, double fallback, string unit = "") {
            var p = new EffectParam(id, label, min, max, fallback);
            p.unit = unit;
            parameters.add(p);
            p.notify["value"].connect(() => {
                update();
                changed();
            });
            return p;
        }

        protected EffectParam add_toggle(string id, string label, bool fallback) {
            var p = add_param(id, label, 0, 1, fallback ? 1 : 0);
            p.toggle = true;
            return p;
        }

        protected EffectParam add_choice(string id, string label, string[] choices, int fallback) {
            var p = add_param(id, label, 0, choices.length - 1, fallback);
            p.choices = choices;
            return p;
        }

        public EffectParam? find(string id) {
            foreach (var p in parameters) {
                if (p.id == id) return p;
            }
            return null;
        }

        public double get_value(string id) {
            var p = find(id);
            return p != null ? p.value : 0;
        }

        public void set_value(string id, double v) {
            var p = find(id);
            if (p != null && p.value != v) p.value = v.clamp(p.min, p.max);
        }

        public virtual void prepare(int rate, int channels) {
            this.rate = rate;
            this.channels = channels;
            update();
        }

        protected virtual void update() {
        }

        public virtual void reset() {
        }

        public virtual int latency() {
            return 0;
        }

        public virtual bool offline_only() {
            return false;
        }

        public abstract void process(float[] buf, int frames);

        public void run(float[] buf, int frames) {
            if (bypass || frames <= 0) return;
            process(buf, frames);
        }

        public virtual Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("kind", kind);
            o.set_boolean_member("bypass", bypass);
            var values = new Json.Object();
            foreach (var p in parameters) values.set_double_member(p.id, p.value);
            o.set_object_member("params", values);
            return o;
        }

        public virtual void load_json(Json.Object o) {
            if (o.has_member("bypass")) bypass = o.get_boolean_member("bypass");
            if (!o.has_member("params")) return;
            var values = o.get_object_member("params");
            foreach (var p in parameters) {
                if (values.has_member(p.id)) p.value = values.get_double_member(p.id).clamp(p.min, p.max);
            }
        }
    }
}
