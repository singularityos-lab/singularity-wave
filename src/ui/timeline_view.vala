using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class TrackHeader : Box {
        public Track track;
        public weak SessionPage page;
        private Label name;
        public LevelMeter meter;

        public TrackHeader(SessionPage page, Track t) {
            Object(orientation: Orientation.VERTICAL, spacing: 4);
            this.page = page;
            track = t;
            add_css_class("wave-track-header");
            var top = new Box(Orientation.HORIZONTAL, 4);
            var color = new DrawingArea();
            color.set_size_request(4, 18);
            color.set_draw_func((a, cr, w, h) => {
                Paint.hex(cr, t.color);
                Paint.rounded(cr, 0, 0, w, h, 2);
                cr.fill();
            });
            top.append(color);
            name = new Label(t.name);
            name.halign = Align.START;
            name.hexpand = true;
            name.ellipsize = Pango.EllipsizeMode.END;
            name.add_css_class("heading");
            top.append(name);
            var kind = new Label(t.kind == TrackKind.BUS ? _("Bus") : t.kind == TrackKind.VIDEO ? _("Video") : t.channels == 1 ? _("Mono") : t.channels == 6 ? "5.1" : _("Stereo"));
            kind.add_css_class("caption");
            kind.add_css_class("dim-label");
            top.append(kind);
            append(top);
            if (t.kind != TrackKind.VIDEO) {
                var row = new Box(Orientation.HORIZONTAL, 2);
                var mute = Dialogs.toggle_text("M", _("Mute"), "mute");
                mute.active = t.mute;
                mute.toggled.connect(() => {
                    t.mute = mute.active;
                    page.edited(_("Mute"));
                });
                row.append(mute);
                var solo = Dialogs.toggle_text("S", _("Solo"), "solo");
                solo.active = t.solo;
                solo.toggled.connect(() => {
                    t.solo = solo.active;
                    page.edited(_("Solo"));
                });
                row.append(solo);
                if (t.kind == TrackKind.AUDIO) {
                    var arm = Dialogs.toggle_text("R", _("Arm for Recording"), "arm");
                    arm.active = t.armed;
                    arm.toggled.connect(() => t.armed = arm.active);
                    row.append(arm);
                    var mon = Dialogs.toggle_text("I", _("Monitor Input"), "monitor");
                    mon.active = t.monitor;
                    mon.toggled.connect(() => {
                        t.monitor = mon.active;
                        page.win.activate_action("monitor", null);
                    });
                    row.append(mon);
                }
                var auto = Dialogs.toggle_text("A", _("Show Automation"), "auto");
                auto.active = page.lanes_visible(t);
                auto.toggled.connect(() => page.toggle_lanes(t, auto.active));
                row.append(auto);
                meter = new LevelMeter(false);
                meter.valign = Align.CENTER;
                meter.hexpand = true;
                meter.set_size_request(40, 8);
                row.append(meter);
                append(row);
            } else {
                meter = new LevelMeter(false);
                meter.visible = false;
            }
            var click = new GestureClick();
            click.pressed.connect((n, x, y) => {
                page.select_track(t);
                if (n == 2) page.rename_track(t);
            });
            add_controller(click);
            var menu = new GestureClick();
            menu.button = 3;
            menu.pressed.connect((n, x, y) => page.track_menu(t, this, x, y));
            add_controller(menu);
        }

        public void set_selected(bool on) {
            if (on) add_css_class("selected");
            else remove_css_class("selected");
        }
    }

    public class TimelineCanvas : DrawingArea {
        public weak SessionPage page;
        private double drag_x0;
        private double drag_y0;
        private int drag_mode = 0;
        private Clip? drag_clip = null;
        private Track? drag_track = null;
        private int64 orig_pos;
        private int64 orig_len;
        private int64 orig_off;
        private AutomationPoint? drag_point = null;
        private AutomationLane? drag_lane = null;

        public TimelineCanvas(SessionPage page) {
            this.page = page;
            hexpand = true;
            focusable = true;
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Multitrack timeline"), -1);
            var drag = new GestureDrag();
            drag.drag_begin.connect(on_begin);
            drag.drag_update.connect(on_update);
            drag.drag_end.connect(on_end);
            add_controller(drag);
            var right = new GestureClick();
            right.button = 3;
            right.pressed.connect((n, x, y) => page.context_menu_at(x, y, this));
            add_controller(right);
            var dbl = new GestureClick();
            dbl.pressed.connect((n, x, y) => {
                grab_focus();
                if (n != 2) return;
                Track? t;
                AutomationLane? lane;
                page.hit_row(y, out t, out lane);
                var c = t != null && lane == null ? t.clip_at(page.frame_at(x)) : null;
                if (c != null) page.win.edit_clip_in_waveform(c);
            });
            add_controller(dbl);
            var scroll = new EventControllerScroll(EventControllerScrollFlags.HORIZONTAL | EventControllerScrollFlags.VERTICAL);
            scroll.scroll.connect((dx, dy) => {
                var st = scroll.get_current_event_state();
                if ((st & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    page.zoom(dy > 0 ? 1.25 : 0.8);
                    return true;
                }
                if (Math.fabs(dx) > 0 || (st & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    page.scroll_by((Math.fabs(dx) > 0 ? dx : dy) * 40 * page.fpp);
                    return true;
                }
                return false;
            });
            add_controller(scroll);
        }

        private void on_begin(double x, double y) {
            grab_focus();
            drag_x0 = x;
            drag_y0 = y;
            drag_mode = 0;
            Track? t;
            AutomationLane? lane;
            double row_y = page.hit_row(y, out t, out lane);
            if (t == null) {
                if (y < SessionPage.RULER) {
                    drag_mode = 6;
                    page.set_time_selection(page.frame_at(x), page.frame_at(x));
                }
                return;
            }
            page.select_track(t);
            int64 f = page.frame_at(x);
            if (lane != null) {
                drag_lane = lane;
                drag_point = null;
                foreach (var p in lane.points) {
                    if (Math.fabs(page.x_at(p.frame) - x) < 6) drag_point = p;
                }
                if (drag_point == null) {
                    double v = lane.min_value + (1 - (y - row_y) / SessionPage.LANE_H) * (lane.max_value - lane.min_value);
                    lane.add(page.session.snap(f), v);
                    foreach (var p in lane.points) {
                        if (p.frame == page.session.snap(f)) drag_point = p;
                    }
                }
                drag_mode = 5;
                return;
            }
            var c = t.clip_at(f);
            drag_track = t;
            if (c == null) {
                drag_mode = 6;
                page.select_clip(null);
                page.move_cursor(page.session.snap(f));
                page.set_time_selection(f, f);
                return;
            }
            page.select_clip(c);
            drag_clip = c;
            orig_pos = c.position;
            orig_len = c.length;
            orig_off = c.source_offset;
            double cx0 = page.x_at(c.position), cx1 = page.x_at(c.end);
            bool top_zone = y - row_y < 14;
            if (top_zone && x - cx0 < 14) drag_mode = 7;
            else if (top_zone && cx1 - x < 14) drag_mode = 8;
            else if (x - cx0 < 6) drag_mode = 2;
            else if (cx1 - x < 6) drag_mode = 3;
            else drag_mode = 1;
        }

        private void on_update(double dx, double dy) {
            if (page.session == null) return;
            int64 df = (int64) (dx * page.fpp);
            switch (drag_mode) {
            case 1:
                drag_clip.position = page.session.snap(int64.max(0, orig_pos + df));
                Track? t;
                AutomationLane? lane;
                page.hit_row(drag_y0 + dy, out t, out lane);
                if (t != null && lane == null && t != drag_track && t.kind == TrackKind.AUDIO) {
                    drag_track.clips.remove(drag_clip);
                    t.clips.add(drag_clip);
                    drag_track = t;
                    page.select_track(t);
                }
                break;
            case 2:
                int64 delta = (df).clamp(-orig_off, orig_len - 64);
                drag_clip.position = orig_pos + delta;
                drag_clip.source_offset = orig_off + delta;
                drag_clip.length = orig_len - delta;
                break;
            case 3:
                int64 max_len = drag_clip.rendered != null ? drag_clip.rendered.frames : drag_clip.source.frames - drag_clip.source_offset;
                drag_clip.length = (orig_len + df).clamp(64, max_len);
                break;
            case 5:
                if (drag_point != null) {
                    drag_point.frame = int64.max(0, page.frame_at(drag_x0 + dx));
                    Track? t2;
                    AutomationLane? l2;
                    double ry = page.hit_row(drag_y0, out t2, out l2);
                    double v = drag_lane.min_value + (1 - (drag_y0 + dy - ry) / SessionPage.LANE_H) * (drag_lane.max_value - drag_lane.min_value);
                    drag_point.value = v.clamp(drag_lane.min_value, drag_lane.max_value);
                    drag_lane.sort();
                }
                break;
            case 6:
                page.set_time_selection(page.frame_at(drag_x0), page.frame_at(drag_x0 + dx));
                break;
            case 7:
                drag_clip.fade_in = int64.max(0, page.frame_at(drag_x0 + dx) - drag_clip.position).clamp(0, drag_clip.length);
                break;
            case 8:
                drag_clip.fade_out = (drag_clip.end - page.frame_at(drag_x0 + dx)).clamp(0, drag_clip.length);
                break;
            default:
                break;
            }
            queue_draw();
        }

        private void on_end(double dx, double dy) {
            if (page.session == null) return;
            if (drag_mode == 1 || drag_mode == 2 || drag_mode == 3) {
                if (drag_track != null) drag_track.sort_clips();
                if (dx != 0) page.edited(drag_mode == 1 ? _("Move Clip") : _("Trim Clip"));
            } else if (drag_mode == 5) {
                page.edited(_("Edit Automation"));
            } else if (drag_mode == 7 || drag_mode == 8) {
                page.edited(_("Clip Fade"));
            }
            drag_mode = 0;
            drag_clip = null;
            drag_point = null;
            queue_draw();
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            var s = page.session;
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.03);
            cr.rectangle(0, 0, w, h);
            cr.fill();
            if (s == null) return;
            draw_ruler(cr, w, s);
            if (s.snap_to_grid || s.metronome) {
                int64 beat = s.grid_frames();
                double bpx = beat / page.fpp;
                if (bpx > 6) {
                    int64 first = (page.scroll / beat) * beat;
                    for (int64 b = first; page.x_at(b) < w; b += beat) {
                        bool bar = (b / beat) % s.beats_per_bar == 0;
                        Paint.set(cr, fg, bar ? 0.12 : 0.05);
                        cr.rectangle(page.x_at(b), SessionPage.RULER, 1, h);
                        cr.fill();
                    }
                }
            }
            double y = SessionPage.RULER;
            foreach (var t in s.tracks) {
                double th = page.track_height(t);
                if (t == page.selected_track) {
                    Paint.accent(cr, 0.05);
                    cr.rectangle(0, y, w, SessionPage.TRACK_H);
                    cr.fill();
                }
                Paint.set(cr, fg, 0.08);
                cr.rectangle(0, y + SessionPage.TRACK_H - 1, w, 1);
                cr.fill();
                if (t.kind == TrackKind.VIDEO) draw_video(cr, t, y, w);
                else foreach (var c in t.clips) draw_clip(cr, t, c, y, w);
                double ly = y + SessionPage.TRACK_H;
                foreach (var l in t.lanes) {
                    if (!page.lanes_visible(t) || !l.visible) continue;
                    draw_lane(cr, t, l, ly, w);
                    ly += SessionPage.LANE_H;
                }
                y += th;
            }
            int64 a0, b0;
            if (page.time_selection(out a0, out b0)) {
                Paint.accent(cr, 0.18);
                cr.rectangle(page.x_at(a0), SessionPage.RULER, (b0 - a0) / page.fpp, h);
                cr.fill();
            }
            foreach (var m in s.markers) {
                double mx = page.x_at(m.start);
                if (mx < 0 || mx > w) continue;
                Paint.semantic(cr, "warning_color", 0.9);
                cr.rectangle(mx, SessionPage.RULER, 1, h);
                cr.fill();
                cr.move_to(mx, SessionPage.RULER - 10);
                cr.line_to(mx + 8, SessionPage.RULER - 10);
                cr.line_to(mx, SessionPage.RULER);
                cr.close_path();
                cr.fill();
                Paint.text(cr, this, m.name, mx + 10, SessionPage.RULER - 13, 8);
            }
            double cx = page.x_at(page.cursor);
            Paint.set(cr, fg, 0.7);
            cr.rectangle(cx, 0, 1, h);
            cr.fill();
            if (page.playhead >= 0) {
                Paint.semantic(cr, "error_color");
                cr.rectangle(page.x_at(page.playhead), 0, 1.5, h);
                cr.fill();
            }
        }

        private void draw_ruler(Cairo.Context cr, int w, Session s) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.06);
            cr.rectangle(0, 0, w, SessionPage.RULER);
            cr.fill();
            double sec_px = s.rate / page.fpp;
            double[] steps = { 0.1, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600 };
            double step = 600;
            foreach (double st in steps) {
                if (st * sec_px >= 80) {
                    step = st;
                    break;
                }
            }
            double t0 = Math.floor(page.scroll / (double) s.rate / step) * step;
            Paint.set(cr, fg, 0.55);
            for (double t = t0; ; t += step) {
                double x = page.x_at((int64) (t * s.rate));
                if (x > w) break;
                cr.rectangle(x, SessionPage.RULER - 6, 1, 6);
                cr.fill();
                Paint.text(cr, this, Timecode.format((int64) (t * s.rate), s.rate, step < 1), x + 3, 2, 8);
            }
        }

        private void draw_clip(Cairo.Context cr, Track t, Clip c, double y, int w) {
            double x0 = page.x_at(c.position), x1 = page.x_at(c.end);
            if (x1 < 0 || x0 > w) return;
            double top = y + 3, ch = SessionPage.TRACK_H - 7;
            bool sel = c == page.selected_clip;
            Paint.hex(cr, t.color, c.muted ? 0.12 : 0.28);
            Paint.rounded(cr, x0, top, x1 - x0, ch, 5);
            cr.fill_preserve();
            Paint.hex(cr, t.color, sel ? 1 : 0.6);
            cr.set_line_width(sel ? 2 : 1);
            cr.stroke();
            cr.save();
            Paint.rounded(cr, x0, top, x1 - x0, ch, 5);
            cr.clip();
            var src = c.rendered ?? c.source;
            int px0 = (int) double.max(0, x0);
            int px1 = (int) double.min(w, x1);
            if (px1 > px0 && src != null) {
                var level = src.peaks.level_for(page.fpp);
                double mid = top + ch / 2 + 6;
                double amp = (ch - 16) / 2;
                Paint.hex(cr, t.color, 0.9);
                for (int px = px0; px < px1; px++) {
                    int64 la = page.frame_at(px) - c.position + (c.rendered != null ? 0 : c.source_offset);
                    int64 lb = page.frame_at(px + 1) - c.position + (c.rendered != null ? 0 : c.source_offset);
                    if (lb <= la) lb = la + 1;
                    float lo = 0, hi = 0;
                    int64 ba = la / level.block, bb = (lb + level.block - 1) / level.block;
                    for (int64 bi = ba; bi < bb && bi < level.count; bi++) {
                        if (bi < 0) continue;
                        for (int k = 0; k < src.channels; k++) {
                            lo = float.min(lo, level.data[(bi * src.channels + k) * 2]);
                            hi = float.max(hi, level.data[(bi * src.channels + k) * 2 + 1]);
                        }
                    }
                    double g = Math.pow(10, c.gain_db / 20) * c.gain_at(page.frame_at(px));
                    cr.rectangle(px, mid - hi * amp * g, 1, double.max(1, (hi - lo) * amp * g));
                }
                cr.fill();
            }
            Paint.set(cr, Paint.fg(this), 0.9);
            string label = c.name + (c.stretch != 1 ? "  %.0f%%".printf(c.stretch * 100) : "") + (c.pitch != 0 ? "  %+.1f st".printf(c.pitch) : "") + (c.takes.size > 1 ? "  " + _("take %d of %d").printf(c.active_take + 1, c.takes.size) : "");
            Paint.text(cr, this, label, x0 + 6, top + 1, 8, true);
            Paint.set(cr, Paint.fg(this), 0.8);
            cr.set_line_width(1.5);
            if (c.fade_in > 0) {
                double fx = page.x_at(c.position + c.fade_in);
                for (int i = 0; i <= 24; i++) {
                    double tt = i / 24.0;
                    double xx = x0 + (fx - x0) * tt;
                    double yy = top + ch - WaveDsp.fade_gain(tt, c.fade_in_curve) * (ch - 2);
                    if (i == 0) cr.move_to(xx, yy);
                    else cr.line_to(xx, yy);
                }
                cr.stroke();
            }
            if (c.fade_out > 0) {
                double fx = page.x_at(c.end - c.fade_out);
                for (int i = 0; i <= 24; i++) {
                    double tt = i / 24.0;
                    double xx = fx + (x1 - fx) * tt;
                    double yy = top + ch - WaveDsp.fade_gain(1 - tt, c.fade_out_curve) * (ch - 2);
                    if (i == 0) cr.move_to(xx, yy);
                    else cr.line_to(xx, yy);
                }
                cr.stroke();
            }
            foreach (var o in t.clips) {
                if (o == c || o.position <= c.position || o.position >= c.end) continue;
                double ox0 = page.x_at(o.position), ox1 = page.x_at(int64.min(o.end, c.end));
                Paint.set(cr, Paint.fg(this), 0.55);
                cr.set_line_width(1);
                cr.move_to(ox0, top);
                cr.line_to(ox1, top + ch);
                cr.move_to(ox0, top + ch);
                cr.line_to(ox1, top);
                cr.stroke();
            }
            cr.restore();
            Paint.set(cr, Paint.fg(this), 0.6);
            Paint.rounded(cr, x0 + 2, top + 2, 8, 8, 2);
            cr.fill();
            Paint.rounded(cr, x1 - 10, top + 2, 8, 8, 2);
            cr.fill();
        }

        private void draw_video(Cairo.Context cr, Track t, double y, int w) {
            foreach (var v in t.video_segments) {
                int64 len = (v.end_ms - v.start_ms) * page.session.rate / 1000;
                double x0 = page.x_at(v.position), x1 = page.x_at(v.position + len);
                if (x1 < 0 || x0 > w) continue;
                Paint.set(cr, Paint.fg(this), 0.18);
                Paint.rounded(cr, x0, y + 3, x1 - x0, SessionPage.TRACK_H - 7, 5);
                cr.fill();
                Paint.set(cr, Paint.fg(this), 0.35);
                for (double fx = x0 + 6; fx < x1 - 6; fx += 14) {
                    cr.rectangle(fx, y + 7, 8, 5);
                    cr.rectangle(fx, y + SessionPage.TRACK_H - 15, 8, 5);
                }
                cr.fill();
                Paint.set(cr, Paint.fg(this), 0.9);
                Paint.text(cr, this, Path.get_basename(File.new_for_uri(v.uri).get_path() ?? v.uri), x0 + 8, y + 24, 9, true);
            }
        }

        private void draw_lane(Cairo.Context cr, Track t, AutomationLane l, double y, int w) {
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.04);
            cr.rectangle(0, y, w, SessionPage.LANE_H);
            cr.fill();
            Paint.set(cr, fg, 0.6);
            Paint.text(cr, this, page.lane_label(t, l), 6, y + 2, 8);
            double range = l.max_value - l.min_value;
            Paint.semantic(cr, "warning_color", 0.95);
            cr.set_line_width(1.5);
            if (l.points.size == 0) {
                double v = l.target == "volume" ? t.volume_db : l.target == "pan" ? t.pan : l.fallback;
                double yy = y + (1 - (v - l.min_value) / range) * (SessionPage.LANE_H - 4) + 2;
                cr.move_to(0, yy);
                cr.line_to(w, yy);
                cr.stroke();
                return;
            }
            for (int px = 0; px <= w; px += 2) {
                double v = l.value_at(page.frame_at(px));
                double yy = y + (1 - (v - l.min_value) / range) * (SessionPage.LANE_H - 4) + 2;
                if (px == 0) cr.move_to(px, yy);
                else cr.line_to(px, yy);
            }
            cr.stroke();
            foreach (var p in l.points) {
                double px = page.x_at(p.frame);
                if (px < -5 || px > w + 5) continue;
                double yy = y + (1 - (p.value - l.min_value) / range) * (SessionPage.LANE_H - 4) + 2;
                cr.arc(px, yy, 4, 0, 2 * Math.PI);
                cr.fill();
            }
        }
    }

    public class SessionPage : Box {
        public const int RULER = 26;
        public const int TRACK_H = 86;
        public const int LANE_H = 54;
        public const int HEADER_W = 230;

        public weak WaveWindow win;
        public Session? session { get; private set; }
        public double fpp { get; set; default = 400; }
        public int64 scroll { get; set; default = 0; }
        public int64 cursor { get; set; default = 0; }
        public int64 playhead { get; set; default = -1; }
        public Track? selected_track { get; private set; }
        public Clip? selected_clip { get; private set; }
        public bool punch_mode { get; set; default = false; }

        private int64 range_a = 0;
        private int64 range_b = 0;
        private Stack stack;
        private Box headers;
        private TimelineCanvas canvas;
        private ScrolledWindow vscroll;
        private Scrollbar hbar;
        private Adjustment hadj;
        public MixerView mixer;
        private Gee.HashSet<string> shown_lanes = new Gee.HashSet<string>();
        private Gee.ArrayList<TrackHeader> header_widgets = new Gee.ArrayList<TrackHeader>();
        private RibbonButton tempo;
        private RibbonToggle snap;
        private RibbonToggle punch;

        public SessionPage(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.win = win;
            stack = new Stack();
            stack.vexpand = true;
            var timeline = new Box(Orientation.VERTICAL, 0);
            var body = new Box(Orientation.HORIZONTAL, 0);
            var head_col = new Box(Orientation.VERTICAL, 0);
            head_col.set_size_request(HEADER_W, -1);
            head_col.hexpand = false;
            var corner = new Box(Orientation.HORIZONTAL, 0);
            corner.set_size_request(HEADER_W, RULER);
            head_col.append(corner);
            headers = new Box(Orientation.VERTICAL, 0);
            head_col.append(headers);
            body.append(head_col);
            canvas = new TimelineCanvas(this);
            body.append(canvas);
            vscroll = new ScrolledWindow();
            vscroll.hscrollbar_policy = PolicyType.NEVER;
            vscroll.vexpand = true;
            vscroll.child = body;
            timeline.append(vscroll);
            hadj = new Adjustment(0, 0, 100, 1, 10, 10);
            hadj.value_changed.connect(() => {
                scroll = (int64) hadj.value;
                canvas.queue_draw();
            });
            hbar = new Scrollbar(Orientation.HORIZONTAL, hadj);
            hbar.margin_start = HEADER_W;
            timeline.append(hbar);
            stack.add_named(timeline, "timeline");
            mixer = new MixerView(this);
            stack.add_named(mixer, "mixer");
            append(stack);
            canvas.resize.connect((w, h) => {
                if (fit_mode && w > 0) {
                    Idle.add(() => {
                        zoom_fit();
                        return GLib.Source.REMOVE;
                    });
                }
                update_adjustment();
            });
        }

        public void fill_ribbon(RibbonContext c) {
            var add = c.add_menu("list-add-symbolic", _("Add Track"), _("Add a track, a bus or a video reference"));
            add.label_in_compact = true;
            add.set_builder((m) => {
                m.add_item(_("Mono Track"), null, () => add_track(TrackKind.AUDIO, 1));
                m.add_item(_("Stereo Track"), null, () => add_track(TrackKind.AUDIO, 2));
                m.add_item(_("5.1 Track"), null, () => add_track(TrackKind.AUDIO, 6));
                m.add_item(_("Bus"), null, () => add_track(TrackKind.BUS, session != null ? session.channels : 2));
                m.add_item(_("Video Reference…"), null, () => choose_video());
            });
            c.add_button("document-open-symbolic", _("Import Audio"), null, "win.import");
            c.add_button("edit-cut-symbolic", _("Split at Playhead"), null, "win.split");
            c.add_separator();
            snap = c.add_toggle("view-grid-symbolic", _("Snap to Beats"));
            snap.toggled.connect((active) => {
                if (session != null) session.snap_to_grid = active;
                canvas.queue_draw();
            });
            punch = c.add_toggle("media-record-symbolic", _("Punch In"), _("Punch In: record only inside the selected range"));
            punch.toggled.connect((active) => punch_mode = active);
            tempo = c.add_button(null, _("Tempo"), _("Tempo and Meter"));
            tempo.activated.connect(() => {
                win.set_panel_visible(true);
                win.show_panel("properties");
            });
            c.add_separator();
            var duck = c.add_button(null, _("Auto Duck"), _("Lower the music under speech"));
            duck.activated.connect(() => auto_duck());
        }

        public void sync_tempo() {
            if (session != null) tempo.label = _("%.0f BPM").printf(session.tempo);
        }

        public void bind_session(Session s) {
            session = s;
            selected_track = s.tracks.size > 0 ? s.tracks[0] : null;
            selected_clip = null;
            cursor = 0;
            scroll = 0;
            range_a = range_b = 0;
            sync_tempo();
            snap.active = s.snap_to_grid;
            rebuild();
            Idle.add(() => {
                zoom_fit();
                return GLib.Source.REMOVE;
            });
        }

        public void show_mixer(bool on) {
            stack.visible_child_name = on ? "mixer" : "timeline";
            if (on) mixer.rebuild();
        }

        public void rebuild() {
            Dialogs.clear(headers);
            header_widgets.clear();
            if (session == null) return;
            if (selected_track != null && !session.tracks.contains(selected_track)) selected_track = null;
            foreach (var t in session.tracks) {
                var h = new TrackHeader(this, t);
                h.set_size_request(HEADER_W, track_height(t));
                h.set_selected(t == selected_track);
                headers.append(h);
                header_widgets.add(h);
            }
            int total = RULER;
            foreach (var t in session.tracks) total += track_height(t);
            canvas.set_size_request(200, total + 40);
            update_adjustment();
            canvas.queue_draw();
            if (stack.visible_child_name == "mixer") mixer.rebuild();
        }

        public void refresh() {
            if (session == null) return;
            if (header_widgets.size != session.tracks.size) {
                rebuild();
                return;
            }
            for (int i = 0; i < header_widgets.size; i++) {
                if (header_widgets[i].track != session.tracks[i]) {
                    rebuild();
                    return;
                }
            }
            update_adjustment();
            canvas.queue_draw();
            if (stack.visible_child_name == "mixer") mixer.sync();
        }

        public void queue_draw_all() {
            canvas.queue_draw();
        }

        public int track_height(Track t) {
            int h = TRACK_H;
            if (lanes_visible(t)) {
                foreach (var l in t.lanes) {
                    if (l.visible) h += LANE_H;
                }
            }
            return h;
        }

        public bool lanes_visible(Track t) {
            return shown_lanes.contains(t.id);
        }

        public void toggle_lanes(Track t, bool on) {
            if (on) {
                shown_lanes.add(t.id);
                t.lane("volume");
                t.lane("pan");
            } else {
                shown_lanes.remove(t.id);
            }
            rebuild();
        }

        public string lane_label(Track t, AutomationLane l) {
            if (l.target == "volume") return _("Volume");
            if (l.target == "pan") return _("Pan");
            if (l.target.has_prefix("send:")) {
                var b = session.find_track(l.target.substring(5));
                return _("Send to %s").printf(b != null ? b.name : "?");
            }
            if (l.target.has_prefix("fx:")) {
                string[] p = l.target.split(":");
                int idx = int.parse(p[1]);
                if (idx < t.rack.effects.size) {
                    var prm = t.rack.effects[idx].find(p[2]);
                    return "%s, %s".printf(t.rack.effects[idx].title, prm != null ? prm.label : p[2]);
                }
            }
            return l.target;
        }

        public double hit_row(double y, out Track? track, out AutomationLane? lane) {
            track = null;
            lane = null;
            if (session == null) return 0;
            double ty = RULER;
            foreach (var t in session.tracks) {
                if (y >= ty && y < ty + TRACK_H) {
                    track = t;
                    return ty;
                }
                double ly = ty + TRACK_H;
                if (lanes_visible(t)) {
                    foreach (var l in t.lanes) {
                        if (!l.visible) continue;
                        if (y >= ly && y < ly + LANE_H) {
                            track = t;
                            lane = l;
                            return ly;
                        }
                        ly += LANE_H;
                    }
                }
                ty += track_height(t);
            }
            return 0;
        }

        public int64 frame_at(double x) {
            return int64.max(0, scroll + (int64) (x * fpp));
        }

        public double x_at(int64 f) {
            return (f - scroll) / fpp;
        }

        public int64 playhead_frame() {
            return cursor;
        }

        public void move_cursor(int64 f) {
            cursor = int64.max(0, f);
            if (x_at(cursor) < 0 || x_at(cursor) > canvas.get_width()) scroll_to(int64.max(0, cursor - (int64) (canvas.get_width() * fpp * 0.1)));
            canvas.queue_draw();
            win.update_status();
        }

        public void show_playhead(int64 f) {
            playhead = f;
            if (f >= 0 && x_at(f) > canvas.get_width() * 0.95) scroll_to(f - (int64) (canvas.get_width() * fpp * 0.05));
            canvas.queue_draw();
        }

        public void set_time_selection(int64 a, int64 b) {
            range_a = int64.min(a, b);
            range_b = int64.max(a, b);
            canvas.queue_draw();
            win.update_status();
        }

        public bool time_selection(out int64 a, out int64 b) {
            a = range_a;
            b = range_b;
            return range_b > range_a;
        }

        public void select_all() {
            if (session != null) set_time_selection(0, session.length);
        }

        public void select_track(Track t) {
            selected_track = t;
            foreach (var h in header_widgets) h.set_selected(h.track == t);
            canvas.queue_draw();
            mixer.sync_selection();
            if (win.current_panel() == "effects") win.bind_rack();
            if (win.current_panel() == "properties") win.properties_panel.refresh();
        }

        public void select_clip(Clip? c) {
            selected_clip = c;
            canvas.queue_draw();
            if (win.current_panel() == "effects") win.bind_rack();
            if (win.current_panel() == "properties" || win.current_panel() == "sound") {
                win.properties_panel.refresh();
                win.essential_panel.refresh();
            }
        }

        public Gee.List<Clip> selected_clips() {
            var list = new Gee.ArrayList<Clip>();
            if (selected_clip != null) list.add(selected_clip);
            return list;
        }

        public void edited(string label) {
            if (session == null) return;
            session.checkpoint(label);
            win.after_edit();
        }

        public void zoom(double factor) {
            if (session == null) return;
            fit_mode = false;
            double center = canvas.get_width() / 2.0;
            int64 anchor = frame_at(center);
            fpp = (fpp * factor).clamp(1, 1e6);
            scroll = int64.max(0, anchor - (int64) (center * fpp));
            update_adjustment();
            canvas.queue_draw();
        }

        private bool fit_mode = true;

        public void zoom_fit() {
            fit_mode = true;
            if (session == null || canvas.get_width() <= 0) return;
            int64 len = int64.max(session.length, session.rate * 30);
            fpp = (double) len * 1.05 / canvas.get_width();
            scroll = 0;
            update_adjustment();
            canvas.queue_draw();
        }

        public void scroll_by(double frames) {
            fit_mode = false;
            scroll_to(int64.max(0, scroll + (int64) frames));
        }

        public void scroll_to(int64 f) {
            scroll = int64.max(0, f);
            update_adjustment();
            canvas.queue_draw();
        }

        private void update_adjustment() {
            if (session == null) return;
            double page_frames = canvas.get_width() * fpp;
            double upper = double.max(session.length + page_frames, scroll + page_frames);
            hadj.configure(scroll, 0, upper, fpp * 20, page_frames * 0.8, page_frames);
        }

        public void update_meters() {
            if (session == null) return;
            foreach (var h in header_widgets) {
                var m = session.mixer.meters[h.track.id];
                if (m != null) h.meter.set_levels(m.peak, int.min(h.track.channels, 8));
            }
            mixer.update_meters();
        }

        private void add_track(TrackKind kind, int ch) {
            if (session == null) return;
            var t = session.add_track(kind == TrackKind.BUS ? _("Bus %d").printf(session.buses().size + 1) : _("Track %d").printf(session.tracks.size + 1), kind, ch);
            t.rack.isolate_plugins = win.app.flag("isolate-plugins", true);
            selected_track = t;
            edited(_("Add Track"));
            rebuild();
        }

        private void choose_video() {
            Dialogs.open.begin(win, _("Video Reference"), _("Video files"), { "mp4", "mkv", "mov", "webm", "avi" }, (o, r) => {
                var f = Dialogs.open.end(r);
                if (f == null || session == null) return;
                var vt = session.video_track();
                if (vt == null) {
                    vt = session.add_track(_("Video"), TrackKind.VIDEO);
                    session.tracks.remove(vt);
                    session.tracks.insert(0, vt);
                }
                int64 ms = 0;
                try {
                    var d = new Gst.PbUtils.Discoverer(5 * Gst.SECOND);
                    var info = d.discover_uri(f.get_uri());
                    ms = (int64) (info.get_duration() / Gst.MSECOND);
                } catch (Error e) {
                    ms = 60000;
                }
                vt.video_segments.add(new VideoSegment(f.get_uri(), cursor, 0, ms));
                edited(_("Add Video"));
                rebuild();
                win.show_panel("video");
                if (session != null) win.import_into_session(f.get_path(), cursor);
            });
        }

        public void rename_track(Track t) {
            Box body;
            EntryRow? name = null;
            var dlg = Dialogs.form(win, _("Rename Track"), _("Rename"), out body, () => {
                t.name = name.text.strip() != "" ? name.text.strip() : t.name;
                edited(_("Rename Track"));
                rebuild();
            });
            var g = new PreferencesGroup(_("Track"));
            name = Dialogs.entry_row(g, _("Name"), t.name);
            body.append(g);
            dlg.present();
        }

        public void track_menu(Track t, Widget w, double x, double y) {
            var m = new ContextMenu(w);
            m.add_item(_("Rename…"), "document-edit-symbolic", () => rename_track(t));
            m.add_item(_("Duplicate"), "edit-copy-symbolic", () => {
                var copy = session.add_track(t.name + " " + _("Copy"), t.kind, t.channels);
                copy.rack.load_json(t.rack.to_json());
                foreach (var c in t.clips) copy.clips.add(c.duplicate());
                edited(_("Duplicate Track"));
                rebuild();
            });
            if (t.kind == TrackKind.AUDIO) {
                m.add_item(_("Automate an Effect Parameter…"), null, () => automate_effect(t));
                m.add_item(_("Add Send…"), null, () => add_send(t));
            }
            m.add_separator();
            m.add_item(_("Delete Track"), "user-trash-symbolic", () => {
                session.tracks.remove(t);
                foreach (var o in session.tracks) {
                    if (o.output == t.id) o.output = "master";
                    var keep = new Gee.ArrayList<Send>();
                    foreach (var s in o.sends) {
                        if (s.bus != t.id) keep.add(s);
                    }
                    o.sends.clear();
                    o.sends.add_all(keep);
                }
                edited(_("Delete Track"));
                rebuild();
            });
            Dialogs.popup_point(m, x, y);
        }

        public void add_send(Track t) {
            var buses = session.buses();
            if (buses.size == 0) {
                var b = session.add_track(_("Bus %d").printf(1), TrackKind.BUS, session.channels);
                buses = session.buses();
                b.rack.add(EffectRegistry.create("reverb"));
            }
            string[] names = {};
            foreach (var b in buses) names += b.name;
            Box body;
            ChoiceRow? bus = null;
            SpinButton? level = null;
            Switch? pre = null;
            var dlg = Dialogs.form(win, _("Add Send"), _("Add"), out body, () => {
                var s = new Send(buses[(int) bus.index].id);
                s.level_db = level.value;
                s.pre_fader = pre.active;
                t.sends.add(s);
                edited(_("Add Send"));
                rebuild();
            });
            var g = new PreferencesGroup(_("Send"));
            bus = Dialogs.choice_row(g, _("Bus"), names, 0);
            level = Dialogs.spin_row(g, _("Level"), -60, 12, 0.5, -6, 1, "dB");
            pre = Dialogs.switch_row(g, _("Before the Fader"), false, _("The send ignores the track volume"));
            body.append(g);
            dlg.present();
        }

        private void automate_effect(Track t) {
            if (t.rack.effects.size == 0) {
                win.toast(_("Add an effect to the track first"));
                return;
            }
            string[] labels = {};
            string[] targets = {};
            for (int i = 0; i < t.rack.effects.size; i++) {
                foreach (var p in t.rack.effects[i].parameters) {
                    if (p.choices.length > 0) continue;
                    labels += "%s, %s".printf(t.rack.effects[i].title, p.label);
                    targets += "fx:%d:%s".printf(i, p.id);
                }
            }
            Box body;
            ChoiceRow? param = null;
            var dlg = Dialogs.form(win, _("Automate"), _("Add Lane"), out body, () => {
                var l = t.lane(targets[param.index]);
                l.min_value = 0;
                l.max_value = 1;
                shown_lanes.add(t.id);
                edited(_("Add Automation"));
                rebuild();
            });
            var g = new PreferencesGroup(_("Lane"));
            param = Dialogs.choice_row(g, _("Parameter"), labels, 0);
            body.append(g);
            dlg.present();
        }

        public void context_menu_at(double x, double y, Widget w) {
            Track? t;
            AutomationLane? lane;
            hit_row(y, out t, out lane);
            if (t == null) return;
            var m = new ContextMenu(w);
            if (lane != null) {
                AutomationPoint? near = null;
                foreach (var p in lane.points) {
                    if (Math.fabs(x_at(p.frame) - x) < 6) near = p;
                }
                if (near != null) {
                    var pt = near;
                    m.add_item(_("Delete Point"), "user-trash-symbolic", () => {
                        lane.points.remove(pt);
                        edited(_("Edit Automation"));
                    });
                    string[] curves = { _("Linear"), _("Hold"), _("Smooth") };
                    for (int i = 0; i < 3; i++) {
                        int ci = i;
                        m.add_item(_("Curve: %s").printf(curves[i]), null, () => {
                            pt.curve = ci;
                            edited(_("Edit Automation"));
                        });
                    }
                }
                m.add_item(_("Clear Lane"), "edit-clear-symbolic", () => {
                    lane.points.clear();
                    edited(_("Clear Automation"));
                });
                Dialogs.popup_point(m, x, y);
                return;
            }
            var c = t.clip_at(frame_at(x));
            if (c != null) {
                select_clip(c);
                m.add_item(_("Edit in Waveform Editor"), "audio-x-generic-symbolic", () => win.edit_clip_in_waveform(c));
                m.add_item(_("Split at Playhead"), "edit-cut-symbolic", () => split_at_playhead());
                m.add_item(_("Duplicate"), "edit-copy-symbolic", () => {
                    var d = c.duplicate();
                    d.position = c.end;
                    t.clips.add(d);
                    t.sort_clips();
                    edited(_("Duplicate Clip"));
                });
                m.add_item(c.muted ? _("Unmute Clip") : _("Mute Clip"), null, () => {
                    c.muted = !c.muted;
                    edited(_("Mute Clip"));
                });
                if (c.takes.size > 1) {
                    for (int i = 0; i < c.takes.size; i++) {
                        int ti = i;
                        m.add_item(_("Use %s").printf(c.takes[i].name), null, () => {
                            c.use_take(ti);
                            edited(_("Choose Take"));
                        });
                    }
                }
                m.add_separator();
                m.add_item(_("Delete"), "user-trash-symbolic", () => {
                    t.clips.remove(c);
                    selected_clip = null;
                    edited(_("Delete Clip"));
                });
            } else {
                m.add_item(_("Import Audio Here…"), "document-open-symbolic", () => {
                    cursor = frame_at(x);
                    selected_track = t;
                    win.activate_action("import", null);
                });
            }
            Dialogs.popup_point(m, x, y);
        }

        public void split_at_playhead() {
            if (session == null) return;
            int64 at = cursor;
            bool done = false;
            foreach (var t in session.tracks) {
                if (selected_track != null && t != selected_track && selected_clip != null) continue;
                foreach (var c in t.clips.to_array()) {
                    if (at <= c.position || at >= c.end) continue;
                    var right = c.duplicate();
                    int64 cut = at - c.position;
                    right.position = at;
                    right.source_offset = c.source_offset + (c.rendered != null ? 0 : cut);
                    right.length = c.length - cut;
                    right.fade_in = 0;
                    c.length = cut;
                    c.fade_out = 0;
                    if (c.rendered != null) {
                        right.source_offset = c.source_offset + (int64) (cut / c.stretch);
                        right.rendered = null;
                    }
                    t.clips.add(right);
                    t.sort_clips();
                    done = true;
                }
            }
            if (done) edited(_("Split"));
        }

        public void delete_selected() {
            if (session == null) return;
            int64 a, b;
            if (time_selection(out a, out b)) {
                TextEdit.ripple_delete(session, a, b);
                set_time_selection(a, a);
                edited(_("Delete Range"));
                return;
            }
            if (selected_clip != null) {
                foreach (var t in session.tracks) t.clips.remove(selected_clip);
                selected_clip = null;
                edited(_("Delete Clip"));
            }
        }

        public void paste_clips(Gee.List<Clip> clips) {
            if (session == null || selected_track == null || clips.size == 0) return;
            int64 base_pos = clips[0].position;
            foreach (var c in clips) {
                var d = c.duplicate();
                d.position = cursor + (c.position - base_pos);
                selected_track.clips.add(d);
            }
            selected_track.sort_clips();
            edited(_("Paste"));
        }

        public Gee.List<Track> armed_tracks() {
            var list = new Gee.ArrayList<Track>();
            if (session == null) return list;
            foreach (var t in session.tracks) {
                if (t.armed && t.kind == TrackKind.AUDIO) list.add(t);
            }
            return list;
        }

        public string? armed_input() {
            foreach (var t in armed_tracks()) {
                if (t.input != "") return t.input;
            }
            return null;
        }

        public void process_clip(string what) {
            if (selected_clip == null) {
                win.toast(_("Select a clip first, or double click it to edit it in the waveform editor"));
                return;
            }
            var c = selected_clip;
            switch (what) {
            case "fade-in":
                c.fade_in = int64.min(c.length / 4, session.rate);
                break;
            case "fade-out":
                c.fade_out = int64.min(c.length / 4, session.rate);
                break;
            case "denoise":
            case "adaptive_denoise":
            case "declick":
            case "dehum":
            case "declip":
            case "dereverb":
                c.rack.add(EffectRegistry.create(what == "denoise" ? "adaptive_denoise" : what));
                break;
            default:
                win.edit_clip_in_waveform(c);
                return;
            }
            edited(_("Clip Effect"));
        }

        private void auto_duck() {
            if (session == null) return;
            int n = 0;
            int spans = 0;
            foreach (var t in session.tracks) {
                if (t.kind == TrackKind.AUDIO && (t.duck || t.role == "music")) {
                    spans += Ducking.apply(session, t, t.duck_db, 250, 500);
                    shown_lanes.add(t.id);
                    n++;
                }
            }
            if (n == 0) {
                win.toast(_("Mark a track as music in the Essential Sound panel first"));
                return;
            }
            win.toast(_("Music ducked under %d speech passages").printf(spans / int.max(1, n)));
            rebuild();
        }
    }
}
