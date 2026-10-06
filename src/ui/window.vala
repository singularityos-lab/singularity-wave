using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class WaveWindow : Singularity.Widgets.Window {
        public WaveApp app;
        public Document? doc { get; private set; }
        public Session? session { get; private set; }
        public Player player = new Player();
        public Recorder recorder = new Recorder();
        public string view_name { get; private set; default = "welcome"; }

        private Stack content;
        private PreferencesGroup recent_list;
        public WaveformView wave;
        private OverviewBar overview;
        public SessionPage session_page;
        public TransportBar transport;
        private Stack work;
        private Gee.ArrayList<Widget> doc_bubbles = new Gee.ArrayList<Widget>();
        private BubbleSwitcher view_switch;
        private Singularity.Widgets.InspectorPanel inspector;
        private Revealer inspector_revealer;
        public RackPanel rack_panel;
        public MarkersPanel markers_panel;
        public HistoryPanel history_panel;
        public LoudnessPanel loudness_panel;
        public AnalysisPanel analysis_panel;
        public InfoPanel info_panel;
        public EssentialPanel essential_panel;
        public TranscriptPanel transcript_panel;
        public PropertiesPanel properties_panel;
        public VideoPanel video_panel;
        private Segment[] clipboard = {};
        private int clipboard_rate = 0;
        private int clipboard_channels = 0;
        private Gee.ArrayList<Clip> clip_clipboard = new Gee.ArrayList<Clip>();
        public WaveRibbon ribbon;
        private ProgressBar busy;
        private bool close_confirmed = false;
        private uint meter_timer = 0;
        public AutomationRecorder automation = new AutomationRecorder();
        private bool recording_session = false;
        private int64 record_start = 0;

        public WaveWindow(WaveApp app) {
            Object(application: app);
            this.app = app;
            set_default_size(1360, 840);
            set_title(_("Wave"));
            content = new Stack();
            content.transition_type = StackTransitionType.CROSSFADE;
            content.add_named(build_welcome(), "welcome");
            content.add_named(build_work(), "work");
            set_content(content);
            build_bubbles();
            install_actions();
            player.tick.connect(on_tick);
            EqGraph.analyzer = player.meter;
            player.ended.connect(() => {
                transport.set_playing(false);
                if (recorder.recording) stop_recording();
                wave.playhead = -1;
                session_page.show_playhead(-1);
                wave.queue_draw();
            });
            recorder.finished.connect(on_recorded);
            recorder.failed.connect((msg) => {
                transport.record_button.active = false;
                show_error(_("Recording Failed"), msg);
            });
            close_request.connect(on_close_request);
            var drop = new DropTarget(typeof(Gdk.FileList), Gdk.DragAction.COPY);
            drop.drop.connect((value, x, y) => {
                var list = (Gdk.FileList) value.get_boxed();
                foreach (var f in list.get_files()) {
                    if (session != null && view_name != "waveform") import_into_session(f.get_path(), session_page.playhead_frame());
                    else open_file(f);
                }
                return true;
            });
            ((Widget) this).add_controller(drop);
            show_welcome();
            TestScript.maybe_run(this);
        }

        public bool is_empty() {
            return doc == null && session == null;
        }

        private Widget build_welcome() {
            var wp = new WelcomePage();
            wp.app_icon_name = "dev.sinty.wave";
            wp.title = _("Wave");
            wp.subtitle = _("Record, edit, restore and mix audio");
            wp.add_action("document-new", _("New Multitrack Session"), _("Tracks, clips, crossfades, buses, automation and a mixer"), () => new_session("session"));
            wp.add_action("audio-input-microphone", _("New Podcast"), _("Host and guest voices, music with automatic ducking, loudness for podcast apps"), () => new_session("podcast"));
            wp.add_action("media-record", _("Record Audio"), _("Record a new file from any input and edit it in the waveform editor"), () => record_new_file());
            wp.add_action("folder-open", _("Open"), _("WAV, BWF, FLAC, MP3, Ogg, Opus, AIFF, M4A, video files, Wave and Audition sessions"), () => choose_open());
            recent_list = new PreferencesGroup(_("Recent"));
            Singularity.Widgets.apply_titlebar_inset(recent_list);
            wp.set_extra_widget(recent_list);
            return wp;
        }

        private void fill_recent() {
            recent_list.clear();
            var items = new Gee.ArrayList<RecentInfo>();
            foreach (var info in RecentManager.get_default().get_items()) {
                if (!info.exists()) continue;
                if (info.has_application("Wave") || info.get_uri().has_suffix(".wave")) items.add(info);
            }
            items.sort((a, b) => b.get_modified().compare(a.get_modified()));
            int count = 0;
            foreach (var info in items) {
                if (count++ >= 6) break;
                var file = File.new_for_uri(info.get_uri());
                var parent = file.get_parent();
                string p = parent != null ? (parent.get_path() ?? "") : "";
                string home = Environment.get_home_dir();
                if (p.has_prefix(home)) p = "~" + p.substring(home.length);
                var row = new ActionRow(file.get_basename(), p, file.get_basename().has_suffix(".wave") ? "dev.sinty.wave" : "audio-x-generic");
                row.tooltip_text = file.get_path();
                row.activated.connect(() => open_file(file));
                recent_list.add_row(row);
            }
            recent_list.visible = count > 0;
        }

        private Widget build_work() {
            var box = new Box(Orientation.VERTICAL, 0);
            work = new Stack();
            work.transition_type = StackTransitionType.CROSSFADE;
            work.vexpand = true;
            var editor = new Box(Orientation.VERTICAL, 6);
            editor.margin_start = 10;
            editor.margin_end = 10;
            editor.margin_top = 6;
            wave = new WaveformView();
            wave.snap_zero = app.flag("snap-zero-crossings", true);
            wave.fft_size = int.parse(app.str("spectral-window", "2048"));
            string sc = app.str("spectral-scale", "log");
            wave.freq_scale = sc == "linear" ? 1 : sc == "mel" ? 2 : 0;
            overview = new OverviewBar(wave);
            editor.append(overview);
            editor.append(wave);
            wave.selection_changed.connect(() => update_status());
            wave.cursor_moved.connect((f) => {
                if (player.playing && player.current == doc) player.play(f);
                update_status();
            });
            wave.fade_applied.connect((fade_in, frames, curve) => {
                run_doc(() => Processes.fade(doc, fade_in ? 0 : doc.length - frames, fade_in ? frames : doc.length, fade_in, curve));
            });
            work.add_named(editor, "waveform");
            session_page = new SessionPage(this);
            work.add_named(session_page, "multitrack");
            ribbon = new WaveRibbon(this);
            session_page.fill_ribbon(ribbon.multitrack);
            Singularity.Widgets.apply_view_edge(ribbon);
            box.append(ribbon);
            box.append(work);
            busy = new ProgressBar();
            busy.visible = false;
            busy.add_css_class("osd");
            box.append(busy);
            transport = new TransportBar();
            transport.play_clicked.connect(() => toggle_play());
            transport.stop_clicked.connect(() => stop_all());
            transport.start_clicked.connect(() => move_to(0));
            transport.end_clicked.connect(() => move_to(current_length()));
            transport.record_button.toggled.connect(() => {
                if (transport.record_button.active && !recorder.recording) start_recording();
                else if (!transport.record_button.active && recorder.recording) stop_recording();
            });
            transport.loop_button.toggled.connect(() => player.looping = transport.loop_button.active);
            transport.metronome_button.toggled.connect(() => {
                if (session != null) {
                    session.metronome = transport.metronome_button.active;
                    session_page.queue_draw_all();
                }
            });
            box.append(transport);
            box.hexpand = true;
            var main = new Box(Orientation.HORIZONTAL, 0);
            main.append(box);
            main.append(build_inspector());
            return main;
        }

        private Widget build_inspector() {
            inspector = new Singularity.Widgets.InspectorPanel(372);
            inspector.scroll_pages = true;
            rack_panel = new RackPanel();
            rack_panel.apply_requested.connect(() => process("rack"));
            rack_panel.param_touched.connect(on_param_touched);
            inspector.add_page("effects", _("Effects"), "wave-effects-symbolic", rack_panel, true);
            properties_panel = new PropertiesPanel(this);
            inspector.add_page("properties", _("Clip"), "document-properties-symbolic", properties_panel, true);
            loudness_panel = new LoudnessPanel(this);
            inspector.add_page("loudness", _("Loudness"), "wave-loudness-symbolic", loudness_panel, true);
            markers_panel = new MarkersPanel(this);
            inspector.add_page("markers", _("Markers"), "bookmark-new-symbolic", markers_panel, true);
            essential_panel = new EssentialPanel(this);
            inspector.add_page("sound", _("Essential Sound"), "audio-speakers-symbolic", essential_panel, false);
            analysis_panel = new AnalysisPanel(this);
            inspector.add_page("analysis", _("Analysis"), "wave-spectrum-symbolic", analysis_panel, false);
            transcript_panel = new TranscriptPanel(this);
            inspector.add_page("transcript", _("Transcript"), "wave-transcript-symbolic", transcript_panel, false);
            video_panel = new VideoPanel(this);
            inspector.add_page("video", _("Video Reference"), "video-x-generic-symbolic", video_panel, false);
            info_panel = new InfoPanel(this);
            inspector.add_page("info", _("Metadata"), "dialog-information-symbolic", info_panel, false);
            history_panel = new HistoryPanel(this);
            inspector.add_page("history", _("History"), "document-open-recent-symbolic", history_panel, false);
            inspector.page_chosen.connect((name) => show_panel(name));
            inspector_revealer = new Revealer();
            inspector_revealer.hexpand = false;
            inspector_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            inspector_revealer.transition_duration = 200;
            inspector_revealer.child = inspector;
            inspector_revealer.reveal_child = false;
            inspector.page = "effects";
            return inspector_revealer;
        }

        public void show_panel(string id) {
            inspector.page = id;
            refresh_panel(id);
        }

        public string current_panel() {
            return inspector.page ?? "";
        }

        public void set_panel_visible(bool visible) {
            inspector_revealer.reveal_child = visible;
            if (visible) refresh_panel(current_panel());
        }

        public bool get_panel_visible() {
            return inspector_revealer.reveal_child;
        }

        private void refresh_panel(string id) {
            switch (id) {
            case "markers": markers_panel.refresh(); break;
            case "history": history_panel.refresh(); break;
            case "info": info_panel.refresh(); break;
            case "properties": properties_panel.refresh(); break;
            case "sound": essential_panel.refresh(); break;
            case "transcript": transcript_panel.refresh(); break;
            case "video": video_panel.refresh(); break;
            case "effects": bind_rack(); break;
            default: break;
            }
        }

        public void bind_rack() {
            if (view_name == "waveform" && doc != null) {
                rack_panel.bind(doc.rack, _("Effects Rack"), true);
            } else if (session != null) {
                var clip = session_page.selected_clip;
                var track = session_page.selected_track;
                if (clip != null) rack_panel.bind(clip.rack, _("Clip: %s").printf(clip.name), false);
                else if (track != null) rack_panel.bind(track.rack, _("Track: %s").printf(track.name), false);
                else rack_panel.bind(session.master.rack, _("Master"), false);
            } else {
                rack_panel.bind(null, _("Effects Rack"), false);
            }
        }

        private Button track(Button b) {
            doc_bubbles.add(b);
            return b;
        }

        private void run(string action, Variant? param = null) {
            activate_action(action, param);
        }

        private void build_bubbles() {
            track(add_bubble_icon("go-previous-symbolic", _("Close (Ctrl+W)"), () => run("close-document")));
            view_switch = new BubbleSwitcher();
            view_switch.add_option("waveform", _("Waveform"));
            view_switch.add_option("multitrack", _("Multitrack"));
            view_switch.add_option("mixer", _("Mixer"));
            view_switch.selected.connect((n) => show_view(n));
            add_bubble_widget(view_switch);
            doc_bubbles.add(view_switch);
            ribbon.attach(this);
            doc_bubbles.add(ribbon.tabs);
            var holder = new Box(Orientation.HORIZONTAL, 0);
            var m = new ContextMenu(holder);
            m.unparent();
            m.add_item(_("Save"), "document-save-symbolic", () => run("save"));
            m.add_item(_("Save As…"), "document-save-as-symbolic", () => run("save-as"));
            m.add_item(_("Save to Online Account…"), "folder-remote-symbolic", () => run("save-online"));
            m.add_separator();
            m.add_item(_("Export Audio…"), "document-send-symbolic", () => run("export"));
            var session_rows = new Gee.ArrayList<Widget>();
            m.add_item(_("Export Stems…"), "document-send-symbolic", () => run("export-stems"));
            session_rows.add(m.get_child().get_last_child());
            m.add_item(_("Export Timeline (OpenTimelineIO)…"), "document-send-symbolic", () => run("export-otio"));
            session_rows.add(m.get_child().get_last_child());
            m.add_item(_("Send Back to Montage"), "mail-send-symbolic", () => run("return-montage"));
            var montage_row = m.get_child().get_last_child();
            m.add_item(_("Export Transcript as Subtitles…"), "text-x-generic-symbolic", () => transcript_panel.export_srt());
            m.add_separator();
            m.add_item(_("Print…"), "document-print-symbolic", () => run("print"));
            m.show.connect(() => {
                foreach (var r in session_rows) r.visible = session != null;
                montage_row.visible = session != null && session.template.has_prefix("montage:");
            });
            var save = add_bubble_menu("document-save-symbolic", _("Save and Export"), m);
            track(save);
            track(add_bubble_icon("sidebar-show-right-symbolic", _("Inspector (F9)"), () => set_panel_visible(!get_panel_visible())));
        }

        private void install_actions() {
            string[] names = {
                "save", "save-as", "save-online", "open-online", "export", "export-stems", "export-otio", "return-montage", "print", "close-document",
                "undo", "redo", "cut", "copy", "paste", "delete", "silence", "crop", "split", "select-all", "marker", "split-markers",
                "zoom-in", "zoom-out", "zoom-fit", "toggle-sidebar", "mode-spectral", "play", "record", "loop", "metronome", "monitor",
                "import", "new-file", "fullscreen"
            };
            foreach (string n in names) {
                var a = new SimpleAction(n, null);
                string name = n;
                a.activate.connect(() => on_action(name));
                add_action(a);
            }
            var proc = new SimpleAction("process", VariantType.STRING);
            proc.activate.connect((v) => process(v.get_string()));
            add_action(proc);
            var view = new SimpleAction("view", VariantType.STRING);
            view.activate.connect((v) => show_view(v.get_string()));
            add_action(view);
        }

        private void on_action(string name) {
            switch (name) {
            case "save": save.begin(false); break;
            case "save-as": save.begin(true); break;
            case "save-online": save_online.begin(); break;
            case "open-online": open_online.begin(); break;
            case "export": open_export(); break;
            case "export-stems": export_stems(); break;
            case "export-otio": export_otio.begin(); break;
            case "return-montage": return_montage.begin(); break;
            case "print": print_document.begin(); break;
            case "close-document": close_document(); break;
            case "undo": undo(); break;
            case "redo": redo(); break;
            case "cut": cut(); break;
            case "copy": copy(); break;
            case "paste": paste(); break;
            case "delete": delete_selection(); break;
            case "silence": process("silence"); break;
            case "crop": process("crop"); break;
            case "split": session_page.split_at_playhead(); break;
            case "select-all": select_all(); break;
            case "marker": add_marker(); break;
            case "split-markers": split_at_markers(); break;
            case "zoom-in": zoom_in(); break;
            case "zoom-out": zoom_out(); break;
            case "zoom-fit": wave.zoom_fit(); session_page.zoom_fit(); break;
            case "toggle-sidebar": set_panel_visible(!get_panel_visible()); break;
            case "fullscreen":
                if (fullscreened) unfullscreen();
                else fullscreen();
                break;
            case "mode-spectral": wave.mode = wave.mode == ViewMode.WAVEFORM ? ViewMode.SPLIT : ViewMode.WAVEFORM; break;
            case "play": toggle_play(); break;
            case "record": transport.record_button.active = !transport.record_button.active; break;
            case "loop": transport.loop_button.active = !transport.loop_button.active; break;
            case "metronome": transport.metronome_button.active = !transport.metronome_button.active; break;
            case "monitor": toggle_monitor(); break;
            case "import": choose_import.begin(); break;
            case "new-file": new_empty_file(); break;
            default: break;
            }
        }

        public void show_view(string n) {
            if (n == "waveform" && doc == null) {
                if (session != null && session_page.selected_clip != null) {
                    edit_clip_in_waveform(session_page.selected_clip);
                    return;
                }
                n = "multitrack";
            }
            if ((n == "multitrack" || n == "mixer") && session == null) {
                if (doc == null) return;
                n = "waveform";
            }
            view_name = n;
            stop_all();
            if (n == "waveform") {
                work.visible_child_name = "waveform";
                player.open(doc);
                player.set_hook(preview_hook);
            } else {
                work.visible_child_name = "multitrack";
                session_page.show_mixer(n == "mixer");
                player.open(session);
                player.set_hook(null);
            }
            view_switch.set_active(n);
            ribbon.sync_view(n, session != null);
            bind_rack();
            refresh_panel(current_panel());
            update_title();
            update_status();
        }

        private void preview_hook(float[] buf, int frames, int64 frame) {
            if (doc != null && doc.rack.has_realtime()) doc.rack.process(buf, frames);
        }

        private void show_welcome() {
            fill_recent();
            view_name = "welcome";
            content.visible_child_name = "welcome";
            foreach (var b in doc_bubbles) b.visible = false;
            set_panel_visible(false);
            set_title(_("Wave"));
            stop_meter();
        }

        private void show_work() {
            content.visible_child_name = "work";
            foreach (var b in doc_bubbles) b.visible = true;
            view_switch.visible = true;
            set_panel_visible(true);
            start_meter();
        }

        private void start_meter() {
            if (meter_timer != 0) return;
            meter_timer = Timeout.add(50, () => {
                var m = player.meter;
                if (!player.playing) m.decay();
                if (recorder.recording) {
                    float[] lv = { recorder.level, recorder.level };
                    transport.meter.set_levels(lv, 2);
                } else {
                    transport.meter.set_levels(m.peak, m.channels);
                }
                if (player.playing) {
                    if (current_panel() == "loudness") loudness_panel.gauge.update(m.momentary, m.short_term, m.integrated);
                    if (current_panel() == "analysis") analysis_panel.live(m);
                    session_page.update_meters();
                }
                return GLib.Source.CONTINUE;
            });
        }

        private void stop_meter() {
            if (meter_timer != 0) GLib.Source.remove(meter_timer);
            meter_timer = 0;
        }

        public void update_title() {
            string t;
            bool modified;
            if (doc != null && view_name == "waveform") {
                t = doc.title;
                modified = doc.modified;
            } else if (session != null) {
                t = session.title;
                modified = session.modified;
            } else {
                set_title(_("Wave"));
                return;
            }
            set_title((modified ? "• " : "") + t);
            ribbon.undo_item.button.sensitive = doc != null && view_name == "waveform" ? doc.can_undo : session != null && session.can_undo;
            ribbon.redo_item.button.sensitive = doc != null && view_name == "waveform" ? doc.can_redo : session != null && session.can_redo;
        }

        public void update_status() {
            int rate = current_rate();
            if (view_name == "waveform" && doc != null) {
                transport.time_label.label = Timecode.clock(player.playing ? player.position : wave.cursor, rate);
                if (wave.has_selection) {
                    transport.sel_label.label = _("Selection %s to %s, %s").printf(Timecode.format(wave.sel_a, rate), Timecode.format(wave.sel_b, rate), Timecode.format(wave.sel_b - wave.sel_a, rate));
                } else {
                    transport.sel_label.label = "%s, %d Hz, %s".printf(Timecode.format(doc.length, rate), doc.rate, doc.channels == 1 ? _("Mono") : doc.channels == 2 ? _("Stereo") : _("%d Channels").printf(doc.channels));
                }
            } else if (session != null) {
                transport.time_label.label = Timecode.clock(player.playing ? player.position : session_page.playhead_frame(), rate);
                int64 a, b;
                if (session_page.time_selection(out a, out b)) transport.sel_label.label = _("Range %s to %s").printf(Timecode.format(a, rate), Timecode.format(b, rate));
                else transport.sel_label.label = _("%d tracks, %s, %.0f BPM").printf(session.tracks.size, Timecode.format(session.length, rate), session.tempo);
            }
            update_title();
        }

        private void on_tick(int64 frame) {
            if (view_name == "waveform") {
                wave.playhead = frame;
                if (frame > wave.scroll + (int64) (wave.get_width() * wave.fpp * 0.95)) wave.scroll_to(frame - (int64) (wave.get_width() * wave.fpp * 0.05));
                wave.queue_draw();
            } else {
                session_page.show_playhead(frame);
                video_panel.sync(frame);
                transcript_panel.highlight(frame);
            }
            if (view_name == "waveform") transcript_panel.highlight(frame);
            transport.time_label.label = Timecode.clock(frame, current_rate());
        }

        public int current_rate() {
            if (view_name == "waveform" && doc != null) return doc.rate;
            if (session != null) return session.rate;
            return doc != null ? doc.rate : 48000;
        }

        public int64 current_length() {
            if (view_name == "waveform" && doc != null) return doc.length;
            return session != null ? session.length : 0;
        }

        public Gee.List<Marker>? current_markers() {
            if (view_name == "waveform" && doc != null) return doc.markers;
            return session != null ? session.markers : null;
        }

        public Metadata? current_metadata() {
            if (view_name == "waveform" && doc != null) return doc.metadata;
            return session != null ? session.metadata : null;
        }

        public string format_summary() {
            if (view_name == "waveform" && doc != null) return "%d Hz, %s, %s".printf(doc.rate, doc.channels == 1 ? _("Mono") : doc.channels == 2 ? _("Stereo") : _("%d Channels").printf(doc.channels), Timecode.format(doc.length, doc.rate));
            if (session != null) return "%d Hz, %s".printf(session.rate, session.channels == 6 ? _("5.1 Surround") : _("Stereo"));
            return "";
        }

        public void mark_modified() {
            if (view_name == "waveform" && doc != null) doc.modified = true;
            else if (session != null) session.modified = true;
            update_title();
        }

        public void history_labels(out string[] labels, out int index) {
            string[] l = {};
            if (view_name == "waveform" && doc != null) {
                foreach (var s in doc.history) l += s.label;
                index = doc.history_index;
            } else if (session != null) {
                foreach (var s in session.history_labels) l += s;
                index = session.history_index;
            } else {
                index = -1;
            }
            labels = l;
        }

        public void restore_history(int i) {
            stop_all();
            if (view_name == "waveform" && doc != null) doc.restore(i);
            else if (session != null) session.restore(i);
            after_edit();
        }

        public void after_edit() {
            update_title();
            update_status();
            if (current_panel() == "history") history_panel.refresh();
            if (current_panel() == "markers") markers_panel.refresh();
            session_page.refresh();
            wave.queue_draw();
        }

        public void choose_open() {
            Dialogs.open.begin(this, _("Open"), _("Audio files and sessions"), Dialogs.audio_suffixes(), (o, r) => {
                var f = Dialogs.open.end(r);
                if (f != null) open_file(f);
            });
        }

        public void open_file(File file) {
            string? path = file.get_path();
            if (path == null) return;
            string lower = path.down();
            if (lower.has_suffix(".wave")) {
                load_session.begin(() => SessionFile.load(path), path);
            } else if (lower.has_suffix(".sesx")) {
                load_session.begin(() => Interchange.import_sesx(path), null);
            } else if (lower.has_suffix(".otio")) {
                load_session.begin(() => Interchange.import_otio(path, app.rate_setting()), null);
            } else if (lower.has_suffix(".montage")) {
                open_montage(path);
            } else if (lower.has_suffix(".cue")) {
                string? audio;
                var marks = Interchange.read_cue(path, 48000, out audio);
                if (audio != null) open_audio.begin(audio, path);
            } else {
                open_audio.begin(path, null);
            }
            RecentManager.get_default().add_full(file.get_uri(), RecentData() { app_name = "Wave", app_exec = "singularity-wave %u", mime_type = lower.has_suffix(".wave") ? "application/x-wave-session" : "audio/x-wav" });
        }

        public void open_montage(string path) {
            load_session.begin(() => Interchange.import_montage(path, app.rate_setting()), null);
        }

        public delegate Session SessionLoader() throws Error;

        private async void load_session(owned SessionLoader loader, string? path) {
            if (!confirm_replace()) return;
            set_busy(true);
            Session? s = null;
            Error? err = null;
            SourceFunc cb = load_session.callback;
            new Thread<void>("wave-load", () => {
                try {
                    s = loader();
                } catch (Error e) {
                    err = e;
                }
                Idle.add((owned) cb);
            });
            yield;
            set_busy(false);
            if (err != null) {
                show_error(_("Could Not Open"), err.message);
                return;
            }
            bind_session(s);
        }

        private async void open_audio(string path, string? cue) {
            set_busy(true);
            var dec = new Decoder();
            dec.progress.connect((f) => busy.fraction = f);
            try {
                var media = yield dec.decode(path);
                if (cue != null) {
                    string? audio;
                    media.markers.clear();
                    media.markers.add_all(Interchange.read_cue(cue, media.source.rate, out audio));
                }
                set_busy(false);
                if (session != null && view_name != "waveform") {
                    var t = session_page.selected_track ?? (session.tracks.size > 0 ? session.tracks[0] : session.add_track(_("Track 1")));
                    var c = session.add_clip(t, media.source, path, session_page.playhead_frame());
                    SessionFile.pool(session).id_for(media.source, path);
                    c.name = Path.get_basename(path);
                    session.checkpoint(_("Import"));
                    after_edit();
                    return;
                }
                set_document(Document.from_media(media));
            } catch (Error e) {
                set_busy(false);
                show_error(_("Could Not Open"), e.message);
            }
        }

        private async void choose_import() {
            var files = yield Dialogs.open_many(this, _("Import Audio"));
            if (files == null) return;
            for (uint i = 0; i < files.get_n_items(); i++) {
                var f = (File) files.get_item(i);
                if (session != null) import_into_session(f.get_path(), session_page.playhead_frame());
                else open_file(f);
            }
        }

        public void import_into_session(string path, int64 at) {
            if (session == null) return;
            try {
                var media = Decoder.decode_sync(path);
                var t = session_page.selected_track;
                if (t == null || t.kind != TrackKind.AUDIO) {
                    foreach (var tr in session.tracks) {
                        if (tr.kind == TrackKind.AUDIO && tr.clip_at(at) == null) {
                            t = tr;
                            break;
                        }
                    }
                }
                if (t == null) t = session.add_track(Path.get_basename(path));
                if (media.has_video && session.video_track() == null) {
                    var vt = session.add_track(_("Video"), TrackKind.VIDEO);
                    vt.video_segments.add(new VideoSegment(File.new_for_path(path).get_uri(), at, 0, media.source.frames * 1000 / media.source.rate));
                    session.tracks.remove(vt);
                    session.tracks.insert(0, vt);
                }
                var c = session.add_clip(t, media.source, path, at);
                SessionFile.pool(session).id_for(media.source, path);
                c.name = Path.get_basename(path);
                session.checkpoint(_("Import"));
                after_edit();
            } catch (Error e) {
                show_error(_("Could Not Import"), e.message);
            }
        }

        private bool confirm_replace() {
            return true;
        }

        public void set_document(Document d) {
            stop_all();
            doc = d;
            doc.rack.isolate_plugins = app.flag("isolate-plugins", true);
            doc.changed.connect(() => after_edit());
            doc.markers_changed.connect(() => {
                if (current_panel() == "markers") markers_panel.refresh();
            });
            doc.rack.plugin_crashed.connect((e, msg) => add_toast(new Toast(_("%s: %s").printf(e.title, msg))));
            wave.set_document(doc);
            show_work();
            show_view("waveform");
            if (session == null) view_switch_sensitivity();
        }

        public void bind_session(Session s) {
            stop_all();
            session = s;
            foreach (var t in s.tracks) t.rack.isolate_plugins = app.flag("isolate-plugins", true);
            s.changed.connect(() => after_edit());
            s.structure_changed.connect(() => session_page.rebuild());
            s.mixer.recorder = automation;
            session_page.bind_session(s);
            show_work();
            show_view("multitrack");
            view_switch_sensitivity();
        }

        private void view_switch_sensitivity() {
        }

        public void new_session(string kind) {
            int rate = app.rate_setting();
            Session s;
            if (kind == "podcast") s = Templates.podcast(rate, LoudnessTarget.find(app.str("loudness-target", "podcast")).lufs);
            else if (kind == "surround") s = Templates.surround(rate);
            else s = Templates.empty(rate, 2);
            bind_session(s);
            set_panel_visible(true);
        }

        private void new_empty_file() {
            try {
                var src = PcmSource.from_samples(new float[0], app.rate_setting(), 2);
                set_document(Document.from_source(src, _("Untitled")));
            } catch (Error e) {
                show_error(_("Could Not Create"), e.message);
            }
        }

        private void record_new_file() {
            new_empty_file();
            Idle.add(() => {
                transport.record_button.active = true;
                return GLib.Source.REMOVE;
            });
        }

        public void edit_clip_in_waveform(Clip c) {
            try {
                var buf = new float[c.length * c.source.channels];
                c.source.read(c.source_offset, c.length, buf);
                var d = Document.from_source(PcmSource.from_samples(buf, c.source.rate, c.source.channels), c.name);
                d.path = "";
                d.title = c.name;
                set_document(d);
                editing_clip = c;
            } catch (Error e) {
                show_error(_("Could Not Open the Clip"), e.message);
            }
        }

        private Clip? editing_clip = null;

        public void return_clip_to_session() {
            if (editing_clip == null || session == null || doc == null) return;
            try {
                var buf = doc.read(0, doc.length);
                var src = PcmSource.from_samples(buf, doc.rate, doc.channels);
                editing_clip.source = src;
                editing_clip.source_offset = 0;
                editing_clip.length = doc.length;
                editing_clip.rendered = null;
                SessionFile.pool(session).id_for(src, "");
                session.checkpoint(_("Edit Clip"));
            } catch (Error e) {
                show_error(_("Could Not Update the Clip"), e.message);
            }
            editing_clip = null;
            doc = null;
            show_view("multitrack");
        }

        public void close_document() {
            stop_all();
            if (view_name == "waveform" && editing_clip != null) {
                return_clip_to_session();
                return;
            }
            bool dirty = (view_name == "waveform" && doc != null && doc.modified) || (view_name != "waveform" && session != null && session.modified);
            if (dirty) {
                Dialogs.confirm(this, _("Close Without Saving?"), _("Your changes will be lost."), _("Close"), () => do_close_document());
                return;
            }
            do_close_document();
        }

        private void do_close_document() {
            if (view_name == "waveform") {
                doc = null;
                wave.set_document(null);
                if (session != null) {
                    show_view("multitrack");
                    return;
                }
            } else {
                session = null;
                if (doc != null) {
                    show_view("waveform");
                    return;
                }
            }
            show_welcome();
        }

        private bool on_close_request() {
            if (close_confirmed) return false;
            bool dirty = (doc != null && doc.modified) || (session != null && session.modified);
            if (!dirty) {
                stop_all();
                return false;
            }
            Dialogs.confirm(this, _("Quit Without Saving?"), _("You have unsaved changes."), _("Quit"), () => {
                close_confirmed = true;
                stop_all();
                close();
            });
            return true;
        }

        public void set_busy(bool on) {
            busy.visible = on;
            busy.fraction = 0;
            if (on) busy.pulse();
        }

        public void show_error(string title, string message) {
            var dlg = new ConfirmDialog.message(app, title, null, message);
            dlg.transient_for = this;
            dlg.present();
        }

        public void toast(string text) {
            add_toast(new Toast(text));
        }

        public void toggle_play() {
            if (player.playing) {
                stop_all();
                return;
            }
            if (view_name == "waveform" && doc != null) {
                player.open(doc);
                player.set_hook(preview_hook);
                player.looping = transport.loop_button.active && wave.has_selection;
                player.loop_start = wave.sel_a;
                player.loop_end = wave.sel_b;
                player.stop_at = wave.has_selection && !player.looping ? wave.sel_b : -1;
                player.meter.reset_loudness();
                player.play(wave.has_selection ? wave.sel_a : wave.cursor);
            } else if (session != null) {
                try {
                    session.mixer.prepare_clips();
                } catch (Error e) {
                    show_error(_("Could Not Render Clips"), e.message);
                }
                session.mixer.include_metronome = true;
                player.open(session);
                int64 a, b;
                bool range = session_page.time_selection(out a, out b);
                player.looping = transport.loop_button.active && range;
                player.loop_start = a;
                player.loop_end = b;
                player.stop_at = -1;
                player.meter.reset_loudness();
                player.play(range && player.looping ? a : session_page.playhead_frame());
            } else {
                return;
            }
            transport.set_playing(true);
        }

        public void stop_all() {
            if (recorder.recording) stop_recording();
            player.stop();
            transport.set_playing(false);
            wave.playhead = -1;
            session_page.show_playhead(-1);
            if (session != null) session.mixer.include_metronome = false;
        }

        private void move_to(int64 f) {
            if (view_name == "waveform") {
                wave.cursor = f;
                wave.set_selection(f, f);
                wave.ensure_visible(f);
            } else {
                session_page.move_cursor(f);
            }
            if (player.playing) player.play(f);
            update_status();
        }

        private void zoom_in() {
            if (view_name == "waveform") wave.zoom(0.5);
            else session_page.zoom(0.5);
        }

        private void zoom_out() {
            if (view_name == "waveform") wave.zoom(2);
            else session_page.zoom(2);
        }

        private void undo() {
            stop_all();
            if (view_name == "waveform" && doc != null) doc.undo();
            else if (session != null) session.undo();
            after_edit();
        }

        private void redo() {
            stop_all();
            if (view_name == "waveform" && doc != null) doc.redo();
            else if (session != null) session.redo();
            after_edit();
        }

        private void select_all() {
            if (view_name == "waveform" && doc != null) wave.set_selection(0, doc.length);
            else session_page.select_all();
        }

        private void copy() {
            if (view_name == "waveform" && doc != null && wave.has_selection) {
                clipboard = doc.copy_range(wave.sel_a, wave.sel_b);
                clipboard_rate = doc.rate;
                clipboard_channels = doc.channels;
            } else if (session != null) {
                clip_clipboard.clear();
                foreach (var c in session_page.selected_clips()) clip_clipboard.add(c.duplicate());
            }
        }

        private void cut() {
            copy();
            delete_selection();
        }

        private void paste() {
            stop_all();
            if (view_name == "waveform" && doc != null && clipboard.length > 0) {
                if (clipboard_channels != doc.channels || clipboard_rate != doc.rate) {
                    toast(_("The copied audio has a different format"));
                    return;
                }
                int64 at = wave.has_selection ? wave.sel_a : wave.cursor;
                if (wave.has_selection) doc.replace(wave.sel_a, wave.sel_b, clipboard, _("Paste"));
                else doc.insert(at, clipboard);
                int64 len = 0;
                foreach (var s in clipboard) len += s.length;
                wave.set_selection(at, at + len);
            } else if (session != null && clip_clipboard.size > 0) {
                session_page.paste_clips(clip_clipboard);
            }
        }

        private void delete_selection() {
            stop_all();
            if (view_name == "waveform" && doc != null && wave.has_selection) {
                int64 a = wave.sel_a;
                doc.delete_range(wave.sel_a, wave.sel_b);
                wave.set_selection(a, a);
            } else if (session != null) {
                session_page.delete_selected();
            }
        }

        public delegate void DocOp() throws Error;

        public void run_doc(DocOp op) {
            stop_all();
            try {
                op();
            } catch (Error e) {
                show_error(_("Could Not Process"), e.message);
            }
            after_edit();
        }

        private void sel_range(out int64 a, out int64 b) {
            a = wave.sel_a;
            b = wave.sel_b;
            if (b <= a) {
                a = 0;
                b = doc.length;
            }
        }

        public void process(string what) {
            if (view_name != "waveform" || doc == null) {
                if (session != null) session_page.process_clip(what);
                return;
            }
            int64 a, b;
            sel_range(out a, out b);
            switch (what) {
            case "silence":
                if (wave.has_selection) run_doc(() => doc.silence(a, b));
                break;
            case "crop":
                if (wave.has_selection) run_doc(() => doc.trim_to(a, b));
                wave.zoom_fit();
                break;
            case "invert": run_doc(() => Processes.invert(doc, a, b)); break;
            case "reverse": run_doc(() => Processes.reverse(doc, a, b)); break;
            case "dc": run_doc(() => Processes.remove_dc(doc, a, b)); break;
            case "fade-in": run_doc(() => Processes.fade(doc, a, b, true, wave.fade_curve)); break;
            case "fade-out": run_doc(() => Processes.fade(doc, a, b, false, wave.fade_curve)); break;
            case "capture-noise":
                if (!wave.has_selection) {
                    toast(_("Select a part with only noise first"));
                    return;
                }
                Processes.capture_noise(doc, a, b);
                toast(_("Noise print captured from %s").printf(Timecode.format(b - a, doc.rate)));
                break;
            case "rack": run_doc(() => Processes.apply_rack(doc, a, b, doc.rack)); break;
            case "enhance": run_doc(() => Processes.enhance_speech(doc, a, b, 0.6)); break;
            case "heal":
                run_doc(() => {
                    int n = Processes.spot_heal(doc, a, b, 20, doc.rate / 2);
                    toast(ngettext("%d spot repaired", "%d spots repaired", n).printf(n));
                });
                break;
            case "separate": ProcessDialogs.separate_voice(this, doc, a, b); break;
            case "model-denoise": ProcessDialogs.model_denoise(this, doc, a, b); break;
            default:
                ProcessDialogs.open(this, what, doc, a, b);
                break;
            }
        }

        public void spectral_apply(WaveDsp.SpectralMode mode, double gain) {
            if (doc == null) return;
            int fft = 2048, hop = 512;
            int64 start;
            int cols, bins;
            var mask = wave.spectral_mask(fft, hop, out start, out cols, out bins);
            if (mask == null) {
                toast(_("Draw a selection in the spectral display first"));
                return;
            }
            run_doc(() => Processes.spectral(doc, start, mask, cols, bins, fft, hop, mode, gain));
            wave.spectral_sel = null;
        }

        public bool selection_mono(out float[]? mono, out int rate) {
            mono = null;
            rate = current_rate();
            Renderable? src = null;
            int64 a = 0, b = 0;
            if (view_name == "waveform" && doc != null) {
                src = doc;
                a = wave.sel_a;
                b = wave.sel_b;
                if (b <= a) {
                    a = 0;
                    b = int64.min(doc.length, doc.rate * 30);
                }
            } else if (session != null) {
                src = session;
                if (!session_page.time_selection(out a, out b)) {
                    a = 0;
                    b = int64.min(session.length, session.rate * 30);
                }
            }
            if (src == null || b <= a) return false;
            b = int64.min(b, a + rate * 120);
            int ch = src.channel_count;
            var buf = new float[(b - a) * ch];
            src.render(a, (int) (b - a), buf);
            var m = new float[b - a];
            for (int64 i = 0; i < b - a; i++) {
                float s = 0;
                for (int c = 0; c < ch; c++) s += buf[i * ch + c];
                m[i] = s / ch;
            }
            mono = m;
            return true;
        }

        public void add_marker() {
            int64 at;
            if (view_name == "waveform" && doc != null) {
                at = player.playing ? player.position : wave.cursor;
                var m = new Marker(_("Marker %d").printf(doc.markers.size + 1), at, wave.has_selection && !player.playing ? wave.sel_b - wave.sel_a : 0, "chapter");
                if (wave.has_selection && !player.playing) m.start = wave.sel_a;
                doc.add_marker(m);
            } else if (session != null) {
                at = player.playing ? player.position : session_page.playhead_frame();
                session.markers.add(new Marker(_("Marker %d").printf(session.markers.size + 1), at, 0, "chapter"));
                session.markers.sort(Marker.compare);
                session.checkpoint(_("Add Marker"));
                after_edit();
            }
            if (current_panel() == "markers") markers_panel.refresh();
        }

        public void remove_marker(Marker m) {
            if (view_name == "waveform" && doc != null) doc.remove_marker(m);
            else if (session != null) {
                session.markers.remove(m);
                session.checkpoint(_("Remove Marker"));
            }
            after_edit();
        }

        public void markers_edited(string label) {
            if (view_name == "waveform" && doc != null) {
                doc.markers.sort(Marker.compare);
                doc.marker_checkpoint(label);
            } else if (session != null) {
                session.markers.sort(Marker.compare);
                session.checkpoint(label);
            }
            after_edit();
        }

        public void go_to_marker(Marker m) {
            if (view_name == "waveform") {
                wave.set_selection(m.start, m.is_range ? m.end : m.start);
                wave.ensure_visible(m.start);
            } else {
                session_page.move_cursor(m.start);
            }
            update_status();
        }

        public void split_at_markers() {
            if (doc == null) return;
            var points = doc.split_points();
            if (points.length == 0) {
                toast(_("Add markers where the file should be split"));
                return;
            }
            Dialogs.folder.begin(this, _("Choose a Folder for the Parts"), (o, r) => {
                var dir = Dialogs.folder.end(r);
                if (dir == null) return;
                export_parts.begin(dir.get_path(), points);
            });
        }

        private async void export_parts(string dir, int64[] points) {
            int64[] edges = { 0 };
            foreach (var p in points) edges += p;
            edges += doc.length;
            set_busy(true);
            int n = 0;
            for (int i = 0; i + 1 < edges.length; i++) {
                if (edges[i + 1] <= edges[i]) continue;
                var o = export_defaults(ExportFormat.WAV);
                o.start = edges[i];
                o.end = edges[i + 1];
                string name = "%02d %s.wav".printf(i + 1, i > 0 && i - 1 < doc.markers.size ? doc.markers[i - 1].name : doc.title.replace(".wav", ""));
                try {
                    yield new Exporter().export(doc, Path.build_filename(dir, name.replace("/", "-")), o);
                    n++;
                } catch (Error e) {
                    show_error(_("Could Not Export"), e.message);
                    break;
                }
            }
            set_busy(false);
            toast(ngettext("%d file written", "%d files written", n).printf(n));
        }

        public void import_markers() {
            Dialogs.open.begin(this, _("Import Markers"), _("CUE sheets and podcast chapters"), { "cue", "json" }, (o, r) => {
                var f = Dialogs.open.end(r);
                if (f == null) return;
                int rate = current_rate();
                string? audio;
                var list = f.get_path().down().has_suffix(".cue") ? Interchange.read_cue(f.get_path(), rate, out audio) : Interchange.read_chapters_json(f.get_path(), rate);
                var target = current_markers();
                if (target == null) return;
                target.add_all(list);
                markers_edited(_("Import Markers"));
            });
        }

        public void export_markers(string kind) {
            var list = current_markers();
            if (list == null) return;
            string base_name = (view_name == "waveform" && doc != null ? doc.title : session != null ? session.title : "markers");
            Dialogs.save.begin(this, _("Export Markers"), base_name + (kind == "cue" ? ".cue" : ".chapters.json"), kind == "cue" ? _("CUE sheet") : _("Podcast chapters"), { kind == "cue" ? "cue" : "json" }, (o, r) => {
                var f = Dialogs.save.end(r);
                if (f == null) return;
                try {
                    if (kind == "cue") {
                        string audio = f.get_path().substring(0, f.get_path().length - 4) + ".wav";
                        Interchange.write_cue(audio, Path.get_basename(audio), ExportFormat.WAV, current_metadata(), list, current_rate());
                    } else {
                        Interchange.write_chapters_json(f.get_path(), list, current_rate());
                    }
                    toast(_("Markers exported"));
                } catch (Error e) {
                    show_error(_("Could Not Export"), e.message);
                }
            });
        }

        public ExportOptions export_defaults(ExportFormat f) {
            var o = new ExportOptions();
            o.format = f;
            string bd = app.str("bit-depth", "24");
            o.is_float = bd == "32f";
            o.bits = bd == "16" ? 16 : 24;
            o.dither = app.flag("dither", true);
            return o;
        }

        public void open_export() {
            if (view_name == "waveform" && doc != null) ExportDialog.show_for(this, doc, doc.title, doc.metadata, doc.markers, wave.has_selection ? wave.sel_a : 0, wave.has_selection ? wave.sel_b : -1);
            else if (session != null) ExportDialog.show_for(this, session, session.title, session.metadata, session.markers, 0, -1);
        }

        private void export_stems() {
            if (session == null) return;
            ExportDialog.stems(this, session);
        }

        private async void export_otio() {
            if (session == null) return;
            var f = yield Dialogs.save(this, _("Export Timeline"), session.title + ".otio", "OpenTimelineIO", { "otio" });
            if (f == null) return;
            try {
                FileUtils.set_contents(f.get_path(), Interchange.export_otio(session));
                toast(_("Timeline exported"));
            } catch (Error e) {
                show_error(_("Could Not Export"), e.message);
            }
        }

        private async void return_montage() {
            if (session == null || !session.template.has_prefix("montage:")) return;
            string montage = session.template.substring(8);
            string mix = Path.build_filename(Path.get_dirname(montage), Path.get_basename(montage).replace(".montage", "") + " Wave Mix.wav");
            set_busy(true);
            try {
                var o = export_defaults(ExportFormat.WAV);
                yield new Exporter().export(session, mix, o);
                Interchange.return_to_montage(montage, mix, session.length * Gst.SECOND / session.rate);
                toast(_("The mix is back in Montage"));
            } catch (Error e) {
                show_error(_("Could Not Send Back"), e.message);
            }
            set_busy(false);
        }

        public async void save(bool as_new) {
            if (view_name == "waveform" && doc != null) {
                if (editing_clip != null) {
                    return_clip_to_session();
                    return;
                }
                string path = doc.path;
                bool native = path != "" && (path.down().has_suffix(".wav") || path.down().has_suffix(".flac") || path.down().has_suffix(".aiff") || path.down().has_suffix(".mp3") || path.down().has_suffix(".ogg") || path.down().has_suffix(".opus") || path.down().has_suffix(".m4a") || path.down().has_suffix(".caf"));
                if (as_new || !native) {
                    ExportDialog.show_for(this, doc, doc.title, doc.metadata, doc.markers, 0, -1, true);
                    return;
                }
                var fmt = ExportFormat.WAV;
                foreach (var f in ExportFormat.all()) {
                    if (path.down().has_suffix("." + f.extension())) fmt = f;
                }
                yield write_document(path, export_defaults(fmt));
                return;
            }
            if (session == null) return;
            string target = session.path;
            if (as_new || target == "") {
                var f = yield Dialogs.save(this, _("Save Session"), (session.title != "" ? session.title : _("Untitled")) + ".wave", _("Wave session"), { "wave" });
                if (f == null) return;
                target = Dialogs.ensure_suffix(f.get_path(), "wave");
            }
            try {
                SessionFile.save(session, target);
                session.title = Path.get_basename(target).replace(".wave", "");
                CloudActions.sync_back(this, File.new_for_path(target));
                toast(_("Saved"));
            } catch (Error e) {
                show_error(_("Could Not Save"), e.message);
            }
            update_title();
        }

        public async void write_document(string path, ExportOptions o) {
            o.metadata = doc.metadata;
            o.markers = doc.markers;
            set_busy(true);
            string tmp = path + ".saving";
            var ex = new Exporter();
            ex.progress.connect((f) => busy.fraction = f);
            try {
                yield ex.export(doc, tmp, o);
                FileUtils.rename(tmp, path);
                doc.modified = false;
                doc.path = path;
                doc.title = Path.get_basename(path);
                CloudActions.sync_back(this, File.new_for_path(path));
                toast(_("Saved"));
            } catch (Error e) {
                FileUtils.unlink(tmp);
                show_error(_("Could Not Save"), e.message);
            }
            set_busy(false);
            update_title();
        }

        private async void save_online() {
            yield CloudActions.save(this);
        }

        private async void open_online() {
            yield CloudActions.open(this, (f) => open_file(f));
        }

        private async void print_document() {
            if (view_name == "waveform" && doc != null) {
                var src = new WavePrintSource.for_document(doc, current_transcript());
                yield Singularity.Print.run_source(this, src);
            } else if (session != null) {
                var src = new WavePrintSource.for_session(session, current_transcript());
                yield Singularity.Print.run_source(this, src);
            }
        }

        public Transcript? current_transcript() {
            string json = view_name == "waveform" && doc != null ? doc.transcript_json : session != null ? session.transcript_json : "";
            return Transcript.from_json(json);
        }

        public async void analyze_loudness() {
            Renderable? src = view_name == "waveform" ? (Renderable?) doc : (Renderable?) session;
            if (src == null) return;
            loudness_panel.set_busy(true);
            LoudnessResult? r = null;
            if (session != null && src == session) {
                try {
                    session.mixer.prepare_clips();
                } catch (Error e) {
                }
            }
            SourceFunc cb = analyze_loudness.callback;
            new Thread<void>("wave-loudness", () => {
                r = Loudness.measure_renderable(src);
                Idle.add((owned) cb);
            });
            yield;
            loudness_panel.set_busy(false);
            loudness_panel.show_result(r);
        }

        public async void normalize_loudness(double lufs, double ceiling) {
            if (view_name == "waveform" && doc != null) {
                int64 a, b;
                sel_range(out a, out b);
                run_doc(() => Processes.normalize_loudness(doc, a, b, lufs, ceiling));
                yield analyze_loudness();
                return;
            }
            if (session == null) return;
            loudness_panel.set_busy(true);
            LoudnessResult? r = null;
            try {
                session.mixer.prepare_clips();
            } catch (Error e) {
            }
            SourceFunc cb = normalize_loudness.callback;
            new Thread<void>("wave-loudness", () => {
                r = Loudness.measure_renderable(session);
                Idle.add((owned) cb);
            });
            yield;
            if (r != null && r.integrated.is_finite()) {
                session.master.volume_db += lufs - r.integrated;
                bool has_limiter = false;
                foreach (var e in session.master.rack.effects) {
                    if (e.kind == "limiter") {
                        e.set_value("threshold", ceiling);
                        has_limiter = true;
                    }
                }
                if (!has_limiter && r.true_peak + (lufs - r.integrated) > ceiling) {
                    var lim = EffectRegistry.create("limiter");
                    lim.set_value("threshold", ceiling);
                    session.master.rack.add(lim);
                }
                session.loudness_target = lufs;
                session.checkpoint(_("Match Loudness"));
                after_edit();
            }
            loudness_panel.set_busy(false);
            yield analyze_loudness();
        }

        public void open_batch() {
            BatchDialog.show_batch(this);
        }

        public void open_match() {
            BatchDialog.show_match(this);
        }

        private void on_param_touched(Effect e, EffectParam p, bool active) {
        }

        public void start_recording() {
            var dev = app.devices.find(session != null && session_page.armed_input() != null ? session_page.armed_input() : "");
            if (TestInput.source() != null) dev = app.devices.find("test");
            int rate = current_rate();
            try {
                if (view_name == "waveform" && doc != null) {
                    recording_session = false;
                    record_start = doc.length;
                    recorder.start_frame = doc.length;
                    recorder.punch_in = -1;
                    recorder.punch_out = -1;
                    recorder.start(dev, doc.rate, doc.channels, null);
                } else if (session != null) {
                    if (session_page.armed_tracks().size == 0) {
                        toast(_("Arm a track for recording first"));
                        transport.record_button.active = false;
                        return;
                    }
                    recording_session = true;
                    int64 a, b;
                    bool punch = session_page.time_selection(out a, out b) && transport.loop_button.active == false && session_page.punch_mode;
                    int64 preroll = punch ? (int64) app.num("preroll", 2) * rate : 0;
                    int64 start = punch ? int64.max(0, a - preroll) : session_page.playhead_frame();
                    record_start = start;
                    recorder.start_frame = start;
                    recorder.punch_in = punch ? a : -1;
                    recorder.punch_out = punch ? b : -1;
                    string media = session.path != "" ? SessionFile.media_dir(session.path) : PcmSource.cache_dir();
                    DirUtils.create_with_parents(media, 0755);
                    var armed = session_page.armed_tracks();
                    int ch = armed[0].channels;
                    recorder.start(dev, session.rate, ch, null);
                    try {
                        session.mixer.prepare_clips();
                    } catch (Error e) {
                    }
                    session.mixer.include_metronome = true;
                    player.open(session);
                    player.stop_at = -1;
                    player.looping = false;
                    player.endless = true;
                    player.play(start);
                    transport.set_playing(true);
                }
                toast(_("Recording from %s").printf(dev.label));
            } catch (Error e) {
                transport.record_button.active = false;
                show_error(_("Recording Failed"), e.message);
            }
        }

        public void stop_recording() {
            player.endless = false;
            recorder.stop();
            transport.record_button.active = false;
            if (player.playing) {
                player.stop();
                transport.set_playing(false);
            }
        }

        private void on_recorded(PcmSource? src, int64 at) {
            if (src == null) return;
            if (!recording_session && doc != null) {
                doc.insert(doc.length, { new Segment(src, 0, src.frames) }, _("Record"));
                wave.zoom_fit();
                after_edit();
                return;
            }
            if (session == null) return;
            foreach (var t in session_page.armed_tracks()) {
                var existing = t.clip_at(at + 1);
                if (existing != null && recorder.punch_in >= 0 && existing.position <= at && existing.end >= at + src.frames) {
                    if (existing.takes.size == 0) existing.takes.add(new Take(existing.source, existing.path, existing.source_offset, _("Take 1")));
                    var punch_clip = session.add_clip(t, src, "", at);
                    punch_clip.name = _("Take %d").printf(existing.takes.size + 1);
                    punch_clip.fade_in = session.rate / 200;
                    punch_clip.fade_out = session.rate / 200;
                    punch_clip.takes.add(new Take(src, "", 0, punch_clip.name));
                    punch_clip.active_take = 0;
                } else {
                    var c = session.add_clip(t, src, "", at);
                    c.name = _("Recording %s").printf(new DateTime.now_local().format("%H:%M:%S"));
                }
                SessionFile.pool(session).id_for(src, "");
            }
            session.checkpoint(_("Record"));
            after_edit();
        }

        private void toggle_monitor() {
            if (recorder.monitoring) {
                recorder.stop_monitor();
                toast(_("Input monitoring off"));
                return;
            }
            var dev = app.devices.find(TestInput.source() != null ? "test" : (session_page.armed_input() ?? ""));
            int lat = int.parse(app.str("monitor-latency", "128"));
            try {
                recorder.start_monitor(dev, current_rate(), 2, lat);
                Timeout.add(500, () => {
                    int64 ns = recorder.monitor_latency_ns();
                    toast(ns >= 0 ? _("Monitoring with %.1f ms of latency").printf(ns / 1e6) : _("Monitoring the input"));
                    return GLib.Source.REMOVE;
                });
            } catch (Error e) {
                show_error(_("Monitoring Failed"), e.message);
            }
        }
    }
}
