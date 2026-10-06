using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class RackPanel : Box {
        public EffectRack? rack { get; private set; }
        public string target_label { get; private set; default = ""; }
        public bool offline_hint { get; set; default = false; }

        public signal void apply_requested();
        public signal void changed();
        public signal void param_touched(Effect effect, EffectParam param, bool active);

        private Box list;
        private PreferencesGroup? group = null;
        private bool can_apply = false;
        private Gtk.Window? window_ref = null;

        public RackPanel() {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            list = new Box(Orientation.VERTICAL, 12);
            list.vexpand = true;
            append(list);
        }

        public void bind(EffectRack? r, string label, bool can_apply) {
            if (rack != null) rack.changed.disconnect(on_rack_changed);
            rack = r;
            target_label = label;
            this.can_apply = can_apply;
            if (rack != null) rack.changed.connect(on_rack_changed);
            rebuild();
        }

        private bool rebuilding = false;
        private int last_count = -1;

        private void on_rack_changed() {
            changed();
            if (rack != null && rack.effects.size != last_count) rebuild();
        }

        public void rebuild() {
            if (rebuilding) return;
            rebuilding = true;
            Dialogs.clear(list);
            last_count = rack != null ? rack.effects.size : -1;
            if (rack == null) {
                list.append(Singularity.Widgets.InspectorPanel.empty_state("dev.sinty.wave", _("No Effects"), _("Select a track or a clip to edit its effects.")));
                rebuilding = false;
                return;
            }
            group = new PreferencesGroup(target_label);
            var add = Dialogs.header_button(group, "list-add-symbolic", _("Add Effect"));
            add.clicked.connect(() => show_add_menu(add));
            var presets = Dialogs.header_button(group, "view-more-symbolic", _("Rack Presets"));
            presets.clicked.connect(() => show_preset_menu(presets));
            list.append(group);
            if (rack.effects.size == 0) {
                group.description = _("Add an equalizer, dynamics, reverb, restoration or a plugin.");
                rebuilding = false;
                return;
            }
            for (int i = 0; i < rack.effects.size; i++) group.add_row(card(rack.effects[i], i));
            if (can_apply) {
                var ag = new PreferencesGroup(_("Render"));
                Dialogs.button_row(ag, _("Apply to Selection"), _("Writes the rack into the audio"), _("Apply"), () => apply_requested(), true);
                list.append(ag);
            }
            rebuilding = false;
        }

        private Widget card(Effect e, int index) {
            var row = new ExpanderRow(e.title);
            row.add_css_class("wave-effect-row");
            var on = new Switch();
            on.active = !e.bypass;
            on.valign = Align.CENTER;
            on.margin_end = 12;
            on.tooltip_text = _("Enabled");
            on.notify["active"].connect(() => e.bypass = !on.active);
            row.add_prefix(on);
            if (e.offline_only()) row.subtitle = _("Applied when rendering");
            var more = new Button.from_icon_name("view-more-symbolic");
            more.add_css_class("flat");
            more.valign = Align.CENTER;
            more.tooltip_text = _("Effect Options");
            row.add_suffix(more);
            var plug = e as PluginEffect;
            if (plug != null && plug.load_error != null) row.subtitle = plug.load_error;
            var editor = new EffectEditor(e);
            editor.margin_top = 6;
            editor.margin_bottom = 6;
            row.add_row(editor);
            row.expanded = index == rack.effects.size - 1 || rack.effects.size <= 2;
            foreach (var prow in collect_rows(editor)) {
                var p = prow.param;
                prow.touched.connect((a) => param_touched(e, p, a));
            }
            more.clicked.connect(() => {
                var m = new ContextMenu(more);
                if (index > 0) m.add_item(_("Move Up"), "go-up-symbolic", () => rack.move(e, index - 1));
                if (index < rack.effects.size - 1) m.add_item(_("Move Down"), "go-down-symbolic", () => rack.move(e, index + 1));
                m.add_separator();
                foreach (string name in Presets.list(e.kind)) {
                    string n = name;
                    m.add_item(_("Preset: %s").printf(n), null, () => {
                        var o = Presets.load(e.kind, n);
                        if (o != null) e.load_json(o);
                    });
                }
                m.add_item(_("Save Preset…"), "document-save-symbolic", () => save_effect_preset(e));
                m.add_item(_("Reset to Defaults"), "edit-clear-symbolic", () => {
                    foreach (var p in e.parameters) p.value = p.fallback;
                });
                m.add_separator();
                m.add_item(_("Remove"), "user-trash-symbolic", () => rack.remove(e), "destructive-action");
                Dialogs.popup_at(m, more, this);
                rebuild_later();
            });
            return row;
        }

        private void rebuild_later() {
            Timeout.add(50, () => {
                if (rack != null && rack.effects.size != last_count) rebuild();
                return GLib.Source.REMOVE;
            });
        }

        private Gee.List<ParamRow> collect_rows(Widget w) {
            var list = new Gee.ArrayList<ParamRow>();
            for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
                if (c is ParamRow) list.add((ParamRow) c);
                list.add_all(collect_rows(c));
            }
            return list;
        }

        private Gtk.Window? win() {
            return get_root() as Gtk.Window;
        }

        private void save_effect_preset(Effect e) {
            var w = win();
            if (w == null) return;
            Box body;
            EntryRow? name = null;
            var dlg = Dialogs.form(w, _("Save Preset"), _("Save"), out body, () => {
                try {
                    Presets.save(e.kind, name.text.strip() != "" ? name.text.strip() : _("Preset"), e.to_json());
                } catch (Error err) {
                    warning("Wave: preset: %s", err.message);
                }
            });
            var g = new PreferencesGroup(_("Preset"));
            name = Dialogs.entry_row(g, _("Name"), "");
            body.append(g);
            dlg.present();
        }

        private void show_add_menu(Widget anchor) {
            if (rack == null) return;
            var m = new ContextMenu(anchor);
            string last = "";
            ContextMenu? sub = null;
            foreach (var k in EffectRegistry.builtin()) {
                if (k.category != last) {
                    sub = m.add_submenu(k.category, null);
                    last = k.category;
                }
                string kind = k.kind;
                sub.add_item(k.title, null, () => add_effect(kind));
            }
            var catalog = PluginCatalog.get_default();
            if (!catalog.scanned) catalog.rescan();
            if (catalog.plugins.size > 0) {
                var plugs = m.add_submenu(_("Plugins"), null);
                foreach (var p in catalog.plugins) {
                    if (p.unsupported != "") continue;
                    string kind = p.kind;
                    plugs.add_item("%s (%s)".printf(p.name, p.format), null, () => add_effect(kind));
                }
            }
            Dialogs.popup_at(m, anchor, this);
        }

        private void add_effect(string kind) {
            var e = EffectRegistry.create(kind, rack.isolate_plugins);
            if (e == null) {
                var w = get_root() as WaveWindow;
                if (w != null) w.toast(_("This effect is not available"));
                return;
            }
            rack.add(e);
            rebuild();
        }

        private void show_preset_menu(Widget anchor) {
            if (rack == null) return;
            var m = new ContextMenu(anchor);
            string[,] factory = { { "voice", _("Voice Clarity") }, { "podcast-master", _("Podcast Master") }, { "telephone", _("Telephone") }, { "music-bed", _("Music Bed") } };
            for (int i = 0; i < factory.length[0]; i++) {
                string id = factory[i, 0];
                m.add_item(factory[i, 1], null, () => {
                    rack.load_json(Presets.factory_rack(id));
                    rebuild();
                });
            }
            var user = Presets.list("rack");
            if (user.size > 0) m.add_separator();
            foreach (string n in user) {
                string name = n;
                m.add_item(name, null, () => {
                    rack.load_json(Presets.load("rack", name));
                    rebuild();
                });
            }
            m.add_separator();
            m.add_item(_("Save Rack Preset…"), "document-save-symbolic", () => {
                var w = win();
                if (w == null) return;
                Box body;
                EntryRow? name = null;
                var dlg = Dialogs.form(w, _("Save Rack Preset"), _("Save"), out body, () => {
                    try {
                        Presets.save("rack", name.text.strip() != "" ? name.text.strip() : _("Rack"), rack.to_json());
                    } catch (Error e) {
                        warning("Wave: preset: %s", e.message);
                    }
                });
                var g = new PreferencesGroup(_("Preset"));
                name = Dialogs.entry_row(g, _("Name"), "");
                body.append(g);
                dlg.present();
            });
            m.add_item(_("Clear Rack"), "edit-clear-symbolic", () => {
                rack.clear();
                rebuild();
            }, "destructive-action");
            Dialogs.popup_at(m, anchor, this);
        }
    }
}
