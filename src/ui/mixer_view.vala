using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class SurroundPad : DrawingArea {
        public Track track;
        public signal void moved();

        public SurroundPad(Track t) {
            track = t;
            set_size_request(96, 96);
            set_draw_func(draw);
            update_property(AccessibleProperty.LABEL, _("Surround panner"), -1);
            var g = new GestureDrag();
            g.drag_begin.connect((x, y) => place(x, y));
            g.drag_update.connect((dx, dy) => {
                double sx, sy;
                g.get_start_point(out sx, out sy);
                place(sx + dx, sy + dy);
            });
            g.drag_end.connect(() => moved());
            add_controller(g);
        }

        private void place(double x, double y) {
            double cx = get_width() / 2.0, cy = get_height() / 2.0;
            double dx = x - cx, dy = cy - y;
            track.azimuth = Math.atan2(dx, dy) * 180 / Math.PI;
            double r = Math.hypot(dx, dy) / (double.min(cx, cy) - 6);
            track.spread = (1 - r).clamp(0, 1);
            queue_draw();
        }

        private void draw(DrawingArea a, Cairo.Context cr, int w, int h) {
            double cx = w / 2.0, cy = h / 2.0, r = double.min(cx, cy) - 6;
            var fg = Paint.fg(this);
            Paint.set(cr, fg, 0.08);
            cr.arc(cx, cy, r, 0, 2 * Math.PI);
            cr.fill();
            Paint.set(cr, fg, 0.5);
            double[] angles = { -30, 0, 30, 110, -110 };
            string[] names = { "L", "C", "R", "Rs", "Ls" };
            for (int i = 0; i < 5; i++) {
                double an = angles[i] * Math.PI / 180;
                Paint.text(cr, this, names[i], cx + Math.sin(an) * (r - 4) - 4, cy - Math.cos(an) * (r - 4) - 6, 7);
            }
            double az = track.azimuth * Math.PI / 180;
            double d = (1 - track.spread) * r;
            Paint.accent(cr);
            cr.arc(cx + Math.sin(az) * d, cy - Math.cos(az) * d, 6, 0, 2 * Math.PI);
            cr.fill();
        }
    }

    public class ChannelStrip : Box {
        public Track track;
        public weak SessionPage page;
        public LevelMeter meter;
        private Scale fader;
        private Label gr;
        private Label vol_label;
        public Box top;
        public Box bottom;

        public ChannelStrip(SessionPage page, Track t, bool is_master) {
            Object(orientation: Orientation.VERTICAL, spacing: 6);
            this.page = page;
            track = t;
            add_css_class("sx-channel-strip");
            set_size_request(124, -1);
            top = new Box(Orientation.VERTICAL, 6);
            append(top);
            var name = new Label(t.name);
            name.add_css_class("heading");
            name.ellipsize = Pango.EllipsizeMode.END;
            name.tooltip_text = t.name;
            top.append(name);
            int n = t.rack.effects.size;
            var fx = new Label(n == 0 ? _("No effects") : ngettext("%d effect", "%d effects", n).printf(n));
            fx.add_css_class("caption");
            fx.add_css_class("dim-label");
            fx.ellipsize = Pango.EllipsizeMode.END;
            fx.tooltip_text = fx_summary();
            top.append(fx);
            if (!is_master) {
                foreach (var s in t.sends) {
                    var bus = page.session.find_track(s.bus);
                    if (bus == null) continue;
                    var sb = new Box(Orientation.VERTICAL, 0);
                    var sl = new Label(_("%s %s").printf(bus.name, s.pre_fader ? _("pre") : _("post")));
                    sl.add_css_class("caption");
                    sl.ellipsize = Pango.EllipsizeMode.END;
                    sb.append(sl);
                    var ss = new Scale.with_range(Orientation.HORIZONTAL, -60, 12, 0.5);
                    ss.draw_value = false;
                    ss.set_value(s.level_db);
                    ss.tooltip_text = _("Send level");
                    ss.update_property(AccessibleProperty.LABEL, _("Send level"), -1);
                    var send = s;
                    ss.value_changed.connect(() => send.level_db = ss.get_value());
                    sb.append(ss);
                    top.append(sb);
                }
                if (t.kind == TrackKind.AUDIO || t.kind == TrackKind.BUS) {
                    var add_send = new Button.with_label(_("Add Send"));
                    add_send.add_css_class("flat");
                    add_send.add_css_class("caption");
                    add_send.halign = Align.CENTER;
                    add_send.clicked.connect(() => page.add_send(t));
                    top.append(add_send);
                }
                if (page.session.channels == 6) {
                    var pad = new SurroundPad(t);
                    pad.halign = Align.CENTER;
                    pad.moved.connect(() => page.edited(_("Surround Pan")));
                    top.append(pad);
                    var lfe = new Scale.with_range(Orientation.HORIZONTAL, 0, 1, 0.01);
                    lfe.draw_value = false;
                    lfe.set_value(t.lfe);
                    lfe.tooltip_text = _("LFE send");
                    lfe.value_changed.connect(() => t.lfe = lfe.get_value());
                    top.append(lfe);
                } else {
                    var pan = new Scale.with_range(Orientation.HORIZONTAL, -1, 1, 0.01);
                    pan.draw_value = false;
                    pan.set_value(t.pan);
                    pan.add_mark(0, PositionType.BOTTOM, null);
                    pan.tooltip_text = _("Pan");
                    pan.update_property(AccessibleProperty.LABEL, _("Pan"), -1);
                    pan.value_changed.connect(() => {
                        t.pan = pan.get_value();
                        page.win.automation.touch(t, "pan", t.pan);
                    });
                    top.append(pan);
                }
            }
            var mid = new Box(Orientation.HORIZONTAL, 6);
            mid.halign = Align.CENTER;
            mid.vexpand = true;
            fader = new Scale.with_range(Orientation.VERTICAL, -60, 12, 0.1);
            fader.inverted = true;
            fader.draw_value = false;
            fader.set_value(t.volume_db);
            fader.add_mark(0, PositionType.LEFT, "0");
            fader.add_mark(-12, PositionType.LEFT, "-12");
            fader.add_mark(-36, PositionType.LEFT, "-36");
            fader.vexpand = true;
            fader.set_size_request(-1, 160);
            fader.update_property(AccessibleProperty.LABEL, _("Volume"), -1);
            fader.value_changed.connect(() => {
                t.volume_db = fader.get_value();
                vol_label.label = "%.1f dB".printf(t.volume_db);
                page.win.automation.touch(t, "volume", t.volume_db);
            });
            var press = new GestureClick();
            press.propagation_phase = PropagationPhase.CAPTURE;
            press.pressed.connect(() => page.win.automation.touch(t, "volume", t.volume_db));
            press.released.connect(() => page.win.automation.release(t, "volume"));
            fader.add_controller(press);
            mid.append(fader);
            meter = new LevelMeter(true);
            meter.vexpand = true;
            meter.margin_top = 10;
            meter.margin_bottom = 10;
            mid.append(meter);
            append(mid);
            bottom = new Box(Orientation.VERTICAL, 6);
            append(bottom);
            vol_label = new Label("%.1f dB".printf(t.volume_db));
            vol_label.add_css_class("caption");
            vol_label.add_css_class("numeric");
            bottom.append(vol_label);
            gr = new Label("");
            gr.add_css_class("caption");
            gr.add_css_class("numeric");
            gr.add_css_class("dim-label");
            gr.height_request = 16;
            bottom.append(gr);
            var buttons = new Box(Orientation.HORIZONTAL, 4);
            buttons.halign = Align.CENTER;
            var mute = Dialogs.toggle_text("M", _("Mute"), "mute");
            mute.active = t.mute;
            mute.toggled.connect(() => {
                t.mute = mute.active;
                page.edited(_("Mute"));
            });
            buttons.append(mute);
            if (!is_master) {
                var solo = Dialogs.toggle_text("S", _("Solo"), "solo");
                solo.active = t.solo;
                solo.toggled.connect(() => {
                    t.solo = solo.active;
                    page.edited(_("Solo"));
                });
                buttons.append(solo);
            }
            if (!is_master && t.kind == TrackKind.AUDIO) {
                var arm = Dialogs.toggle_text("R", _("Arm for Recording"), "arm");
                arm.active = t.armed;
                arm.toggled.connect(() => {
                    t.armed = arm.active;
                    page.rebuild();
                });
                buttons.append(arm);
            }
            bottom.append(buttons);
            if (!is_master) {
                string[] outs = { _("Master") };
                string[] ids = { "master" };
                int active = 0;
                foreach (var b in page.session.buses()) {
                    if (b == t) continue;
                    if (b.id == t.output) active = outs.length;
                    outs += b.name;
                    ids += b.id;
                }
                var route = new CompactMenu(_("Output"), outs, active);
                route.changed.connect((i) => {
                    t.output = ids[i];
                    page.edited(_("Route Output"));
                });
                bottom.append(route);
                var modes = new CompactMenu(_("Automation"), { _("Off"), _("Read"), _("Write"), _("Touch"), _("Latch") }, (int) t.automation);
                modes.changed.connect((i) => t.automation = (AutomationMode) i);
                bottom.append(modes);
            }
            var click = new GestureClick();
            click.pressed.connect(() => page.select_track(t));
            add_controller(click);
        }

        private string fx_summary() {
            if (track.rack.effects.size == 0) return _("No effects");
            string s = "";
            foreach (var e in track.rack.effects) s += (s != "" ? ", " : "") + e.title;
            return s;
        }

        public void sync() {
            if (Math.fabs(fader.get_value() - track.volume_db) > 0.05) fader.set_value(track.volume_db);
        }

        public void update_meter(TrackMeter? m) {
            if (m == null) return;
            meter.set_levels(m.peak, int.min(track.channels, 8));
            gr.label = m.reduction > 0.1 ? _("GR %.1f dB").printf(m.reduction) : "";
        }
    }

    public class CompactMenu : Button {
        private string[] labels;
        private Label value;
        public int active { get; private set; }

        public signal void changed(int index);

        public CompactMenu(string title, string[] labels, int active) {
            this.labels = labels;
            this.active = active.clamp(0, labels.length - 1);
            add_css_class("flat");
            add_css_class("wave-compact-menu");
            tooltip_text = title;
            update_property(AccessibleProperty.LABEL, title, -1);
            var box = new Box(Orientation.HORIZONTAL, 4);
            box.halign = Align.CENTER;
            value = new Label(labels[this.active]);
            value.ellipsize = Pango.EllipsizeMode.END;
            value.max_width_chars = 9;
            box.append(value);
            var arrow = new Image.from_icon_name("pan-down-symbolic");
            arrow.pixel_size = 12;
            box.append(arrow);
            child = box;
            clicked.connect(() => {
                var m = new ContextMenu(this);
                for (int i = 0; i < this.labels.length; i++) {
                    int idx = i;
                    m.add_item(this.labels[i], idx == this.active ? "object-select-symbolic" : null, () => {
                        this.active = idx;
                        value.label = this.labels[idx];
                        changed(idx);
                    });
                }
                Dialogs.popup_at(m, this, this);
            });
        }

        public void select(int index) {
            active = index.clamp(0, labels.length - 1);
            value.label = labels[active];
        }
    }

    public class MixerView : Box {
        private weak SessionPage page;
        private Box strips;
        private Gee.ArrayList<ChannelStrip> list = new Gee.ArrayList<ChannelStrip>();

        public MixerView(SessionPage page) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.page = page;
            var scroll = new ScrolledWindow();
            scroll.vscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.hscrollbar_policy = PolicyType.AUTOMATIC;
            scroll.vexpand = true;
            strips = new Box(Orientation.HORIZONTAL, 0);
            scroll.child = strips;
            append(scroll);
        }

        public void rebuild() {
            Dialogs.clear(strips);
            list.clear();
            if (page.session == null) return;
            foreach (var t in page.session.tracks) {
                if (t.kind == TrackKind.VIDEO) continue;
                var s = new ChannelStrip(page, t, false);
                strips.append(s);
                list.add(s);
            }
            var spacer = new Box(Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            strips.append(spacer);
            var master = new ChannelStrip(page, page.session.master, true);
            strips.append(master);
            list.add(master);
            var tops = new SizeGroup(SizeGroupMode.VERTICAL);
            var bottoms = new SizeGroup(SizeGroupMode.VERTICAL);
            var widths = new SizeGroup(SizeGroupMode.HORIZONTAL);
            foreach (var st in list) {
                widths.add_widget(st);
                tops.add_widget(st.top);
                bottoms.add_widget(st.bottom);
            }
            sync_selection();
        }

        public void sync() {
            foreach (var s in list) s.sync();
        }

        public void sync_selection() {
            foreach (var s in list) {
                if (s.track == page.selected_track) s.add_css_class("selected");
                else s.remove_css_class("selected");
            }
        }

        public void update_meters() {
            if (page.session == null) return;
            foreach (var s in list) s.update_meter(page.session.mixer.meters[s.track.id]);
        }
    }
}
