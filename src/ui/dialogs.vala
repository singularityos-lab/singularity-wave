using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class Dialogs {
        public delegate void ConfirmedFunc();

        public static GLib.ListStore filters(string name, string[] suffixes) {
            var store = new GLib.ListStore(typeof(FileFilter));
            var f = new FileFilter();
            f.name = name;
            foreach (var s in suffixes) f.add_suffix(s);
            store.append(f);
            return store;
        }

        public static string[] audio_suffixes() {
            return { "wave", "wav", "bwf", "flac", "mp3", "ogg", "oga", "opus", "m4a", "aac", "aif", "aiff", "aifc", "caf", "mp4", "mkv", "mov", "webm", "sesx", "otio", "cue", "montage" };
        }

        public static async File? save(Gtk.Window parent, string title, string suggested, string filter_name, string[] suffixes) {
            var d = new FileDialog();
            d.title = title;
            d.initial_name = suggested;
            d.filters = filters(filter_name, suffixes);
            try {
                return yield d.save(parent, null);
            } catch (Error e) {
                return null;
            }
        }

        public static async File? open(Gtk.Window parent, string title, string filter_name, string[] suffixes) {
            var d = new FileDialog();
            d.title = title;
            d.filters = filters(filter_name, suffixes);
            try {
                return yield d.open(parent, null);
            } catch (Error e) {
                return null;
            }
        }

        public static async GLib.ListModel? open_many(Gtk.Window parent, string title) {
            var d = new FileDialog();
            d.title = title;
            d.filters = filters(_("Audio files"), audio_suffixes());
            try {
                return yield d.open_multiple(parent, null);
            } catch (Error e) {
                return null;
            }
        }

        public static async File? folder(Gtk.Window parent, string title) {
            var d = new FileDialog();
            d.title = title;
            try {
                return yield d.select_folder(parent, null);
            } catch (Error e) {
                return null;
            }
        }

        public static string ensure_suffix(string path, string suffix) {
            return path.down().has_suffix("." + suffix) ? path : path + "." + suffix;
        }

        public static void confirm(Gtk.Window parent, string title, string body, string action, owned ConfirmedFunc done, bool destructive = true) {
            var dlg = new ConfirmDialog(parent.application, title, null, body, action, destructive ? ConfirmDialog.ActionStyle.DESTRUCTIVE : ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = parent;
            dlg.response.connect((r) => {
                if (r == ConfirmDialog.Response.PRIMARY) done();
            });
            dlg.present();
        }

        public static AppDialog form(Gtk.Window parent, string title, string action, out Box body, owned ConfirmedFunc done, int width = 460) {
            var dlg = new AppDialog(parent.application, true, false);
            dlg.set_title(title);
            dlg.transient_for = parent;
            dlg.set_default_size(width, -1);
            var scroll = new ScrolledWindow();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.propagate_natural_height = true;
            scroll.max_content_height = max_body_height(parent);
            scroll.vexpand = true;
            body = new Box(Orientation.VERTICAL, 12);
            body.margin_start = 18;
            body.margin_end = 18;
            body.margin_top = 6;
            body.margin_bottom = 12;
            scroll.child = body;
            dlg.content_box.append(scroll);
            var buttons = new Box(Orientation.HORIZONTAL, 8);
            buttons.halign = Align.END;
            buttons.margin_start = 18;
            buttons.margin_end = 18;
            buttons.margin_top = 4;
            buttons.margin_bottom = 16;
            buttons.append(dlg.add_cancel_button(_("Cancel")));
            var ok = new Button.with_label(action);
            ok.add_css_class("suggested-action");
            ok.clicked.connect(() => {
                done();
                dlg.close_dialog();
            });
            buttons.append(ok);
            dlg.content_box.append(buttons);
            dlg.default_widget = ok;
            return dlg;
        }

        private static int max_body_height(Gtk.Window parent) {
            var surface = parent.get_surface();
            var display = parent.get_display();
            Gdk.Monitor? mon = surface != null ? display.get_monitor_at_surface(surface) : null;
            if (mon == null) return 560;
            return int.max(240, mon.geometry.height - 260);
        }

        public static EntryRow entry_row(PreferencesGroup g, string title, string value) {
            var row = new EntryRow(title);
            row.text = value;
            g.add_row(row);
            return row;
        }

        public static SpinButton spin_row(PreferencesGroup g, string title, double min, double max, double step, double value, int digits = 1, string? unit = null, string? subtitle = null) {
            var row = new ActionRow(title, subtitle);
            var s = new SpinButton.with_range(min, max, step);
            s.digits = digits;
            s.value = value;
            s.valign = Align.CENTER;
            row.add_suffix(s);
            if (unit != null) {
                var u = new Label(unit);
                u.add_css_class("dim-label");
                u.width_chars = 4;
                u.xalign = 0;
                row.add_suffix(u);
            }
            g.add_row(row);
            return s;
        }

        public static ChoiceRow choice_row(PreferencesGroup g, string title, string[] labels, int active, string? subtitle = null) {
            var row = new ChoiceRow(title, labels, active, subtitle);
            g.add_row(row);
            return row;
        }

        public static Switch switch_row(PreferencesGroup g, string title, bool active, string? subtitle = null) {
            var row = new SwitchRow(title, subtitle, active);
            g.add_row(row);
            return row.switch_btn;
        }

        public static Button header_button(PreferencesGroup g, string icon, string tooltip) {
            var b = new Button.from_icon_name(icon);
            b.tooltip_text = tooltip;
            b.valign = Align.CENTER;
            g.add_header_suffix(b);
            return b;
        }

        public static ActionRow button_row(PreferencesGroup g, string title, string? subtitle, string action, owned ConfirmedFunc done, bool suggested = false) {
            var row = new ActionRow(title, subtitle);
            var b = new Button.with_label(action);
            b.valign = Align.CENTER;
            if (suggested) b.add_css_class("suggested-action");
            b.clicked.connect(() => done());
            row.add_suffix(b);
            g.add_row(row);
            row.set_data<Button>("wave-button", b);
            return row;
        }

        public static Button row_button(ActionRow row) {
            return row.get_data<Button>("wave-button");
        }

        public static void clear(Box box) {
            Widget? c;
            while ((c = box.get_first_child()) != null) box.remove(c);
        }

        public static Button flat_icon(string icon, string tooltip) {
            var b = new Button.from_icon_name(icon);
            b.tooltip_text = tooltip;
            b.add_css_class("flat");
            b.valign = Align.CENTER;
            return b;
        }

        public static ToggleButton toggle_icon(string icon, string tooltip) {
            var b = new ToggleButton();
            b.icon_name = icon;
            b.tooltip_text = tooltip;
            b.add_css_class("flat");
            b.valign = Align.CENTER;
            return b;
        }

        public static ToggleButton toggle_text(string text, string tooltip, string css) {
            var b = new ToggleButton.with_label(text);
            b.tooltip_text = tooltip;
            b.add_css_class("flat");
            b.add_css_class("wave-mini");
            b.add_css_class(css);
            b.valign = Align.CENTER;
            return b;
        }

        public static void popup_at(ContextMenu menu, Widget anchor, Widget relative) {
            Graphene.Rect bounds;
            Widget rel = menu.get_parent() ?? relative;
            if (anchor.compute_bounds(rel, out bounds)) {
                var rect = Gdk.Rectangle();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                menu.pointing_to = rect;
            }
            menu.position = PositionType.BOTTOM;
            menu.closed.connect(() => Idle.add(() => {
                menu.unparent();
                return GLib.Source.REMOVE;
            }));
            menu.popup();
        }

        public static void popup_point(ContextMenu menu, double x, double y) {
            var rect = Gdk.Rectangle();
            rect.x = (int) x;
            rect.y = (int) y;
            rect.width = 1;
            rect.height = 1;
            menu.pointing_to = rect;
            menu.closed.connect(() => Idle.add(() => {
                menu.unparent();
                return GLib.Source.REMOVE;
            }));
            menu.popup();
        }
    }

    public class ChoiceRow : SelectionRow {
        private uint _index;
        public uint index {
            get { return _index; }
            set {
                _index = value;
                current_value = value.to_string();
            }
        }

        public ChoiceRow(string title, string[] labels, int active, string? subtitle = null) {
            base.with_options(title, options_for(labels), active.clamp(0, labels.length - 1).to_string());
            _index = active.clamp(0, labels.length - 1);
            if (subtitle != null) this.subtitle = subtitle;
            selected.connect((id) => index = (uint) int.parse(id));
        }

        private static Gee.ArrayList<Singularity.Core.AppSettingOption> options_for(string[] labels) {
            var list = new Gee.ArrayList<Singularity.Core.AppSettingOption>();
            for (int i = 0; i < labels.length; i++) {
                var o = new Singularity.Core.AppSettingOption();
                o.id = i.to_string();
                o.label = labels[i];
                list.add(o);
            }
            return list;
        }
    }
}
