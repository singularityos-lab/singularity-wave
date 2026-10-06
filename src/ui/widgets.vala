using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    namespace Paint {
        public Gdk.RGBA fg(Widget w) {
            return w.get_color();
        }

        public void set(Cairo.Context cr, Gdk.RGBA c, double alpha = 1) {
            cr.set_source_rgba(c.red, c.green, c.blue, c.alpha * alpha);
        }

        public void accent(Cairo.Context cr, double alpha = 1) {
            hex(cr, Singularity.Style.StyleManager.get_default().accent_hex, alpha);
        }

        private Gtk.Label? probe = null;

        public Gdk.RGBA token(string name) {
            if (probe == null) probe = new Gtk.Label("");
            Gdk.RGBA c;
            if (!probe.get_style_context().lookup_color(name, out c)) {
                c = Gdk.RGBA();
                c.parse(name == "success_color" ? "#2ec27e" : name == "error_color" ? "#e01b24" : "#e5a50a");
            }
            return c;
        }

        public void semantic(Cairo.Context cr, string name, double alpha = 1) {
            var c = token(name);
            cr.set_source_rgba(c.red, c.green, c.blue, c.alpha * alpha);
        }

        public void hex(Cairo.Context cr, string color, double alpha = 1) {
            var c = Gdk.RGBA();
            if (!c.parse(color)) c.parse("#3584e4");
            cr.set_source_rgba(c.red, c.green, c.blue, alpha);
        }

        public void rounded(Cairo.Context cr, double x, double y, double w, double h, double r) {
            r = double.min(r, double.min(w, h) / 2);
            cr.new_sub_path();
            cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
            cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
            cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
            cr.arc(x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
            cr.close_path();
        }

        public void text(Cairo.Context cr, Widget w, string s, double x, double y, double size = 11, bool bold = false) {
            var layout = w.create_pango_layout(s);
            var fd = new Pango.FontDescription();
            fd.set_size((int) (size * Pango.SCALE));
            if (bold) fd.set_weight(Pango.Weight.BOLD);
            layout.set_font_description(fd);
            cr.move_to(x, y);
            Pango.cairo_show_layout(cr, layout);
        }

        public double text_width(Widget w, string s, double size = 11) {
            var layout = w.create_pango_layout(s);
            var fd = new Pango.FontDescription();
            fd.set_size((int) (size * Pango.SCALE));
            layout.set_font_description(fd);
            int pw, ph;
            layout.get_pixel_size(out pw, out ph);
            return pw;
        }

        public double db_to_meter(double db) {
            if (!db.is_finite() || db < -60) return 0;
            return Math.pow((db + 60) / 60, 2);
        }
    }

    public class LevelMeter : DrawingArea {
        public float[] peaks = new float[2];
        public float[] holds = new float[2];
        public bool vertical { get; set; default = false; }

        public LevelMeter(bool vertical) {
            this.vertical = vertical;
            if (vertical) set_size_request(14, 120);
            else set_size_request(160, 14);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Level meter"), -1);
        }

        public void set_levels(float[] p, int n) {
            if (peaks.length != n) {
                peaks = new float[n];
                holds = new float[n];
            }
            for (int i = 0; i < n; i++) {
                peaks[i] = p[i];
                holds[i] = float.max(holds[i] * 0.97f, p[i]);
            }
            queue_draw();
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            int n = int.max(1, peaks.length);
            Paint.set(cr, Paint.fg(this), 0.08);
            Paint.rounded(cr, 0, 0, w, h, 3);
            cr.fill();
            for (int i = 0; i < n; i++) {
                double db = peaks[i] > 0 ? 20 * Math.log10(peaks[i]) : -100;
                double v = Paint.db_to_meter(db);
                double hold = Paint.db_to_meter(holds[i] > 0 ? 20 * Math.log10(holds[i]) : -100);
                if (vertical) {
                    double bw = (w - (n - 1)) / (double) n;
                    double x = i * (bw + 1);
                    gradient(cr, x, h * (1 - v), bw, h * v, h, true);
                    Paint.set(cr, Paint.fg(this), 0.8);
                    cr.rectangle(x, h * (1 - hold), bw, 1.5);
                    cr.fill();
                } else {
                    double bh = (h - (n - 1)) / (double) n;
                    double y = i * (bh + 1);
                    gradient(cr, 0, y, w * v, bh, w, false);
                    Paint.set(cr, Paint.fg(this), 0.8);
                    cr.rectangle(w * hold, y, 1.5, bh);
                    cr.fill();
                }
            }
        }

        private void gradient(Cairo.Context cr, double x, double y, double w, double h, double full, bool vertical) {
            if (w <= 0 || h <= 0) return;
            Cairo.Pattern g = vertical ? new Cairo.Pattern.linear(0, full, 0, 0) : new Cairo.Pattern.linear(0, 0, full, 0);
            var ok = Paint.token("success_color");
            var warn = Paint.token("warning_color");
            var hot = Paint.token("error_color");
            g.add_color_stop_rgb(0, ok.red, ok.green, ok.blue);
            g.add_color_stop_rgb(Paint.db_to_meter(-18), ok.red, ok.green, ok.blue);
            g.add_color_stop_rgb(Paint.db_to_meter(-6), warn.red, warn.green, warn.blue);
            g.add_color_stop_rgb(Paint.db_to_meter(-1), hot.red, hot.green, hot.blue);
            g.add_color_stop_rgb(1, hot.red, hot.green, hot.blue);
            cr.set_source(g);
            cr.rectangle(x, y, w, h);
            cr.fill();
        }
    }

    public class LoudnessGauge : DrawingArea {
        public double momentary = -double.INFINITY;
        public double short_term = -double.INFINITY;
        public double integrated = -double.INFINITY;
        public double target = -16;

        public LoudnessGauge() {
            set_size_request(220, 220);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Loudness radar"), -1);
        }

        public void update(double m, double s, double i) {
            momentary = m;
            short_term = s;
            integrated = i;
            queue_draw();
        }

        private double angle(double lufs) {
            double t = ((lufs - (target - 18)) / 36).clamp(0, 1);
            return Math.PI * 0.75 + t * Math.PI * 1.5;
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            double cx = w / 2.0, cy = h / 2.0;
            double r = double.min(w, h) / 2.0 - 12;
            var fg = Paint.fg(this);
            cr.set_line_width(14);
            Paint.set(cr, fg, 0.08);
            cr.arc(cx, cy, r, Math.PI * 0.75, Math.PI * 2.25);
            cr.stroke();
            Paint.semantic(cr, "success_color", 0.35);
            cr.arc(cx, cy, r, angle(target - 1), angle(target + 1));
            cr.stroke();
            if (short_term.is_finite()) {
                Paint.accent(cr, 0.85);
                cr.arc(cx, cy, r, Math.PI * 0.75, angle(short_term));
                cr.stroke();
            }
            cr.set_line_width(4);
            if (momentary.is_finite()) {
                Paint.set(cr, fg, 0.7);
                cr.arc(cx, cy, r - 14, Math.PI * 0.75, angle(momentary));
                cr.stroke();
            }
            string big = integrated.is_finite() ? "%.1f".printf(integrated) : "--";
            double bw = Paint.text_width(this, big, 26);
            Paint.set(cr, fg, 1);
            Paint.text(cr, this, big, cx - bw / 2, cy - 22, 26, true);
            string unit = _("LUFS integrated");
            Paint.set(cr, fg, 0.6);
            Paint.text(cr, this, unit, cx - Paint.text_width(this, unit, 9) / 2, cy + 14, 9);
            string tgt = _("Target %.0f").printf(target);
            Paint.text(cr, this, tgt, cx - Paint.text_width(this, tgt, 9) / 2, cy + 30, 9);
        }
    }

    public class Vectorscope : DrawingArea {
        public float[] points = new float[0];
        public int count = 0;
        public float correlation = 1;

        public Vectorscope() {
            set_size_request(200, 220);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Stereo vectorscope and phase correlation"), -1);
        }

        public void update(float[] scope, int n, float corr) {
            if (points.length < n * 2) points = new float[n * 2];
            for (int i = 0; i < n * 2; i++) points[i] = scope[i];
            count = n;
            correlation = corr;
            queue_draw();
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            double size = double.min(w, h - 26);
            double cx = w / 2.0, cy = size / 2.0;
            double r = size / 2.0 - 6;
            Paint.set(cr, fg, 0.08);
            cr.arc(cx, cy, r, 0, 2 * Math.PI);
            cr.fill();
            Paint.set(cr, fg, 0.2);
            cr.set_line_width(1);
            cr.move_to(cx, cy - r);
            cr.line_to(cx, cy + r);
            cr.move_to(cx - r, cy);
            cr.line_to(cx + r, cy);
            cr.stroke();
            Paint.text(cr, this, "L", cx - r * 0.75, cy - r * 0.8, 9);
            Paint.text(cr, this, "R", cx + r * 0.65, cy - r * 0.8, 9);
            Paint.accent(cr, 0.5);
            for (int i = 0; i < count; i++) {
                double l = points[i * 2], rr = points[i * 2 + 1];
                double m = (l + rr) * 0.7071, s = (rr - l) * 0.7071;
                cr.rectangle(cx + s * r, cy - m * r, 1.2, 1.2);
            }
            cr.fill();
            double by = size + 6;
            Paint.set(cr, fg, 0.1);
            Paint.rounded(cr, 10, by, w - 20, 8, 4);
            cr.fill();
            double x = 10 + (w - 20) * (correlation + 1) / 2;
            if (correlation < 0) Paint.semantic(cr, "error_color");
            else Paint.semantic(cr, "success_color");
            cr.arc(x, by + 4, 6, 0, 2 * Math.PI);
            cr.fill();
            Paint.set(cr, fg, 0.6);
            Paint.text(cr, this, "-1", 6, by + 10, 8);
            Paint.text(cr, this, "+1", w - 20, by + 10, 8);
        }
    }

    public class SpectrumPlot : DrawingArea {
        public float[] db = new float[0];
        public float[]? overlay = null;
        public int rate = 48000;
        public double floor_db = -96;

        public SpectrumPlot() {
            set_size_request(200, 160);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Frequency analysis"), -1);
        }

        public static double x_for(double hz, double w) {
            return w * Math.log(double.max(hz, 20) / 20) / Math.log(1000);
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.05);
            Paint.rounded(cr, 0, 0, w, h, 6);
            cr.fill();
            Paint.set(cr, fg, 0.15);
            cr.set_line_width(1);
            foreach (double f in new double[] { 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) {
                double x = x_for(f, w);
                cr.move_to(x, 0);
                cr.line_to(x, h);
            }
            for (double d = 0; d >= floor_db; d -= 12) {
                double y = h * (-d / -floor_db);
                cr.move_to(0, y);
                cr.line_to(w, y);
            }
            cr.stroke();
            Paint.set(cr, fg, 0.55);
            Paint.text(cr, this, "100", x_for(100, w) + 2, h - 14, 8);
            Paint.text(cr, this, "1k", x_for(1000, w) + 2, h - 14, 8);
            Paint.text(cr, this, "10k", x_for(10000, w) + 2, h - 14, 8);
            plot(cr, db, w, h, true);
            if (overlay != null) {
                Paint.semantic(cr, "warning_color", 0.9);
                plot(cr, overlay, w, h, false);
            }
        }

        private void plot(Cairo.Context cr, float[] data, int w, int h, bool fill) {
            if (data.length < 2) return;
            int bins = data.length;
            bool first = true;
            for (int b = 1; b < bins; b++) {
                double hz = (double) b * rate / 2 / (bins - 1);
                if (hz < 20) continue;
                double x = x_for(hz, w);
                double y = h * (double.min(0, data[b]) / floor_db).clamp(0, 1);
                if (first) cr.move_to(x, y);
                else cr.line_to(x, y);
                first = false;
            }
            if (fill) {
                Paint.accent(cr, 0.9);
                cr.set_line_width(1.5);
                cr.stroke_preserve();
                cr.line_to(w, h);
                cr.line_to(0, h);
                Paint.accent(cr, 0.15);
                cr.fill();
            } else {
                cr.set_line_width(1.5);
                cr.stroke();
            }
        }
    }

    public class EqGraph : DrawingArea {
        public static LiveMeter? analyzer = null;
        public EqEffect eq;
        private int drag = -1;

        public EqGraph(EqEffect eq) {
            this.eq = eq;
            set_size_request(200, 150);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Equalizer curve"), -1);
            eq.changed.connect(() => queue_draw());
            add_tick_callback(() => {
                if (analyzer != null && analyzer.has_spectrum) queue_draw();
                return GLib.Source.CONTINUE;
            });
            if (!eq.graphic) {
                var g = new GestureDrag();
                g.drag_begin.connect((x, y) => {
                    drag = nearest(x, y);
                    if (drag >= 0) eq.set_value("b%d_on".printf(drag), 1);
                });
                g.drag_update.connect((dx, dy) => {
                    if (drag < 0) return;
                    double sx, sy;
                    g.get_start_point(out sx, out sy);
                    move_band(drag, sx + dx, sy + dy);
                });
                g.drag_end.connect(() => drag = -1);
                add_controller(g);
            }
        }

        private double freq_x(double f, int w) {
            return SpectrumPlot.x_for(f, w);
        }

        private double x_freq(double x, int w) {
            return 20 * Math.pow(1000, (x / w).clamp(0, 1));
        }

        private int nearest(double x, double y) {
            int w = get_width(), h = get_height();
            int best = -1;
            double bd = 30;
            for (int i = 0; i < eq.bands; i++) {
                double bx = freq_x(eq.get_value("b%d_freq".printf(i)), w);
                double by = h / 2.0 - eq.get_value("b%d_gain".printf(i)) / 24 * h / 2;
                double d = Math.hypot(bx - x, by - y);
                if (d < bd) {
                    bd = d;
                    best = i;
                }
            }
            return best;
        }

        private void move_band(int i, double x, double y) {
            int w = get_width(), h = get_height();
            eq.set_value("b%d_freq".printf(i), x_freq(x, w));
            int t = (int) eq.get_value("b%d_type".printf(i));
            if (t <= 2) eq.set_value("b%d_gain".printf(i), ((h / 2.0 - y) / (h / 2.0) * 24).clamp(-24, 24));
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.05);
            Paint.rounded(cr, 0, 0, w, h, 6);
            cr.fill();
            Paint.set(cr, fg, 0.15);
            cr.set_line_width(1);
            foreach (double f in new double[] { 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) {
                cr.move_to(freq_x(f, w), 0);
                cr.line_to(freq_x(f, w), h);
            }
            foreach (double d in new double[] { -12, 0, 12 }) {
                cr.move_to(0, h / 2.0 - d / 24 * h / 2);
                cr.line_to(w, h / 2.0 - d / 24 * h / 2);
            }
            cr.stroke();
            if (analyzer != null && analyzer.has_spectrum) {
                Paint.set(cr, fg, 0.25);
                int bins = analyzer.spectrum.length;
                for (int b = 1; b < bins; b++) {
                    double hz = (double) b * analyzer.rate / 2 / (bins - 1);
                    if (hz < 20) continue;
                    double x = freq_x(hz, w);
                    double y = h * ((-analyzer.spectrum[b]) / 96.0).clamp(0, 1);
                    if (b == 1) cr.move_to(x, h);
                    cr.line_to(x, y);
                }
                cr.line_to(w, h);
                cr.close_path();
                cr.fill();
            }
            int n = int.max(2, w);
            var freqs = new float[n];
            for (int i = 0; i < n; i++) freqs[i] = (float) x_freq(i, w);
            var db = eq.response(freqs);
            for (int i = 0; i < n; i++) {
                double y = h / 2.0 - (db[i] / 24.0).clamp(-1, 1) * h / 2;
                if (i == 0) cr.move_to(i, y);
                else cr.line_to(i, y);
            }
            Paint.accent(cr);
            cr.set_line_width(2);
            cr.stroke_preserve();
            cr.line_to(w, h / 2.0);
            cr.line_to(0, h / 2.0);
            Paint.accent(cr, 0.12);
            cr.fill();
            if (eq.graphic) return;
            for (int i = 0; i < eq.bands; i++) {
                if (eq.get_value("b%d_on".printf(i)) < 0.5) continue;
                double bx = freq_x(eq.get_value("b%d_freq".printf(i)), w);
                int t = (int) eq.get_value("b%d_type".printf(i));
                double by = t <= 2 ? h / 2.0 - eq.get_value("b%d_gain".printf(i)) / 24 * h / 2 : h / 2.0;
                Paint.accent(cr);
                cr.arc(bx, by, 7, 0, 2 * Math.PI);
                cr.fill();
                cr.set_source_rgb(1, 1, 1);
                Paint.text(cr, this, (i + 1).to_string(), bx - 3, by - 7, 8, true);
            }
        }
    }

    public class DynamicsGraph : DrawingArea {
        public DynamicsEffect fx;

        public DynamicsGraph(DynamicsEffect fx) {
            this.fx = fx;
            set_size_request(150, 150);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Transfer curve and gain reduction"), -1);
            fx.changed.connect(() => queue_draw());
            add_tick_callback(() => {
                queue_draw();
                return GLib.Source.CONTINUE;
            });
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            int side = int.min(w - 22, h);
            Paint.set(cr, fg, 0.05);
            Paint.rounded(cr, 0, 0, side, side, 6);
            cr.fill();
            Paint.set(cr, fg, 0.2);
            cr.set_line_width(1);
            cr.move_to(0, side);
            cr.line_to(side, 0);
            cr.stroke();
            for (int i = 0; i <= side; i++) {
                double in_db = -72 + 72.0 * i / side;
                double out_db = fx.curve((float) in_db);
                double y = side - (out_db + 72) / 72 * side;
                if (i == 0) cr.move_to(i, y);
                else cr.line_to(i, y);
            }
            Paint.accent(cr);
            cr.set_line_width(2);
            cr.stroke();
            double gr = (fx.last_reduction / 24.0).clamp(0, 1);
            Paint.set(cr, fg, 0.08);
            cr.rectangle(side + 8, 0, 12, side);
            cr.fill();
            Paint.semantic(cr, "warning_color");
            cr.rectangle(side + 8, 0, 12, side * gr);
            cr.fill();
        }
    }

    public class ParamRow : Box {
        public EffectParam param;
        private Scale? scale = null;
        private Switch? sw = null;
        private CompactMenu? drop = null;
        private Label value_label;
        private bool syncing = false;

        public signal void touched(bool active);

        public ParamRow(EffectParam p) {
            Object(orientation: Orientation.VERTICAL, spacing: 2);
            param = p;
            margin_start = 12;
            margin_end = 12;
            var top = new Box(Orientation.HORIZONTAL, 6);
            var name = new Label(p.label);
            name.halign = Align.START;
            name.hexpand = true;
            name.add_css_class("caption");
            top.append(name);
            value_label = new Label("");
            value_label.add_css_class("caption");
            value_label.add_css_class("dim-label");
            value_label.add_css_class("numeric");
            top.append(value_label);
            append(top);
            if (p.toggle) {
                sw = new Switch();
                sw.halign = Align.END;
                sw.valign = Align.CENTER;
                sw.active = p.value >= 0.5;
                sw.notify["active"].connect(() => {
                    if (!syncing) p.value = sw.active ? 1 : 0;
                });
                top.append(sw);
                value_label.visible = false;
            } else if (p.choices.length > 0) {
                drop = new CompactMenu(p.label, p.choices, (int) p.value);
                drop.valign = Align.CENTER;
                drop.changed.connect((i) => {
                    if (!syncing) p.value = i;
                });
                top.append(drop);
                value_label.visible = false;
            } else {
                scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 1, 0.001);
                scale.draw_value = false;
                scale.hexpand = true;
                scale.set_value(to_pos(p.value));
                scale.value_changed.connect(() => {
                    if (!syncing) p.value = from_pos(scale.get_value());
                });
                scale.update_property(AccessibleProperty.LABEL, p.label, -1);
                var click = new GestureClick();
                click.button = 1;
                click.pressed.connect(() => touched(true));
                click.released.connect(() => touched(false));
                click.propagation_phase = PropagationPhase.CAPTURE;
                scale.add_controller(click);
                var dbl = new GestureClick();
                dbl.pressed.connect((n, x, y) => {
                    if (n == 2) p.value = p.fallback;
                });
                scale.add_controller(dbl);
                append(scale);
            }
            p.notify["value"].connect(sync);
            sync();
        }

        private double to_pos(double v) {
            if (param.logarithmic && param.min > 0) return Math.log(v / param.min) / Math.log(param.max / param.min);
            return (v - param.min) / (param.max - param.min);
        }

        private double from_pos(double t) {
            if (param.logarithmic && param.min > 0) return param.min * Math.pow(param.max / param.min, t);
            return param.min + t * (param.max - param.min);
        }

        private void sync() {
            syncing = true;
            value_label.label = param.format_value(param.value);
            if (scale != null && Math.fabs(from_pos(scale.get_value()) - param.value) > (param.max - param.min) * 1e-4) scale.set_value(to_pos(param.value));
            if (sw != null) sw.active = param.value >= 0.5;
            if (drop != null) drop.select((int) Math.round(param.value));
            syncing = false;
        }
    }

    public class EffectEditor : Box {
        public Effect effect;

        public EffectEditor(Effect e) {
            Object(orientation: Orientation.VERTICAL, spacing: 8);
            effect = e;
            margin_bottom = 6;
            var eq = e as EqEffect;
            var dyn = e as DynamicsEffect;
            if (eq != null) {
                var g = new EqGraph(eq);
                g.margin_start = 12;
                g.margin_end = 12;
                append(g);
            } else if (dyn != null) {
                var g = new DynamicsGraph(dyn);
                g.margin_start = 12;
                g.halign = Align.START;
                append(g);
            }
            var plug = e as PluginEffect;
            if (plug != null && plug.has_native_ui) {
                var b = new Button.with_label(_("Show Plugin Window"));
                b.halign = Align.START;
                b.margin_start = 12;
                b.clicked.connect(() => plug.show_native_ui(true));
                append(b);
            }
            if (eq != null && !eq.graphic) {
                var stack = new Stack();
                stack.vhomogeneous = false;
                string[] names = {};
                for (int i = 0; i < eq.bands; i++) {
                    var box = new Box(Orientation.VERTICAL, 4);
                    for (int k = i * 5; k < i * 5 + 5; k++) box.append(new ParamRow(e.parameters[k]));
                    stack.add_named(box, i.to_string());
                    names += _("Band %d").printf(i + 1);
                }
                var bands = new ChoiceRow(_("Band"), names, 0);
                bands.notify["index"].connect(() => stack.visible_child_name = bands.index.to_string());
                var band_list = new ListBox();
                band_list.selection_mode = SelectionMode.NONE;
                band_list.add_css_class("preferences-list");
                band_list.append(bands);
                append(band_list);
                append(stack);
                append(new ParamRow(e.find("output")));
                return;
            }
            var flow = new FlowBox();
            flow.selection_mode = SelectionMode.NONE;
            flow.max_children_per_line = e.parameters.size > 12 ? 2 : 1;
            flow.homogeneous = true;
            foreach (var p in e.parameters) flow.append(new ParamRow(p));
            append(flow);
        }
    }
}
