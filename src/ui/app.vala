using Gtk;

namespace Singularity.Apps.Wave {

    public class WaveApp : Singularity.Application {
        public GLib.Settings? settings;
        public InputDevices? devices = null;
        private string? new_kind = null;
        private string? montage_path = null;
        private string[] batch_args = {};

        public WaveApp() {
            Object(application_id: "dev.sinty.wave", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option("new", 0, OptionFlags.NONE, OptionArg.STRING, _("Start a new session: session, podcast or surround"), "KIND");
            add_main_option("montage", 0, OptionFlags.NONE, OptionArg.FILENAME, _("Edit the sound of a Montage project and send it back"), "PROJECT");
            add_main_option("batch", 0, OptionFlags.NONE, OptionArg.STRING_ARRAY, _("Process files without a window: --batch FORMAT:TARGET_LUFS:OUTPUT_DIR FILE…"), "SPEC");
            var schema = SettingsSchemaSource.get_default()?.lookup("dev.sinty.wave", true);
            if (schema != null) settings = new GLib.Settings("dev.sinty.wave");
        }

        public int rate_setting() {
            return settings != null ? int.parse(settings.get_string("sample-rate")) : 48000;
        }

        public string str(string key, string fallback) {
            return settings != null ? settings.get_string(key) : fallback;
        }

        public bool flag(string key, bool fallback) {
            return settings != null ? settings.get_boolean(key) : fallback;
        }

        public int num(string key, int fallback) {
            return settings != null ? settings.get_int(key) : fallback;
        }

        protected override int handle_local_options(VariantDict options) {
            if (options.contains("new")) {
                string? k = null;
                options.lookup("new", "s", out k);
                new_kind = k;
            }
            if (options.contains("montage")) {
                string? m = null;
                options.lookup("montage", "^ay", out m);
                montage_path = m;
            }
            if (options.contains("batch")) {
                string[]? b = null;
                options.lookup("batch", "^as", out b);
                if (b != null) {
                    string[] list = {};
                    for (int i = 0; b[i] != null; i++) list += b[i];
                    batch_args = list;
                }
                return run_batch();
            }
            return -1;
        }

        private int run_batch() {
            unowned string[]? gst_args = null;
            Gst.init(ref gst_args);
            if (batch_args.length < 2) {
                printerr("usage: singularity-wave --batch FORMAT:TARGET_LUFS:OUTPUT_DIR --batch FILE ...\n");
                return 2;
            }
            string[] spec = batch_args[0].split(":");
            var job = new BatchJob();
            job.options.format = ExportFormat.from_id(spec[0]);
            if (spec.length > 1 && spec[1] != "") {
                job.normalize = true;
                job.target_lufs = double.parse(spec[1]);
            }
            if (spec.length > 2) job.output_dir = spec[2];
            for (int i = 1; i < batch_args.length; i++) {
                if (FileUtils.test(batch_args[i], FileTest.IS_DIR)) job.files.add_all(BatchJob.collect(batch_args[i], true));
                else job.files.add(batch_args[i]);
            }
            int failed = 0;
            job.file_done.connect((input, output, error) => {
                if (error != null) {
                    printerr("%s: %s\n", input, error);
                    failed++;
                } else {
                    print("%s -> %s\n", input, output);
                }
            });
            job.run_sync();
            return failed == 0 ? 0 : 1;
        }

        protected override void startup() {
            base.startup();
            unowned string[]? gst_args = null;
            Gst.init(ref gst_args);
            PcmSource.prune_cache(14);
            about_version = "0.1.0";
            about_license = _("GNU General Public License, version 3 only");
            Gtk.IconTheme.get_for_display(Gdk.Display.get_default()).add_resource_path("/dev/sinty/wave/icons");
            Singularity.Application.add_app_css(CSS);
            devices = new InputDevices();
            string[] actions = { "new-session", "new-podcast", "new-surround", "open", "quit", "settings", "batch", "match-loudness" };
            foreach (string name in actions) {
                var a = new SimpleAction(name, null);
                string n = name;
                a.activate.connect(() => on_app_action(n));
                add_action(a);
            }
            build_menu();
            string[,] accels = {
                { "app.quit", "<Control>q" }, { "app.open", "<Control>o" }, { "app.settings", "<Control>comma" }, { "app.new-session", "<Control>n" },
                { "win.save", "<Control>s" }, { "win.save-as", "<Control><Shift>s" }, { "win.export", "<Control><Shift>e" }, { "win.close-document", "<Control>w" },
                { "win.undo", "<Control>z" }, { "win.redo", "<Control><Shift>z" }, { "win.print", "<Control>p" },
                { "win.cut", "<Control>x" }, { "win.copy", "<Control>c" }, { "win.paste", "<Control>v" }, { "win.delete", "Delete" },
                { "win.select-all", "<Control>a" }, { "win.play", "space" }, { "win.record", "<Shift>r" }, { "win.marker", "m" },
                { "win.zoom-in", "<Control>plus" }, { "win.zoom-out", "<Control>minus" }, { "win.zoom-fit", "<Control>0" },
                { "win.split", "<Control>k" }, { "win.silence", "<Control><Shift>l" }, { "win.toggle-sidebar", "F9" }, { "win.fullscreen", "F11" }, { "win.mode-spectral", "<Shift>d" },
                { "win.view::waveform", "<Alt>1" }, { "win.view::multitrack", "<Alt>2" }, { "win.view::mixer", "<Alt>3" }
            };
            for (int i = 0; i < accels.length[0]; i++) set_accels_for_action(accels[i, 0], { accels[i, 1] });
        }

        private void build_menu() {
            var menu = new GLib.Menu();
            var file = new GLib.Menu();
            var f1 = new GLib.Menu();
            f1.append(_("New Multitrack Session"), "app.new-session");
            f1.append(_("New Podcast"), "app.new-podcast");
            f1.append(_("New 5.1 Session"), "app.new-surround");
            f1.append(_("New Audio File"), "win.new-file");
            file.append_section(null, f1);
            var f2 = new GLib.Menu();
            f2.append(_("Open…"), "app.open");
            f2.append(_("Open from Online Account…"), "win.open-online");
            f2.append(_("Import into Session…"), "win.import");
            file.append_section(null, f2);
            var f3 = new GLib.Menu();
            f3.append(_("Save"), "win.save");
            f3.append(_("Save As…"), "win.save-as");
            f3.append(_("Save to Online Account…"), "win.save-online");
            f3.append(_("Export…"), "win.export");
            f3.append(_("Export Stems…"), "win.export-stems");
            f3.append(_("Export Timeline (OpenTimelineIO)…"), "win.export-otio");
            f3.append(_("Send Back to Montage"), "win.return-montage");
            file.append_section(null, f3);
            var f4 = new GLib.Menu();
            f4.append(_("Batch Process…"), "app.batch");
            f4.append(_("Match Loudness of Files…"), "app.match-loudness");
            f4.append(_("Print…"), "win.print");
            file.append_section(null, f4);
            var f5 = new GLib.Menu();
            f5.append(_("Close"), "win.close-document");
            f5.append(_("Quit"), "app.quit");
            file.append_section(null, f5);
            menu.append_submenu(_("File"), file);
            var edit = new GLib.Menu();
            var e1 = new GLib.Menu();
            e1.append(_("Undo"), "win.undo");
            e1.append(_("Redo"), "win.redo");
            edit.append_section(null, e1);
            var e2 = new GLib.Menu();
            e2.append(_("Cut"), "win.cut");
            e2.append(_("Copy"), "win.copy");
            e2.append(_("Paste"), "win.paste");
            e2.append(_("Delete"), "win.delete");
            e2.append(_("Silence"), "win.silence");
            e2.append(_("Crop to Selection"), "win.crop");
            e2.append(_("Split"), "win.split");
            e2.append(_("Select All"), "win.select-all");
            edit.append_section(null, e2);
            var e3 = new GLib.Menu();
            e3.append(_("Add Marker"), "win.marker");
            e3.append(_("Split at Markers"), "win.split-markers");
            edit.append_section(null, e3);
            var e4 = new GLib.Menu();
            e4.append(_("Settings"), "app.settings");
            edit.append_section(null, e4);
            menu.append_submenu(_("Edit"), edit);
            var fx = new GLib.Menu();
            var x1 = new GLib.Menu();
            x1.append(_("Amplify…"), "win.process::amplify");
            x1.append(_("Normalize…"), "win.process::normalize");
            x1.append(_("Match Loudness…"), "win.process::loudness");
            x1.append(_("Fade In"), "win.process::fade-in");
            x1.append(_("Fade Out"), "win.process::fade-out");
            x1.append(_("Invert"), "win.process::invert");
            x1.append(_("Reverse"), "win.process::reverse");
            x1.append(_("Remove DC Offset"), "win.process::dc");
            fx.append_section(null, x1);
            var x2 = new GLib.Menu();
            x2.append(_("Capture Noise Print"), "win.process::capture-noise");
            x2.append(_("Noise Reduction…"), "win.process::denoise");
            x2.append(_("Adaptive Noise Reduction"), "win.process::adaptive_denoise");
            x2.append(_("Denoise with a Local Model…"), "win.process::model-denoise");
            x2.append(_("Remove Clicks and Crackle"), "win.process::declick");
            x2.append(_("Remove Hum"), "win.process::dehum");
            x2.append(_("Repair Clipping"), "win.process::declip");
            x2.append(_("Reduce Reverb"), "win.process::dereverb");
            x2.append(_("Enhance Speech"), "win.process::enhance");
            x2.append(_("Separate Voice…"), "win.process::separate");
            x2.append(_("Spot Healing"), "win.process::heal");
            fx.append_section(_("Restoration"), x2);
            var x3 = new GLib.Menu();
            x3.append(_("Stretch and Pitch…"), "win.process::stretch");
            x3.append(_("Convert Sample Type…"), "win.process::convert");
            x3.append(_("Generate Tone…"), "win.process::tone");
            x3.append(_("Apply Effects Rack"), "win.process::rack");
            fx.append_section(null, x3);
            menu.append_submenu(_("Effects"), fx);
            var view = new GLib.Menu();
            var v1 = new GLib.Menu();
            v1.append(_("Waveform Editor"), "win.view::waveform");
            v1.append(_("Multitrack"), "win.view::multitrack");
            v1.append(_("Mixer"), "win.view::mixer");
            view.append_section(null, v1);
            var v2 = new GLib.Menu();
            v2.append(_("Spectral Display"), "win.mode-spectral");
            v2.append(_("Zoom In"), "win.zoom-in");
            v2.append(_("Zoom Out"), "win.zoom-out");
            v2.append(_("Zoom to Fit"), "win.zoom-fit");
            v2.append(_("Inspector"), "win.toggle-sidebar");
            v2.append(_("Full Screen"), "win.fullscreen");
            view.append_section(null, v2);
            menu.append_submenu(_("View"), view);
            var transport = new GLib.Menu();
            transport.append(_("Play or Pause"), "win.play");
            transport.append(_("Record"), "win.record");
            transport.append(_("Loop Selection"), "win.loop");
            transport.append(_("Metronome"), "win.metronome");
            transport.append(_("Monitor Input"), "win.monitor");
            menu.append_submenu(_("Transport"), transport);
            set_menubar(menu);
        }

        public WaveWindow target_window() {
            var w = get_active_window() as WaveWindow;
            if (w == null) {
                w = new WaveWindow(this);
                w.present();
            }
            return w;
        }

        private WaveWindow empty_window() {
            var w = get_active_window() as WaveWindow;
            if (w == null || !w.is_empty()) {
                w = new WaveWindow(this);
                w.present();
            }
            return w;
        }

        private void on_app_action(string name) {
            switch (name) {
            case "new-session":
                empty_window().new_session("session");
                break;
            case "new-podcast":
                empty_window().new_session("podcast");
                break;
            case "new-surround":
                empty_window().new_session("surround");
                break;
            case "open":
                target_window().choose_open();
                break;
            case "batch":
                target_window().open_batch();
                break;
            case "match-loudness":
                target_window().open_match();
                break;
            case "settings":
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync(BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings("dev.sinty.wave");
                } catch (Error e) {
                    warning("Wave: cannot open settings: %s", e.message);
                }
                break;
            case "quit":
                var list = new Gee.ArrayList<Gtk.Window>();
                foreach (var w in get_windows()) list.add(w);
                foreach (var w in list) w.close();
                break;
            default:
                break;
            }
        }

        protected override void activate() {
            var w = target_window();
            if (new_kind != null) {
                w.new_session(new_kind);
                new_kind = null;
            }
            if (montage_path != null) {
                w.open_montage(montage_path);
                montage_path = null;
            }
            w.present();
        }

        protected override void open(File[] files, string hint) {
            var w = empty_window();
            foreach (var f in files) w.open_file(f);
            w.present();
        }

        protected override void shutdown() {
            if (devices != null) devices.stop();
            base.shutdown();
        }

        public static int main(string[] args) {
            Intl.setlocale(GLib.LocaleCategory.ALL, "");
            string locale_dir = "/usr/share/locale";
            try {
                string exe = GLib.FileUtils.read_link("/proc/self/exe");
                locale_dir = Path.build_filename(Path.get_dirname(Path.get_dirname(exe)), "share", "locale");
            } catch (GLib.Error e) {
            }
            Intl.bindtextdomain("singularity-wave", locale_dir);
            Intl.bind_textdomain_codeset("singularity-wave", "UTF-8");
            Intl.textdomain("singularity-wave");
            return new WaveApp().run(args);
        }

        private const string CSS = """
.wave-mini {
    min-width: 22px;
    min-height: 22px;
    padding: 0 4px;
    font-size: 11px;
    font-weight: 700;
}

.wave-mini.mute:checked {
    background-color: @warning_color;
    color: @destructive_fg;
}

.wave-mini.solo:checked {
    background-color: @success_color;
    color: @destructive_fg;
}

.wave-mini.arm:checked {
    background-color: @destructive_color;
    color: @destructive_fg;
}

.wave-mini.monitor:checked,
.wave-mini.auto:checked {
    background-color: @accent_bg_color;
    color: @accent_fg_color;
}

.wave-record:checked {
    color: @destructive_color;
}

.wave-track-header {
    padding: 4px 6px;
    border-bottom: 1px solid alpha(currentColor, 0.08);
}

.wave-track-header.selected {
    background-color: alpha(@accent_bg_color, 0.15);
}

.sx-channel-strip {
    padding: 8px 6px;
    border-right: 1px solid alpha(currentColor, 0.08);
}

.sx-channel-strip.selected {
    background-color: alpha(@accent_bg_color, 0.12);
}

button.wave-compact-menu {
    padding: 2px 8px;
    min-height: 26px;
    font-size: 12px;
}

.sx-inspector {
    border-left: 1px solid alpha(@window_fg_color, 0.08);
}

.sx-inspector-header {
    margin: 0 14px 10px 14px;
}

.wave-word {
    padding: 1px 3px;
    border-radius: 4px;
}

.wave-word.deleted {
    text-decoration: line-through;
    opacity: 0.45;
}

.wave-word.current {
    background-color: alpha(@accent_bg_color, 0.3);
}
""";
    }
}
