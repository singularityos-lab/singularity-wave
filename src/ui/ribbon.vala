using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class WaveRibbon : ContextRibbon {
        private weak WaveWindow win;
        private bool syncing = false;
        private Gee.ArrayList<RibbonToggle> tools = new Gee.ArrayList<RibbonToggle>();
        private Gee.ArrayList<RibbonItem> waveform_items = new Gee.ArrayList<RibbonItem>();
        private RibbonSelector display;
        public RibbonButton undo_item;
        public RibbonButton redo_item;
        public RibbonContext multitrack;

        public WaveRibbon(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.win = win;
            add_css_class("wave-ribbon");
            build_edit(add_context("edit", _("Edit"), "edit-symbolic"));
            build_effects(add_context("effects", _("Effects"), "wave-effects-symbolic"));
            build_restore(add_context("restore", _("Restore"), "wave-spectrum-symbolic"));
            multitrack = add_context("multitrack", _("Tracks"), "view-list-symbolic");
            build_view(add_context("view", _("View"), "view-reveal-symbolic"));
            win.wave.notify["mode"].connect(() => sync_display());
            sync_display();
        }

        private RibbonButton button(RibbonContext c, string? icon, string label, string action, bool with_label = false) {
            var b = c.add_button(icon, label, null, "win." + action);
            b.label_in_compact = with_label;
            return b;
        }

        private RibbonButton process(RibbonContext c, string? icon, string label, string what, string? tip = null) {
            var b = c.add_button(icon, label, tip, "win.process", new Variant.string(what));
            b.label_in_compact = true;
            return b;
        }

        private RibbonMenu process_menu(RibbonContext c, string? icon, string label, string tip, string[,] items) {
            var m = c.add_menu(icon, label, tip);
            m.label_in_compact = true;
            string[,] copy = items;
            m.set_builder((menu) => {
                for (int i = 0; i < copy.length[0]; i++) {
                    string what = copy[i, 1];
                    menu.add_item(copy[i, 0], null, () => win.process(what));
                }
            });
            return m;
        }

        private void build_edit(RibbonContext c) {
            undo_item = button(c, "edit-undo-symbolic", _("Undo"), "undo");
            redo_item = button(c, "edit-redo-symbolic", _("Redo"), "redo");
            c.add_separator();
            button(c, "edit-cut-symbolic", _("Cut"), "cut");
            button(c, "edit-copy-symbolic", _("Copy"), "copy");
            button(c, "edit-paste-symbolic", _("Paste"), "paste");
            button(c, "edit-delete-symbolic", _("Delete"), "delete");
            c.add_separator();
            button(c, null, _("Silence"), "silence");
            button(c, null, _("Crop"), "crop");
            button(c, "edit-select-all-symbolic", _("Select All"), "select-all");
            c.add_separator();
            button(c, "bookmark-new-symbolic", _("Marker"), "marker", true);
            button(c, null, _("Split at Markers"), "split-markers");
            c.add_separator();
            string[,] defs = {
                { "wave-select-time-symbolic", _("Time"), _("Time Selection") },
                { "wave-select-rect-symbolic", _("Rectangle"), _("Rectangle Selection in the Spectrum") },
                { "wave-select-lasso-symbolic", _("Lasso"), _("Lasso Selection in the Spectrum") },
                { "wave-select-brush-symbolic", _("Brush"), _("Brush Selection in the Spectrum") }
            };
            for (int i = 0; i < defs.length[0]; i++) {
                var t = c.add_toggle(defs[i, 0], defs[i, 1], defs[i, 2]);
                t.active = i == 0;
                int idx = i;
                t.toggled.connect((active) => choose_tool(idx, active));
                tools.add(t);
                waveform_items.add(t);
            }
            var spectral = c.add_menu("wave-effects-symbolic", _("Spectral Selection"), _("Edit the Spectral Selection"));
            spectral.set_builder((m) => {
                m.add_item(_("Attenuate Selection"), null, () => win.spectral_apply(WaveDsp.SpectralMode.ATTENUATE, -24));
                m.add_item(_("Remove Selection"), null, () => win.spectral_apply(WaveDsp.SpectralMode.ATTENUATE, -90));
                m.add_item(_("Boost Selection"), null, () => win.spectral_apply(WaveDsp.SpectralMode.AMPLIFY, 6));
                m.add_item(_("Heal Selection"), null, () => win.spectral_apply(WaveDsp.SpectralMode.HEAL, 0));
                m.add_separator();
                m.add_item(_("Spot Healing in Time Selection"), null, () => win.process("heal"));
            });
            waveform_items.add(spectral);
        }

        private void choose_tool(int idx, bool active) {
            if (syncing) return;
            syncing = true;
            if (!active) {
                tools[idx].active = true;
                syncing = false;
                return;
            }
            for (int i = 0; i < tools.size; i++) if (i != idx) tools[i].active = false;
            syncing = false;
            win.wave.tool = (SpectralTool) idx;
            if (idx > 0 && win.wave.mode == ViewMode.WAVEFORM) win.wave.mode = ViewMode.SPLIT;
        }

        private void build_effects(RibbonContext c) {
            process(c, null, _("Amplify…"), "amplify");
            process(c, null, _("Normalize…"), "normalize");
            process(c, "wave-loudness-symbolic", _("Match Loudness…"), "loudness");
            c.add_separator();
            process(c, null, _("Fade In"), "fade-in");
            process(c, null, _("Fade Out"), "fade-out");
            process_menu(c, null, _("Invert and Reverse"), _("Polarity, direction and DC offset"), {
                { _("Invert"), "invert" },
                { _("Reverse"), "reverse" },
                { _("Remove DC Offset"), "dc" }
            });
            c.add_separator();
            process(c, null, _("Stretch and Pitch…"), "stretch");
            process(c, null, _("Convert Sample Type…"), "convert");
            process(c, null, _("Generate Tone…"), "tone");
            process(c, "wave-effects-symbolic", _("Apply Effects Rack"), "rack");
        }

        private void build_restore(RibbonContext c) {
            process(c, null, _("Capture Noise Print"), "capture-noise");
            process(c, null, _("Noise Reduction…"), "denoise");
            process(c, null, _("Adaptive Noise Reduction"), "adaptive_denoise");
            c.add_separator();
            process(c, null, _("Clicks"), "declick", _("Remove Clicks and Crackle"));
            process(c, null, _("Hum"), "dehum", _("Remove Hum"));
            process(c, null, _("Clipping"), "declip", _("Repair Clipping"));
            process(c, null, _("Reverb"), "dereverb", _("Reduce Reverb"));
            c.add_separator();
            process(c, null, _("Enhance Speech"), "enhance");
            process_menu(c, null, _("Advanced"), _("Model based and spot repairs"), {
                { _("Denoise with a Local Model…"), "model-denoise" },
                { _("Separate Voice…"), "separate" },
                { _("Spot Healing"), "heal" }
            });
        }

        private void build_view(RibbonContext c) {
            display = c.add_selector(_("Display"), 10);
            display.add_option("waveform", _("Waveform"));
            display.add_option("spectral", _("Spectral"));
            display.add_option("split", _("Both"));
            display.changed.connect((id) => {
                if (syncing) return;
                win.wave.mode = id == "spectral" ? ViewMode.SPECTRAL : id == "split" ? ViewMode.SPLIT : ViewMode.WAVEFORM;
            });
            waveform_items.add(display);
            c.add_separator();
            button(c, "zoom-out-symbolic", _("Zoom Out"), "zoom-out");
            button(c, "zoom-in-symbolic", _("Zoom In"), "zoom-in");
            var fit = c.add_button("zoom-fit-best-symbolic", _("Zoom to Fit"), _("Zoom to the selection, or to fit"));
            fit.shortcut = "Ctrl+0";
            fit.activated.connect(() => {
                if (win.view_name == "waveform" && win.wave.has_selection) win.wave.zoom_selection();
                else win.activate_action("zoom-fit", null);
            });
            c.add_separator();
            button(c, "sidebar-show-right-symbolic", _("Inspector"), "toggle-sidebar");
            button(c, "view-fullscreen-symbolic", _("Full Screen"), "fullscreen");
        }

        private void sync_display() {
            syncing = true;
            var m = win.wave.mode;
            display.selected = m == ViewMode.SPECTRAL ? "spectral" : m == ViewMode.SPLIT ? "split" : "waveform";
            syncing = false;
        }

        public void sync_view(string view, bool has_session) {
            bool waveform = view == "waveform";
            foreach (var item in waveform_items) item.widget.sensitive = waveform;
            int i = 0;
            for (var child = tabs.get_first_child(); child != null; child = child.get_next_sibling()) {
                if (i == 3) child.visible = has_session;
                i++;
            }
            if (!has_session && active_context == "multitrack") active_context = "edit";
            if (!waveform && has_session && active_context != "multitrack" && active_context != "view") active_context = "multitrack";
            else if (waveform && active_context == "multitrack") active_context = "edit";
        }
    }
}
