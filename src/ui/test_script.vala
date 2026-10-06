using Gtk;

namespace Singularity.Apps.Wave {

    public class TestScript : Object {
        private static bool started = false;
        private WaveWindow win;
        private string[] lines;
        private int index = 0;

        public static void maybe_run(WaveWindow win) {
            string? path = Environment.get_variable("SINGULARITY_WAVE_TEST_SCRIPT");
            if (path == null || started) return;
            started = true;
            string text;
            try {
                FileUtils.get_contents(path, out text);
            } catch (Error e) {
                printerr("script: %s\n", e.message);
                return;
            }
            var s = new TestScript();
            s.win = win;
            s.lines = text.split("\n");
            s.ref();
            Timeout.add(1200, () => {
                s.step();
                return GLib.Source.REMOVE;
            });
        }

        private void step() {
            while (index < lines.length) {
                string line = lines[index++].strip();
                if (line == "" || line.has_prefix("#")) continue;
                uint wait = 500;
                try {
                    wait = run(line);
                } catch (Error e) {
                    printerr("script: %s failed: %s\n", line, e.message);
                }
                printerr("script: ok %s\n", line);
                Timeout.add(wait, () => {
                    step();
                    return GLib.Source.REMOVE;
                });
                return;
            }
            printerr("script: finished\n");
            unref();
        }

        private static Gtk.Widget? find_label(Gtk.Widget w, string text) {
            if (w is Gtk.Button && ((Gtk.Button) w).label == text && w.is_visible()) return w;
            if (w is Gtk.Label && ((Gtk.Label) w).label == text && w.is_visible()) return w;
            for (var c = w.get_first_child(); c != null; c = c.get_next_sibling()) {
                var r = find_label(c, text);
                if (r != null) return r;
            }
            return null;
        }

        private void shot(string name) throws Error {
            string dir = Environment.get_variable("WAVE_SHOTS") ?? Environment.get_tmp_dir();
            string[] argv = { "grim", Path.build_filename(dir, name + ".png") };
            int status;
            Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
        }

        private static Gtk.Widget? find_anywhere(string text) {
            foreach (var tl in Gtk.Window.list_toplevels()) {
                if (!tl.is_visible()) continue;
                var r = find_label(tl, text);
                if (r != null) return r;
            }
            return null;
        }

        private double sec(string s) {
            return double.parse(s);
        }

        private uint run(string line) throws Error {
            string[] a = line.split(" ");
            string rest = line.length > a[0].length ? line.substring(a[0].length + 1) : "";
            int rate = win.current_rate();
            switch (a[0]) {
            case "sleep":
                return (uint) int.parse(a[1]);
            case "open":
                win.open_file(File.new_for_path(rest));
                return 2500;
            case "session":
                win.new_session(a[1]);
                return 1200;
            case "import":
                win.import_into_session(rest, win.session_page.cursor);
                return 1500;
            case "view":
                win.show_view(a[1]);
                return 700;
            case "panel":
                win.set_panel_visible(true);
                win.show_panel(a[1]);
                return 700;
            case "sidebar":
                win.set_panel_visible(a[1] == "on");
                return 400;
            case "select":
                if (win.view_name == "waveform") win.wave.set_selection((int64) (sec(a[1]) * rate), (int64) (sec(a[2]) * rate));
                else win.session_page.set_time_selection((int64) (sec(a[1]) * rate), (int64) (sec(a[2]) * rate));
                return 400;
            case "cursor":
                if (win.view_name == "waveform") win.wave.set_selection((int64) (sec(a[1]) * rate), (int64) (sec(a[1]) * rate));
                else win.session_page.move_cursor((int64) (sec(a[1]) * rate));
                return 300;
            case "mode":
                win.wave.mode = a[1] == "spectral" ? ViewMode.SPECTRAL : a[1] == "split" ? ViewMode.SPLIT : ViewMode.WAVEFORM;
                return 1500;
            case "spectral-rect":
                win.wave.tool = SpectralTool.RECTANGLE;
                return 300;
            case "spectral-box":
                win.wave.select_spectral_box((int64) (sec(a[1]) * rate), (int64) (sec(a[2]) * rate), double.parse(a[3]), double.parse(a[4]));
                return 600;
            case "spectral-apply":
                win.spectral_apply(a[1] == "heal" ? WaveDsp.SpectralMode.HEAL : WaveDsp.SpectralMode.ATTENUATE, double.parse(a.length > 2 ? a[2] : "-40"));
                return 2500;
            case "batch":
                win.open_batch();
                return 1200;
            case "match":
                win.open_match();
                return 1200;
            case "montage":
                win.open_montage(rest);
                return 3000;
            case "zoom":
                if (a[1] == "fit") {
                    win.wave.zoom_fit();
                    win.session_page.zoom_fit();
                } else if (a[1] == "sel") {
                    win.wave.zoom_selection();
                } else {
                    win.wave.zoom(double.parse(a[1]));
                }
                return 600;
            case "play":
                win.toggle_play();
                return (uint) int.parse(a.length > 1 ? a[1] : "1000");
            case "stop":
                win.stop_all();
                return 300;
            case "process":
                win.process(a[1]);
                return 1500;
            case "action":
                win.activate_action(a[1], a.length > 2 ? new Variant.string(a[2]) : null);
                return 1200;
            case "marker":
                win.add_marker();
                return 300;
            case "rack-add":
                var rack = win.rack_panel.rack;
                if (rack != null) {
                    var e = EffectRegistry.create(a[1]);
                    if (e != null) rack.add(e);
                    win.rack_panel.rebuild();
                }
                return 600;
            case "rack-preset":
                if (win.rack_panel.rack != null) win.rack_panel.rack.load_json(Presets.factory_rack(a[1]));
                win.rack_panel.rebuild();
                return 600;
            case "set-param":
                var r = win.rack_panel.rack;
                if (r != null) r.effects[int.parse(a[1])].set_value(a[2], double.parse(a[3]));
                return 300;
            case "track":
                if (win.session != null) win.session_page.select_track(win.session.tracks[int.parse(a[1])]);
                return 400;
            case "clip":
                if (win.session != null) {
                    int ti = int.parse(a[1]), ci = int.parse(a[2]);
                    if (ti >= win.session.tracks.size || ci >= win.session.tracks[ti].clips.size) throw new IOError.NOT_FOUND("no such clip");
                    var t = win.session.tracks[ti];
                    win.session_page.select_track(t);
                    win.session_page.select_clip(t.clips[ci]);
                }
                return 400;
            case "clip-at":
                if (win.session != null) {
                    var t = win.session.tracks[int.parse(a[1])];
                    var c = win.session.add_clip(t, Decoder.decode_sync(a[3]).source, a[3], (int64) (sec(a[2]) * win.session.rate));
                    SessionFile.pool(win.session).id_for(c.source, a[3]);
                    c.name = Path.get_basename(a[3]);
                    win.session.checkpoint(_("Import"));
                    win.after_edit();
                }
                return 800;
            case "lanes":
                if (win.session != null) win.session_page.toggle_lanes(win.session.tracks[int.parse(a[1])], true);
                return 400;
            case "duck":
                if (win.session != null) {
                    foreach (var t in win.session.tracks) {
                        if (t.duck) {
                            Ducking.apply(win.session, t, t.duck_db, 250, 500);
                            win.session_page.toggle_lanes(t, true);
                        }
                    }
                }
                return 800;
            case "send":
                if (win.session != null) {
                    var t = win.session.tracks[int.parse(a[1])];
                    var bus = win.session.tracks[int.parse(a[2])];
                    var s = new Send(bus.id);
                    s.level_db = -8;
                    t.sends.add(s);
                    win.session.checkpoint(_("Add Send"));
                }
                return 300;
            case "save-session":
                SessionFile.save(win.session, rest);
                return 600;
            case "export":
                var o = win.export_defaults(ExportFormat.from_id(a[1]));
                Renderable src = win.view_name == "waveform" ? (Renderable) win.doc : (Renderable) win.session;
                if (win.session != null) win.session.mixer.prepare_clips();
                Exporter.export_sync(src, a[2], o);
                return 600;
            case "record":
                win.transport.record_button.active = true;
                return (uint) int.parse(a[1]);
            case "record-stop":
                win.transport.record_button.active = false;
                return 800;
            case "arm":
                if (win.session != null) win.session.tracks[int.parse(a[1])].armed = true;
                win.session_page.rebuild();
                return 300;
            case "click":
                var w = find_anywhere(rest);
                if (w == null) throw new IOError.NOT_FOUND("no widget %s".printf(rest));
                if (w is Gtk.Button) ((Gtk.Button) w).clicked();
                return 900;
            case "shot":
                shot(a[1]);
                return 300;
            case "shot-dialog":
                shot(a[1]);
                return 300;
            case "print":
                win.activate_action("print", null);
                return 4000;
            case "dark":
                Singularity.Style.StyleManager.get_default().apply_color_scheme(a[1] == "on");
                return 800;
            case "size":
                win.set_default_size(int.parse(a[1]), int.parse(a[2]));
                return 800;
            case "analyze":
                win.analysis_panel.analyze_selection();
                return 800;
            case "measure":
                win.analyze_loudness.begin();
                return 3000;
            case "state":
                printerr("script: state fullscreened=%s maximized=%s\n", win.fullscreened.to_string(), win.maximized.to_string());
                return 100;
            case "unmaximize":
                win.unmaximize();
                return 1000;
            case "maximize":
                win.maximize();
                return 1000;
            case "quit":
                var app = win.application;
                win.close();
                if (app != null) app.quit();
                return 100;
            default:
                throw new IOError.INVALID_ARGUMENT("unknown command");
            }
        }
    }
}
