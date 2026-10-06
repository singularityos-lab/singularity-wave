using Gtk;

namespace Singularity.Apps.Wave {

    public enum ViewMode {
        WAVEFORM,
        SPECTRAL,
        SPLIT
    }

    public enum SpectralTool {
        TIME,
        RECTANGLE,
        LASSO,
        BRUSH
    }

    public class SpectralSelection {
        public Cairo.ImageSurface mask;
        public int64 scroll;
        public double fpp;
        public int top;
        public int height;
        public int scale;
        public int rate;
        public int64 first_frame = int64.MAX;
        public int64 last_frame = 0;

        public double y_for(double hz) {
            return top + WaveformView.freq_to_unit(hz, rate, scale) * height;
        }

        public float weight(int64 frame, double hz) {
            int x = (int) ((frame - scroll) / fpp);
            int y = (int) y_for(hz);
            if (x < 0 || y < 0 || x >= mask.get_width() || y >= mask.get_height()) return 0;
            mask.flush();
            unowned uchar[] data = mask.get_data();
            return data[y * mask.get_stride() + x] / 255.0f;
        }
    }

    public class WaveformView : DrawingArea {
        public const int RULER = 24;

        public Document? doc { get; private set; }
        public double fpp { get; set; default = 256; }
        public int64 scroll { get; set; default = 0; }
        public int64 sel_a { get; private set; default = 0; }
        public int64 sel_b { get; private set; default = 0; }
        public int64 cursor { get; set; default = 0; }
        public int64 playhead { get; set; default = -1; }
        public ViewMode mode { get; set; default = ViewMode.WAVEFORM; }
        public SpectralTool tool { get; set; default = SpectralTool.TIME; }
        public bool snap_zero { get; set; default = true; }
        public int fft_size { get; set; default = 2048; }
        public int freq_scale { get; set; default = 0; }
        public double brush_size { get; set; default = 18; }
        public int fade_curve { get; set; default = 2; }
        public SpectralSelection? spectral_sel = null;

        public signal void selection_changed();
        public signal void view_changed();
        public signal void cursor_moved(int64 frame);
        public signal void fade_applied(bool fade_in, int64 frames, int curve);
        public signal void marker_activated(Marker m);

        private GestureDrag drag_gesture;
        private double drag_x0 = 0;
        private double drag_y0 = 0;
        private int64 drag_anchor = 0;
        private int drag_kind = 0;
        private Marker? drag_marker = null;
        private int64 fade_preview = 0;
        private Gee.ArrayList<double?> lasso = new Gee.ArrayList<double?>();
        private Gdk.Texture? spec_tex = null;
        private string spec_key = "";
        private bool spec_busy = false;
        private uint spec_timer = 0;

        public WaveformView() {
            set_draw_func(draw);
            hexpand = true;
            vexpand = true;
            focusable = true;
            update_property(AccessibleProperty.LABEL, _("Waveform editor"), -1);
            var drag = new GestureDrag();
            drag_gesture = drag;
            drag.drag_begin.connect(on_drag_begin);
            drag.drag_update.connect(on_drag_update);
            drag.drag_end.connect(on_drag_end);
            add_controller(drag);
            var scroll_ctl = new EventControllerScroll(EventControllerScrollFlags.BOTH_AXES);
            scroll_ctl.scroll.connect(on_scroll);
            add_controller(scroll_ctl);
            var dbl = new GestureClick();
            dbl.pressed.connect((n, x, y) => {
                grab_focus();
                if (n == 2 && doc != null) {
                    var m = marker_at(x, y);
                    if (m != null) {
                        set_selection(m.start, m.is_range ? m.end : m.start);
                        marker_activated(m);
                    } else {
                        set_selection(0, doc.length);
                    }
                }
            });
            add_controller(dbl);
            resize.connect((w, h) => {
                if ((pending_fit || fit_mode) && w > 0) {
                    pending_fit = false;
                    Idle.add(() => {
                        zoom_fit();
                        return GLib.Source.REMOVE;
                    });
                }
            });
            notify["mode"].connect(() => {
                spec_key = "";
                queue_draw();
            });
            notify["fft-size"].connect(() => {
                spec_key = "";
                queue_draw();
            });
            notify["freq-scale"].connect(() => {
                spec_key = "";
                queue_draw();
            });
        }

        public void set_document(Document? d) {
            if (doc != null) {
                doc.changed.disconnect(on_doc_changed);
                doc.markers_changed.disconnect(on_doc_changed);
            }
            doc = d;
            spectral_sel = null;
            sel_a = sel_b = 0;
            cursor = 0;
            if (doc != null) {
                doc.changed.connect(on_doc_changed);
                doc.markers_changed.connect(on_doc_changed);
            }
            spec_key = "";
            pending_fit = true;
            if (get_width() > 0) Idle.add(() => {
                if (pending_fit && get_width() > 0) {
                    pending_fit = false;
                    zoom_fit();
                }
                return GLib.Source.REMOVE;
            });
            queue_draw();
        }

        private bool pending_fit = false;

        private void on_doc_changed() {
            spec_key = "";
            if (sel_b > doc.length) sel_b = doc.length;
            if (sel_a > sel_b) sel_a = sel_b;
            queue_draw();
        }

        private bool fit_mode = false;

        public void zoom_fit() {
            if (doc == null || get_width() <= 0) return;
            fit_mode = true;
            fpp = double.max(0.02, (double) int64.max(doc.length, 1) / get_width());
            scroll = 0;
            spec_key = "";
            view_changed();
            queue_draw();
        }

        public void zoom(double factor, double anchor_x = -1) {
            if (doc == null) return;
            fit_mode = false;
            if (anchor_x < 0) anchor_x = get_width() / 2.0;
            int64 anchor = frame_at(anchor_x);
            double max_fpp = double.max(1, (double) doc.length / double.max(1, get_width()));
            fpp = (fpp * factor).clamp(0.02, max_fpp * 1.2);
            scroll = int64.max(0, anchor - (int64) (anchor_x * fpp));
            spec_key = "";
            view_changed();
            queue_draw();
        }

        public void zoom_selection() {
            if (doc == null || sel_b <= sel_a) return;
            fit_mode = false;
            fpp = double.max(0.02, (double) (sel_b - sel_a) / double.max(1, get_width()));
            scroll = sel_a;
            spec_key = "";
            view_changed();
            queue_draw();
        }

        public void scroll_to(int64 frame) {
            scroll = int64.max(0, frame);
            spec_key = "";
            view_changed();
            queue_draw();
        }

        public void ensure_visible(int64 frame) {
            int w = get_width();
            if (frame < scroll || frame > scroll + (int64) (w * fpp)) scroll_to(int64.max(0, frame - (int64) (w * fpp * 0.1)));
        }

        public int64 frame_at(double x) {
            return scroll + (int64) Math.round(x * fpp);
        }

        public double x_at(int64 frame) {
            return (frame - scroll) / fpp;
        }

        public void set_selection(int64 a, int64 b) {
            if (doc == null) return;
            if (a > b) {
                int64 t = a;
                a = b;
                b = t;
            }
            sel_a = a.clamp(0, doc.length);
            sel_b = b.clamp(0, doc.length);
            cursor = sel_a;
            selection_changed();
            queue_draw();
        }

        public bool has_selection {
            get { return sel_b > sel_a; }
        }

        private int lanes_top() {
            return RULER;
        }

        private void lane_geometry(out int wave_top, out int wave_h, out int spec_top, out int spec_h) {
            int h = get_height() - RULER;
            switch (mode) {
            case ViewMode.SPECTRAL:
                wave_top = RULER;
                wave_h = 0;
                spec_top = RULER;
                spec_h = h;
                break;
            case ViewMode.SPLIT:
                wave_top = RULER;
                wave_h = h / 2;
                spec_top = RULER + h / 2;
                spec_h = h - h / 2;
                break;
            default:
                wave_top = RULER;
                wave_h = h;
                spec_top = 0;
                spec_h = 0;
                break;
            }
        }

        public static double freq_to_unit(double hz, int rate, int scale) {
            double nyq = rate / 2.0;
            double t;
            if (scale == 1) {
                t = hz / nyq;
            } else if (scale == 2) {
                t = (2595 * Math.log10(1 + hz / 700)) / (2595 * Math.log10(1 + nyq / 700));
            } else {
                t = Math.log(double.max(hz, 20) / 20) / Math.log(nyq / 20);
            }
            return 1 - t.clamp(0, 1);
        }

        public static double unit_to_freq(double u, int rate, int scale) {
            double nyq = rate / 2.0;
            double t = 1 - u.clamp(0, 1);
            if (scale == 1) return t * nyq;
            if (scale == 2) return 700 * (Math.pow(10, t * Math.log10(1 + nyq / 700)) - 1);
            return 20 * Math.pow(nyq / 20, t);
        }

        private Marker? marker_at(double x, double y) {
            if (doc == null || y > RULER + 14) return null;
            foreach (var m in doc.markers) {
                if (Math.fabs(x_at(m.start) - x) < 6) return m;
            }
            return null;
        }

        private void on_drag_begin(double x, double y) {
            if (doc == null) return;
            grab_focus();
            drag_x0 = x;
            drag_y0 = y;
            int wave_top, wave_h, spec_top, spec_h;
            lane_geometry(out wave_top, out wave_h, out spec_top, out spec_h);
            var m = marker_at(x, y);
            if (m != null) {
                drag_kind = 4;
                drag_marker = m;
                return;
            }
            if (wave_h > 0 && y >= wave_top && y < wave_top + 16) {
                if (x < 16 + x_at(0) && x_at(0) > -16) {
                    drag_kind = 2;
                    fade_preview = 0;
                    return;
                }
                if (x > x_at(doc.length) - 16 && x_at(doc.length) < get_width() + 16) {
                    drag_kind = 3;
                    fade_preview = 0;
                    return;
                }
            }
            if (spec_h > 0 && y >= spec_top && tool != SpectralTool.TIME) {
                drag_kind = 5;
                begin_spectral(x, y, spec_top, spec_h);
                return;
            }
            drag_kind = 1;
            spectral_sel = null;
            var state = drag_gesture.get_current_event_state();
            int64 f = frame_at(x).clamp(0, doc.length);
            if ((state & Gdk.ModifierType.SHIFT_MASK) != 0 && has_selection) {
                drag_anchor = (f - sel_a).abs() < (f - sel_b).abs() ? sel_b : sel_a;
                set_selection(drag_anchor, snap(f));
            } else {
                drag_anchor = snap(f);
                sel_a = sel_b = drag_anchor;
                cursor = drag_anchor;
                cursor_moved(cursor);
                selection_changed();
            }
            queue_draw();
        }

        private int64 snap(int64 f) {
            if (!snap_zero || doc == null || fpp > 64) return f;
            return doc.snap_zero(f, (int64) double.max(32, fpp * 6));
        }

        private void on_drag_update(double dx, double dy) {
            if (doc == null) return;
            double x = drag_x0 + dx;
            double y = drag_y0 + dy;
            switch (drag_kind) {
            case 1:
                int64 f = frame_at(x).clamp(0, doc.length);
                int64 a = drag_anchor, b = f;
                if (a > b) {
                    int64 t = a;
                    a = b;
                    b = t;
                }
                sel_a = a;
                sel_b = b;
                selection_changed();
                break;
            case 2:
                fade_preview = int64.max(0, frame_at(x)).clamp(0, doc.length);
                fade_curve = curve_for(dy);
                break;
            case 3:
                fade_preview = (doc.length - frame_at(x)).clamp(0, doc.length);
                fade_curve = curve_for(dy);
                break;
            case 4:
                drag_marker.start = frame_at(x).clamp(0, doc.length);
                break;
            case 5:
                extend_spectral(x, y);
                break;
            default:
                break;
            }
            queue_draw();
        }

        private int curve_for(double dy) {
            if (dy < -20) return 1;
            if (dy > 20) return 3;
            if (Math.fabs(dy) < 8) return 2;
            return 0;
        }

        private void on_drag_end(double dx, double dy) {
            if (doc == null) return;
            if (drag_kind == 1 && sel_b > sel_a) sel_b = snap(sel_b);
            if (drag_kind == 1) selection_changed();
            if ((drag_kind == 2 || drag_kind == 3) && fade_preview > 0) fade_applied(drag_kind == 2, fade_preview, fade_curve);
            if (drag_kind == 4) {
                doc.markers.sort(Marker.compare);
                doc.marker_checkpoint(_("Move Marker"));
            }
            if (drag_kind == 5) finish_spectral();
            drag_kind = 0;
            fade_preview = 0;
            drag_marker = null;
            queue_draw();
        }

        private void begin_spectral(double x, double y, int top, int h) {
            var s = new SpectralSelection();
            s.mask = new Cairo.ImageSurface(Cairo.Format.A8, int.max(1, get_width()), int.max(1, get_height()));
            s.scroll = scroll;
            s.fpp = fpp;
            s.top = top;
            s.height = h;
            s.scale = freq_scale;
            s.rate = doc.rate;
            spectral_sel = s;
            lasso.clear();
            lasso.add(x);
            lasso.add(y);
            if (tool == SpectralTool.BRUSH) paint_brush(x, y);
        }

        private void paint_brush(double x, double y) {
            var cr = new Cairo.Context(spectral_sel.mask);
            cr.set_source_rgba(0, 0, 0, 1);
            cr.arc(x, y, brush_size, 0, 2 * Math.PI);
            cr.fill();
            track_extent(x - brush_size, x + brush_size);
        }

        private void track_extent(double x0, double x1) {
            var s = spectral_sel;
            s.first_frame = int64.min(s.first_frame, int64.max(0, s.scroll + (int64) (x0 * s.fpp)));
            s.last_frame = int64.max(s.last_frame, s.scroll + (int64) (x1 * s.fpp));
        }

        private void extend_spectral(double x, double y) {
            if (spectral_sel == null) return;
            if (tool == SpectralTool.BRUSH) {
                double px = lasso[lasso.size - 2], py = lasso[lasso.size - 1];
                double dist = Math.hypot(x - px, y - py);
                int steps = int.max(1, (int) (dist / (brush_size / 3)));
                for (int i = 1; i <= steps; i++) paint_brush(px + (x - px) * i / steps, py + (y - py) * i / steps);
            }
            lasso.add(x);
            lasso.add(y);
        }

        private void finish_spectral() {
            if (spectral_sel == null) return;
            var cr = new Cairo.Context(spectral_sel.mask);
            cr.set_source_rgba(0, 0, 0, 1);
            if (tool == SpectralTool.RECTANGLE) {
                double x1 = lasso[lasso.size - 2], y1 = lasso[lasso.size - 1];
                double ax = double.min(lasso[0], x1), bx = double.max(lasso[0], x1);
                cr.rectangle(ax, double.min(lasso[1], y1), bx - ax, Math.fabs(y1 - lasso[1]));
                cr.fill();
                track_extent(ax, bx);
            } else if (tool == SpectralTool.LASSO) {
                double ax = double.MAX, bx = -double.MAX;
                for (int i = 0; i + 1 < lasso.size; i += 2) {
                    if (i == 0) cr.move_to(lasso[i], lasso[i + 1]);
                    else cr.line_to(lasso[i], lasso[i + 1]);
                    ax = double.min(ax, lasso[i]);
                    bx = double.max(bx, lasso[i]);
                }
                cr.close_path();
                cr.fill();
                track_extent(ax, bx);
            }
            spectral_sel.mask.flush();
            if (spectral_sel.last_frame <= spectral_sel.first_frame) {
                spectral_sel = null;
            } else {
                sel_a = spectral_sel.first_frame.clamp(0, doc.length);
                sel_b = spectral_sel.last_frame.clamp(0, doc.length);
                selection_changed();
            }
        }

        public void select_spectral_box(int64 a, int64 b, double low_hz, double high_hz) {
            int wave_top, wave_h, spec_top, spec_h;
            lane_geometry(out wave_top, out wave_h, out spec_top, out spec_h);
            if (spec_h <= 0 || doc == null) return;
            begin_spectral(x_at(a), spec_top, spec_top, spec_h);
            var cr = new Cairo.Context(spectral_sel.mask);
            cr.set_source_rgba(0, 0, 0, 1);
            double y0 = spectral_sel.y_for(high_hz), y1 = spectral_sel.y_for(low_hz);
            cr.rectangle(x_at(a), y0, x_at(b) - x_at(a), y1 - y0);
            cr.fill();
            spectral_sel.mask.flush();
            spectral_sel.first_frame = a;
            spectral_sel.last_frame = b;
            sel_a = a;
            sel_b = b;
            selection_changed();
            queue_draw();
        }

        public float[]? spectral_mask(int fft, int hop, out int64 start, out int columns, out int bins) {
            start = 0;
            columns = 0;
            bins = fft / 2 + 1;
            if (spectral_sel == null || doc == null) return null;
            var s = spectral_sel;
            start = int64.max(0, s.first_frame - fft);
            columns = (int) ((s.last_frame + fft - start) / hop) + 1;
            var mask = new float[columns * bins];
            for (int c = 0; c < columns; c++) {
                int64 frame = start + (int64) c * hop;
                for (int b = 0; b < bins; b++) {
                    double hz = (double) b * doc.rate / fft;
                    mask[c * bins + b] = s.weight(frame, hz);
                }
            }
            return mask;
        }

        private bool on_scroll(EventControllerScroll c, double dx, double dy) {
            if (doc == null) return false;
            fit_mode = false;
            var state = c.get_current_event_state();
            if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                double px = get_width() / 2.0;
                zoom(dy > 0 ? 1.25 : 0.8, px);
                return true;
            }
            double delta = (Math.fabs(dx) > Math.fabs(dy) ? dx : dy) * 40 * fpp;
            scroll_to(int64.max(0, scroll + (int64) delta));
            return true;
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.04);
            cr.rectangle(0, 0, w, h);
            cr.fill();
            draw_ruler(cr, w);
            if (doc == null) return;
            int wave_top, wave_h, spec_top, spec_h;
            lane_geometry(out wave_top, out wave_h, out spec_top, out spec_h);
            if (wave_h > 0) draw_wave(cr, w, wave_top, wave_h);
            if (spec_h > 0) draw_spectral(cr, w, spec_top, spec_h);
            double sa = x_at(sel_a), sb = x_at(sel_b);
            if (sb > sa) {
                Paint.accent(cr, 0.22);
                cr.rectangle(sa, RULER, sb - sa, h - RULER);
                cr.fill();
            }
            if (spectral_sel != null && spec_h > 0) {
                cr.save();
                cr.translate((spectral_sel.scroll - scroll) / fpp, 0);
                cr.scale(spectral_sel.fpp / fpp, 1);
                Paint.semantic(cr, "warning_color", 0.45);
                cr.mask_surface(spectral_sel.mask, 0, 0);
                cr.restore();
            }
            if (drag_kind == 5 && lasso.size >= 4 && tool != SpectralTool.BRUSH) {
                Paint.semantic(cr, "warning_color", 0.9);
                cr.set_line_width(1.5);
                if (tool == SpectralTool.RECTANGLE) {
                    cr.rectangle(lasso[0], lasso[1], lasso[lasso.size - 2] - lasso[0], lasso[lasso.size - 1] - lasso[1]);
                } else {
                    for (int i = 0; i + 1 < lasso.size; i += 2) {
                        if (i == 0) cr.move_to(lasso[i], lasso[i + 1]);
                        else cr.line_to(lasso[i], lasso[i + 1]);
                    }
                }
                cr.stroke();
            }
            foreach (var m in doc.markers) {
                double x = x_at(m.start);
                if (m.is_range) {
                    Paint.semantic(cr, "warning_color", 0.10);
                    cr.rectangle(x, RULER, m.length / fpp, h - RULER);
                    cr.fill();
                }
                if (x < -100 || x > w) continue;
                Paint.semantic(cr, "warning_color", 0.9);
                cr.set_line_width(1);
                cr.move_to(x + 0.5, RULER);
                cr.line_to(x + 0.5, h);
                cr.stroke();
                cr.move_to(x, RULER);
                cr.line_to(x + 8, RULER);
                cr.line_to(x, RULER + 10);
                cr.close_path();
                cr.fill();
                Paint.text(cr, this, m.name, x + 10, RULER + 1, 9);
            }
            double cx = x_at(cursor);
            Paint.set(cr, fg, 0.7);
            cr.set_line_width(1);
            cr.move_to(cx + 0.5, RULER);
            cr.line_to(cx + 0.5, h);
            cr.stroke();
            if (playhead >= 0) {
                double px = x_at(playhead);
                Paint.semantic(cr, "error_color");
                cr.set_line_width(1.5);
                cr.move_to(px, 0);
                cr.line_to(px, h);
                cr.stroke();
            }
        }

        private void draw_ruler(Cairo.Context cr, int w) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.06);
            cr.rectangle(0, 0, w, RULER);
            cr.fill();
            if (doc == null) return;
            double secs_per_px = fpp / doc.rate;
            double[] steps = { 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600 };
            double step = 3600;
            foreach (double s in steps) {
                if (s / secs_per_px >= 90) {
                    step = s;
                    break;
                }
            }
            double t0 = Math.floor(scroll / (double) doc.rate / step) * step;
            Paint.set(cr, fg, 0.55);
            cr.set_line_width(1);
            for (double t = t0; ; t += step) {
                double x = x_at((int64) (t * doc.rate));
                if (x > w) break;
                if (x < -100) continue;
                cr.move_to(x + 0.5, RULER - 8);
                cr.line_to(x + 0.5, RULER);
                cr.stroke();
                string label = step < 1 ? "%.*f".printf(step < 0.001 ? 4 : step < 0.01 ? 3 : step < 0.1 ? 2 : 1, t) : Timecode.format((int64) (t * doc.rate), doc.rate, false);
                Paint.text(cr, this, label, x + 3, 2, 8);
            }
        }

        private void draw_wave(Cairo.Context cr, int w, int top, int height) {
            var fg = Paint.fg(this);
            int ch = doc.channels;
            double lane = (double) height / ch;
            var lo = new float[w];
            var hi = new float[w];
            for (int c = 0; c < ch; c++) {
                double mid = top + lane * c + lane / 2;
                double amp = lane / 2 - 4;
                Paint.set(cr, fg, 0.12);
                cr.set_line_width(1);
                cr.move_to(0, mid + 0.5);
                cr.line_to(w, mid + 0.5);
                cr.stroke();
                if (c > 0) {
                    Paint.set(cr, fg, 0.1);
                    cr.move_to(0, top + lane * c);
                    cr.line_to(w, top + lane * c);
                    cr.stroke();
                }
                if (fpp < 1) {
                    int64 first = frame_at(0) - 1;
                    int n = (int) (w * fpp) + 3;
                    var buf = new float[n * ch];
                    doc.render(first, n, buf);
                    Paint.accent(cr);
                    cr.set_line_width(1.5);
                    for (int i = 0; i < n; i++) {
                        int64 f = first + i;
                        if (f < 0 || f >= doc.length) continue;
                        double x = x_at(f);
                        double y = mid - buf[i * ch + c] * amp;
                        if (i == 0 || f == 0) cr.move_to(x, y);
                        else cr.line_to(x, y);
                    }
                    cr.stroke();
                    if (fpp < 0.15) {
                        for (int i = 0; i < n; i++) {
                            int64 f = first + i;
                            if (f < 0 || f >= doc.length) continue;
                            cr.arc(x_at(f), mid - buf[i * ch + c] * amp, 3, 0, 2 * Math.PI);
                            cr.fill();
                        }
                    }
                    continue;
                }
                doc.peaks(scroll, fpp, w, c, lo, hi);
                Paint.accent(cr, 0.9);
                int64 end_px = (int64) x_at(doc.length);
                for (int x = 0; x < w && x < end_px; x++) {
                    double y1 = mid - hi[x] * amp;
                    double y2 = mid - lo[x] * amp;
                    cr.rectangle(x, y1, 1, double.max(1, y2 - y1));
                }
                cr.fill();
            }
            double fx0 = x_at(0);
            double fx1 = x_at(doc.length);
            Paint.set(cr, fg, 0.7);
            foreach (double fx in new double[] { fx0 + 1, fx1 - 13 }) {
                if (fx < -20 || fx > w + 20) continue;
                Paint.rounded(cr, fx, top + 2, 12, 12, 3);
                cr.fill();
            }
            if (fade_preview > 0) {
                bool fin = drag_kind == 2;
                double x0 = fin ? fx0 : x_at(doc.length - fade_preview);
                double x1 = fin ? x_at(fade_preview) : fx1;
                Paint.semantic(cr, "warning_color", 0.95);
                cr.set_line_width(2);
                for (int i = 0; i <= 64; i++) {
                    double t = i / 64.0;
                    double g = WaveDsp.fade_gain(fin ? t : 1 - t, fade_curve);
                    double x = x0 + (x1 - x0) * t;
                    double y = top + height - g * (height - 4);
                    if (i == 0) cr.move_to(x, y);
                    else cr.line_to(x, y);
                }
                cr.stroke();
                string[] names = { _("Linear"), _("Logarithmic"), _("S-Curve"), _("Exponential") };
                Paint.text(cr, this, "%s %s".printf(names[fade_curve], Timecode.format(fade_preview, doc.rate)), double.min(x0, x1) + 4, top + 18, 9, true);
            }
        }

        private void draw_spectral(Cairo.Context cr, int w, int top, int height) {
            string key = "%lld:%g:%d:%d:%d:%d:%u".printf(scroll, fpp, w, height, fft_size, freq_scale, doc.history_index);
            if (key != spec_key && !spec_busy) schedule_spectral(key, w, height);
            if (spec_tex != null) {
                cr.save();
                cr.translate(0, top);
                var surface = texture_surface(spec_tex);
                if (surface != null) {
                    cr.scale((double) w / spec_tex.get_width(), (double) height / spec_tex.get_height());
                    cr.set_source_surface(surface, 0, 0);
                    cr.paint();
                }
                cr.restore();
            }
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.85);
            foreach (double hz in new double[] { 100, 500, 1000, 2000, 5000, 10000, 20000 }) {
                if (hz > doc.rate / 2) continue;
                double y = top + freq_to_unit(hz, doc.rate, freq_scale) * height;
                cr.set_source_rgba(1, 1, 1, 0.75);
                Paint.text(cr, this, hz >= 1000 ? "%gk".printf(hz / 1000) : "%g".printf(hz), 3, y - 6, 8);
            }
        }

        private Cairo.ImageSurface? cached_surface = null;
        private Gdk.Texture? cached_for = null;

        private Cairo.ImageSurface? texture_surface(Gdk.Texture tex) {
            if (cached_for == tex && cached_surface != null) return cached_surface;
            var surface = new Cairo.ImageSurface(Cairo.Format.ARGB32, tex.get_width(), tex.get_height());
            tex.download(surface.get_data(), surface.get_stride());
            surface.mark_dirty();
            cached_surface = surface;
            cached_for = tex;
            return surface;
        }

        private void schedule_spectral(string key, int w, int height) {
            if (spec_timer != 0) GLib.Source.remove(spec_timer);
            spec_timer = Timeout.add(60, () => {
                spec_timer = 0;
                compute_spectral.begin(key, w, height);
                return GLib.Source.REMOVE;
            });
        }

        private async void compute_spectral(string key, int w, int height) {
            if (doc == null || w <= 0 || height <= 0) return;
            spec_busy = true;
            var d = doc;
            int fft = fft_size;
            double view_fpp = fpp;
            int64 first = scroll;
            int scale = freq_scale;
            int rate = d.rate;
            int cols = int.min(w, 2400);
            int rows = int.min(height, 1024);
            double col_frames = view_fpp * w / cols;
            uint8[]? pixels = null;
            SourceFunc cb = compute_spectral.callback;
            new Thread<void>("wave-spectrum", () => {
                pixels = SpectralRenderer.render(d, first, col_frames, cols, rows, fft, scale, rate);
                Idle.add((owned) cb);
            });
            yield;
            spec_busy = false;
            if (pixels != null) {
                var bytes = new Bytes.take((owned) pixels);
                spec_tex = new Gdk.MemoryTexture(cols, rows, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, cols * 4);
                spec_key = key;
            }
            queue_draw();
        }
    }

    namespace SpectralRenderer {
        public uint8[] render(Document d, int64 first, double col_frames, int cols, int rows, int fft, int scale, int rate) {
            int bins = fft / 2 + 1;
            var pixels = new uint8[cols * rows * 4];
            int64 span = (int64) (col_frames * cols) + fft;
            int64 start = first - fft / 2;
            var buf = new float[span * d.channels];
            d.render(start, (int) span, buf);
            var mono = new float[span];
            for (int64 f = 0; f < span; f++) {
                float s = 0;
                for (int c = 0; c < d.channels; c++) s += buf[f * d.channels + c];
                mono[f] = s / d.channels;
            }
            int hop = int.max(1, (int) col_frames);
            int ncol = (int) (span / hop) + 1;
            var spec = new float[ncol * bins];
            int got = WaveDsp.spectrogram(mono, span, fft, hop, WaveDsp.Window.HANN, spec, ncol);
            var row_bin = new int[rows];
            for (int y = 0; y < rows; y++) {
                double hz = WaveformView.unit_to_freq((y + 0.5) / rows, rate, scale);
                row_bin[y] = ((int) Math.round(hz * fft / rate)).clamp(0, bins - 1);
            }
            for (int x = 0; x < cols; x++) {
                int64 center = (int64) (x * col_frames) + fft / 2;
                int col = (int) (center / hop);
                if (col >= got || first + (int64) (x * col_frames) >= d.length) continue;
                for (int y = 0; y < rows; y++) {
                    float v = spec[col * bins + row_bin[y]];
                    double t = ((v + 110) / 110).clamp(0, 1);
                    uint8 r, g, b;
                    colormap(t, out r, out g, out b);
                    int o = (y * cols + x) * 4;
                    pixels[o] = b;
                    pixels[o + 1] = g;
                    pixels[o + 2] = r;
                    pixels[o + 3] = 255;
                }
            }
            return pixels;
        }

        public void colormap(double t, out uint8 r, out uint8 g, out uint8 b) {
            double[,] stops = {
                { 0.0, 0, 0, 4 }, { 0.15, 28, 16, 68 }, { 0.35, 114, 31, 129 }, { 0.55, 183, 55, 121 },
                { 0.75, 241, 96, 93 }, { 0.9, 254, 175, 119 }, { 1.0, 252, 253, 191 }
            };
            int i = 0;
            while (i < stops.length[0] - 2 && t > stops[i + 1, 0]) i++;
            double u = ((t - stops[i, 0]) / (stops[i + 1, 0] - stops[i, 0])).clamp(0, 1);
            r = (uint8) (stops[i, 1] + (stops[i + 1, 1] - stops[i, 1]) * u);
            g = (uint8) (stops[i, 2] + (stops[i + 1, 2] - stops[i, 2]) * u);
            b = (uint8) (stops[i, 3] + (stops[i + 1, 3] - stops[i, 3]) * u);
        }
    }

    public class OverviewBar : DrawingArea {
        public weak WaveformView view;

        public OverviewBar(WaveformView view) {
            this.view = view;
            set_size_request(-1, 36);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Overview of the whole file"), -1);
            view.view_changed.connect(() => queue_draw());
            view.selection_changed.connect(() => queue_draw());
            var click = new GestureDrag();
            click.drag_begin.connect((x, y) => jump(x));
            click.drag_update.connect((dx, dy) => {
                double sx, sy;
                click.get_start_point(out sx, out sy);
                jump(sx + dx);
            });
            add_controller(click);
        }

        private void jump(double x) {
            var d = view.doc;
            if (d == null || get_width() <= 0) return;
            int64 center = (int64) (x / get_width() * d.length);
            int64 visible = (int64) (view.get_width() * view.fpp);
            view.scroll_to(int64.max(0, center - visible / 2));
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.05);
            Paint.rounded(cr, 0, 0, w, h, 6);
            cr.fill();
            var d = view.doc;
            if (d == null || d.length <= 0) return;
            double fpp = (double) d.length / w;
            var lo = new float[w];
            var hi = new float[w];
            d.peaks(0, fpp, w, 0, lo, hi);
            Paint.accent(cr, 0.6);
            for (int x = 0; x < w; x++) cr.rectangle(x, h / 2.0 - hi[x] * h / 2, 1, double.max(1, (hi[x] - lo[x]) * h / 2));
            cr.fill();
            double vx = view.scroll / fpp;
            double vw = view.get_width() * view.fpp / fpp;
            Paint.set(cr, fg, 0.6);
            cr.set_line_width(1.5);
            Paint.rounded(cr, vx, 1, double.max(4, vw), h - 2, 4);
            cr.stroke();
            if (view.has_selection) {
                Paint.accent(cr, 0.25);
                cr.rectangle(view.sel_a / fpp, 0, (view.sel_b - view.sel_a) / fpp, h);
                cr.fill();
            }
        }
    }
}
