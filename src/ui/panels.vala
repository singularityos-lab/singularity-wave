using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class MarkersPanel : Box {
        private weak WaveWindow win;
        private Box list;

        public MarkersPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            list = new Box(Orientation.VERTICAL, 12);
            list.vexpand = true;
            append(list);
        }

        private void show_options(Widget anchor) {
            var m = new ContextMenu(anchor);
            m.add_item(_("Split File at Markers"), "edit-cut-symbolic", () => win.split_at_markers());
            m.add_item(_("Import CUE Sheet or Chapters…"), "document-open-symbolic", () => win.import_markers());
            m.add_item(_("Export CUE Sheet…"), "document-save-symbolic", () => win.export_markers("cue"));
            m.add_item(_("Export Podcast Chapters…"), "document-save-symbolic", () => win.export_markers("json"));
            Dialogs.popup_at(m, anchor, this);
        }

        public void refresh() {
            Dialogs.clear(list);
            var markers = win.current_markers();
            int rate = win.current_rate();
            if (markers == null || markers.size == 0) {
                var wp = new WelcomePage();
                wp.is_section = true;
                wp.compact = true;
                wp.embedded = true;
                wp.vexpand = true;
                wp.valign = Align.CENTER;
                wp.title = _("No Markers");
                wp.subtitle = _("Press M while playing to drop a marker. Markers become chapters when you export.");
                wp.add_action("mark-location", _("Add Marker"), _("At the cursor or around the selection"), () => win.add_marker());
                wp.add_action("text-x-generic", _("Import Chapters"), _("CUE sheets and podcast chapter files"), () => win.import_markers());
                list.append(wp);
                return;
            }
            var g = new PreferencesGroup(_("Chapters and Cues"));
            var add = Dialogs.header_button(g, "list-add-symbolic", _("Add Marker (M)"));
            add.clicked.connect(() => win.add_marker());
            var more = Dialogs.header_button(g, "view-more-symbolic", _("Marker Options"));
            more.clicked.connect(() => show_options(more));
            foreach (var m in markers) {
                var row = new ActionRow(m.name != "" ? m.name : _("Untitled"),
                    m.is_range ? "%s, %s".printf(Timecode.format(m.start, rate), Timecode.format(m.length, rate)) : Timecode.format(m.start, rate));
                var marker = m;
                row.activated.connect(() => win.go_to_marker(marker));
                var menu = Dialogs.flat_icon("view-more-symbolic", _("Marker Actions"));
                menu.clicked.connect(() => {
                    var cm = new ContextMenu(menu);
                    cm.add_item(_("Go to Marker"), "find-location-symbolic", () => win.go_to_marker(marker));
                    cm.add_item(_("Edit…"), "document-edit-symbolic", () => rename(marker));
                    cm.add_separator();
                    cm.add_item(_("Remove"), "user-trash-symbolic", () => win.remove_marker(marker), "destructive-action");
                    Dialogs.popup_at(cm, menu, this);
                });
                row.add_suffix(menu);
                g.add_row(row);
            }
            list.append(g);
        }

        private void rename(Marker m) {
            Box body;
            EntryRow? name = null;
            ChoiceRow? kind = null;
            SpinButton? length = null;
            int rate = win.current_rate();
            var dlg = Dialogs.form(win, _("Marker"), _("Save"), out body, () => {
                m.name = name.text.strip();
                string[] kinds = { "cue", "chapter", "track" };
                m.kind = kinds[kind.index];
                m.length = (int64) (length.value * rate);
                win.markers_edited(_("Edit Marker"));
            });
            var g = new PreferencesGroup(_("Marker"));
            name = Dialogs.entry_row(g, _("Name"), m.name);
            kind = Dialogs.choice_row(g, _("Kind"), { _("Cue"), _("Chapter"), _("Track") }, m.kind == "chapter" ? 1 : m.kind == "track" ? 2 : 0);
            length = Dialogs.spin_row(g, _("Range Length"), 0, 36000, 0.1, (double) m.length / rate, 3, "s", _("0 for a point marker"));
            body.append(g);
            dlg.present();
        }
    }

    public class HistoryPanel : Box {
        private weak WaveWindow win;
        private PreferencesGroup group;

        public HistoryPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            group = new PreferencesGroup(_("Steps"), _("Choose a step to go back to it"));
            append(group);
        }

        public void refresh() {
            group.clear();
            string[] labels;
            int index;
            win.history_labels(out labels, out index);
            for (int i = 0; i < labels.length; i++) {
                var row = new ActionRow(labels[i]);
                int idx = i;
                if (i > index) row.add_css_class("dim-label");
                if (i == index) row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
                row.activated.connect(() => win.restore_history(idx));
                group.add_row(row);
            }
        }
    }

    public class LoudnessPanel : Box {
        private weak WaveWindow win;
        public LoudnessGauge gauge;
        private Label integrated;
        private Label short_term;
        private Label momentary;
        private Label range;
        private Label true_peak;
        private ChoiceRow target;
        private SpinButton ceiling;
        private Button analyze;
        private Button normalize;

        public LoudnessPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            gauge = new LoudnessGauge();
            gauge.halign = Align.CENTER;
            append(gauge);
            var g = new PreferencesGroup(_("Measurement"), _("EBU R128 and ITU-R BS.1770"));
            analyze = new Button.with_label(_("Analyze"));
            analyze.valign = Align.CENTER;
            analyze.clicked.connect(() => win.analyze_loudness.begin());
            g.add_header_suffix(analyze);
            integrated = value_row(g, _("Integrated"));
            short_term = value_row(g, _("Short Term Maximum"));
            momentary = value_row(g, _("Momentary Maximum"));
            range = value_row(g, _("Loudness Range"));
            true_peak = value_row(g, _("True Peak"));
            append(g);
            var t = new PreferencesGroup(_("Normalize"));
            string[] labels = {};
            foreach (var lt in LoudnessTarget.all()) labels += lt.label;
            int active = 0;
            var all = LoudnessTarget.all();
            for (int i = 0; i < all.length; i++) {
                if (all[i].id == win.app.str("loudness-target", "podcast")) active = i;
            }
            target = Dialogs.choice_row(t, _("Target"), labels, active);
            ceiling = Dialogs.spin_row(t, _("True Peak Ceiling"), -6, 0, 0.5, win.app.num("true-peak-ceiling", -1), 1, "dBTP");
            target.notify["index"].connect(() => gauge.target = all[target.index].lufs);
            gauge.target = all[active].lufs;
            var nrow = Dialogs.button_row(t, _("Match Loudness"), _("Gain to reach the target, limited at the ceiling"), _("Match"), () => win.normalize_loudness.begin(all[target.index].lufs, ceiling.value), true);
            normalize = Dialogs.row_button(nrow);
            append(t);
        }

        private Label value_row(PreferencesGroup g, string title) {
            var row = new ActionRow(title);
            var l = new Label("--");
            l.add_css_class("numeric");
            row.add_suffix(l);
            g.add_row(row);
            return l;
        }

        public void show_result(LoudnessResult r) {
            integrated.label = LoudnessResult.format_lufs(r.integrated);
            short_term.label = LoudnessResult.format_lufs(r.short_term_max);
            momentary.label = LoudnessResult.format_lufs(r.momentary_max);
            range.label = "%.1f LU".printf(r.range);
            true_peak.label = LoudnessResult.format_db(r.true_peak, "dBTP");
            gauge.update(r.momentary_max, r.short_term_max, r.integrated);
        }

        public void set_busy(bool busy) {
            analyze.sensitive = !busy;
            normalize.sensitive = !busy;
        }
    }

    public class AnalysisPanel : Box {
        private weak WaveWindow win;
        public SpectrumPlot spectrum;
        public Vectorscope scope;
        private Label corr;
        private ChoiceRow size;

        public AnalysisPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            var fg = new PreferencesGroup(_("Frequency Analysis"), _("Average spectrum of the selection"));
            var scan = new Button.with_label(_("Analyze"));
            scan.valign = Align.CENTER;
            scan.tooltip_text = _("Analyze Selection");
            scan.clicked.connect(() => analyze_selection());
            fg.add_header_suffix(scan);
            spectrum = new SpectrumPlot();
            spectrum.margin_start = 12;
            spectrum.margin_end = 12;
            spectrum.margin_top = 12;
            spectrum.margin_bottom = 12;
            fg.add_row(spectrum);
            size = Dialogs.choice_row(fg, _("Resolution"), { _("1024 points"), _("4096 points"), _("16384 points") }, 1);
            append(fg);
            var pg = new PreferencesGroup(_("Phase and Stereo Image"));
            scope = new Vectorscope();
            scope.halign = Align.CENTER;
            scope.margin_top = 12;
            scope.margin_bottom = 6;
            pg.add_row(scope);
            corr = new Label(_("Play to see the live phase correlation"));
            corr.add_css_class("caption");
            corr.add_css_class("dim-label");
            corr.wrap = true;
            corr.margin_bottom = 12;
            corr.margin_start = 12;
            corr.margin_end = 12;
            pg.add_row(corr);
            append(pg);
        }

        public void analyze_selection() {
            float[]? mono;
            int rate;
            if (!win.selection_mono(out mono, out rate) || mono == null) return;
            int[] sizes = { 1024, 4096, 16384 };
            int fft = sizes[size.index];
            if (mono.length < fft) {
                win.toast(_("Select a longer part to analyze"));
                return;
            }
            var db = new float[fft / 2 + 1];
            WaveDsp.spectrum_average(mono, mono.length, fft, WaveDsp.Window.BLACKMAN_HARRIS, db);
            spectrum.db = db;
            spectrum.rate = rate;
            spectrum.queue_draw();
        }

        public void live(LiveMeter m) {
            scope.update(m.scope, m.scope_frames, m.correlation);
            corr.label = _("Correlation %.2f").printf(m.correlation);
        }
    }

    public class InfoPanel : Box {
        private weak WaveWindow win;
        private Box body;

        public InfoPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            body = new Box(Orientation.VERTICAL, 12);
            body.vexpand = true;
            append(body);
        }

        public void refresh() {
            Dialogs.clear(body);
            var meta = win.current_metadata();
            if (meta == null) {
                body.append(Singularity.Widgets.InspectorPanel.empty_state("dialog-information", _("No Metadata"), _("Open a file or a session to edit its tags.")));
                return;
            }
            var g = new PreferencesGroup(_("Tags"), _("Written as ID3, Vorbis comments, RIFF INFO and MP4 tags"));
            string[,] fields = {
                { "title", _("Title") }, { "artist", _("Artist") }, { "album", _("Album or Show") }, { "genre", _("Genre") },
                { "year", _("Year") }, { "track", _("Track or Episode") }, { "comment", _("Comment") }, { "copyright", _("Copyright") }, { "isrc", "ISRC" }
            };
            add_fields(g, meta, fields);
            body.append(g);
            var b = new PreferencesGroup(_("Broadcast Wave"), _("Stored in the bext chunk of BWF files"));
            string[,] bwf = {
                { "description", _("Description") }, { "originator", _("Originator") }, { "originator-reference", _("Reference") },
                { "origination-date", _("Date") }, { "origination-time", _("Time") }, { "coding-history", _("Coding History") }
            };
            add_fields(b, meta, bwf);
            body.append(b);
            var fmt = win.format_summary();
            if (fmt != "") {
                var f = new PreferencesGroup(_("Format"));
                f.add_row(new ActionRow(fmt));
                body.prepend(f);
            }
        }

        private void add_fields(PreferencesGroup g, Metadata meta, string[,] fields) {
            for (int i = 0; i < fields.length[0]; i++) {
                string prop = fields[i, 0];
                var v = Value(typeof(string));
                meta.get_property(prop, ref v);
                var e = Dialogs.entry_row(g, fields[i, 1], (string) v);
                e.entry_changed.connect(() => {
                    meta.set_property(prop, e.text);
                    win.mark_modified();
                });
            }
        }
    }
}
