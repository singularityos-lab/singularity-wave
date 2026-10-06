using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    namespace ProcessDialogs {
        public void open(WaveWindow win, string what, Document doc, int64 a, int64 b) {
            Box body;
            var g = new PreferencesGroup(null);
            string title = "";
            Dialogs.ConfirmedFunc? done = null;
            switch (what) {
            case "amplify":
                title = _("Amplify");
                g.title = _("Level");
                var gain = Dialogs.spin_row(g, _("Gain"), -48, 48, 0.5, 3, 1, "dB");
                done = () => win.run_doc(() => Processes.amplify(doc, a, b, gain.value));
                break;
            case "normalize":
                title = _("Normalize");
                g.title = _("Peak");
                var target = Dialogs.spin_row(g, _("Peak Level"), -24, 0, 0.1, -1, 1, "dBFS");
                var per = Dialogs.switch_row(g, _("Each Channel Separately"), false);
                done = () => win.run_doc(() => Processes.normalize_peak(doc, a, b, target.value, per.active));
                break;
            case "loudness":
                title = _("Match Loudness");
                g.title = _("Target");
                string[] labels = {};
                foreach (var lt in LoudnessTarget.all()) labels += lt.label;
                var target = Dialogs.choice_row(g, _("Target"), labels, 0);
                var ceiling = Dialogs.spin_row(g, _("True Peak Ceiling"), -6, 0, 0.5, win.app.num("true-peak-ceiling", -1), 1, "dBTP");
                done = () => win.run_doc(() => Processes.normalize_loudness(doc, a, b, LoudnessTarget.all()[target.index].lufs, ceiling.value));
                break;
            case "denoise":
                title = _("Noise Reduction");
                g.title = _("Reduction");
                if (!doc.noise.ready) {
                    win.toast(_("Select a part with only noise and choose Capture Noise Print first"));
                    return;
                }
                var red = Dialogs.spin_row(g, _("Reduction"), 0, 48, 1, 18, 0, "dB");
                var sens = Dialogs.spin_row(g, _("Sensitivity"), 0, 24, 0.5, 6, 1, "dB");
                var smooth = Dialogs.spin_row(g, _("Smoothing"), 0, 1, 0.05, 0.5, 2);
                done = () => win.run_doc(() => Processes.reduce_noise(doc, a, b, red.value, sens.value, smooth.value));
                break;
            case "adaptive_denoise":
            case "declick":
            case "dehum":
            case "declip":
            case "dereverb":
                var fx = (RestoreEffect) EffectRegistry.create(what);
                title = fx.title;
                var editor = new EffectEditor(fx);
                done = () => win.run_doc(() => Processes.apply_effect(doc, a, b, fx));
                var dlg = Dialogs.form(win, title, _("Apply"), out body, (owned) done);
                g.title = _("Parameters");
                editor.margin_top = 12;
                g.add_row(editor);
                body.append(g);
                dlg.present();
                return;
            case "stretch":
                title = _("Stretch and Pitch");
                g.title = _("Time and Pitch");
                var len = Dialogs.spin_row(g, _("Length"), 25, 400, 1, 100, 0, "%");
                var pitch = Dialogs.spin_row(g, _("Pitch"), -24, 24, 0.5, 0, 1, _("st"));
                done = () => win.run_doc(() => Processes.time_stretch(doc, a, b, len.value / 100, pitch.value));
                break;
            case "convert":
                title = _("Convert Sample Type");
                g.title = _("Sample Type");
                var rates = new int[] { 22050, 32000, 44100, 48000, 88200, 96000 };
                int ri = 3;
                for (int i = 0; i < rates.length; i++) {
                    if (rates[i] == doc.rate) ri = i;
                }
                var rate = Dialogs.choice_row(g, _("Sample Rate"), { "22050 Hz", "32000 Hz", "44100 Hz", "48000 Hz", "88200 Hz", "96000 Hz" }, ri);
                var ch = Dialogs.choice_row(g, _("Channels"), { _("Mono"), _("Stereo"), "5.1" }, doc.channels == 1 ? 0 : doc.channels == 6 ? 2 : 1);
                done = () => {
                    int[] counts = { 1, 2, 6 };
                    win.run_doc(() => doc.convert(rates[rate.index], counts[ch.index], _("Convert")));
                    win.wave.zoom_fit();
                };
                break;
            case "tone":
                title = _("Generate Tone");
                g.title = _("Tone");
                var freq = Dialogs.spin_row(g, _("Frequency"), 20, 20000, 1, 1000, 0, "Hz");
                var lvl = Dialogs.spin_row(g, _("Level"), -60, 0, 1, -18, 0, "dBFS");
                var dur = Dialogs.spin_row(g, _("Duration"), 0.1, 600, 0.5, 5, 1, "s");
                done = () => win.run_doc(() => Processes.generate_tone(doc, win.wave.cursor, dur.value, freq.value, lvl.value));
                break;
            default:
                return;
            }
            var d = Dialogs.form(win, title, _("Apply"), out body, (owned) done);
            body.append(g);
            d.present();
        }

        public void separate_voice(WaveWindow win, Document doc, int64 a, int64 b) {
            run_model(win, doc, a, b, "VoiceSeparation", _("Separate Voice"), "enhance", _("Enhance Speech"));
        }

        public void model_denoise(WaveWindow win, Document doc, int64 a, int64 b) {
            run_model(win, doc, a, b, "Denoise", _("Denoise with a Local Model"), "adaptive_denoise", _("Adaptive Noise Reduction"));
        }

        private void run_model(WaveWindow win, Document doc, int64 a, int64 b, string group, string title, string fallback, string fallback_label) {
            string? cmd = CommandTranscriber.config_value(group, "Command");
            if (cmd == null) {
                Dialogs.confirm(win, title, _("This runs a local model that your distribution can provide, configured in the [%s] section of singularity/wave.conf with %%i for the input and %%o for the output file. Until then the built-in processing is used.").printf(group), fallback_label, () => win.process(fallback), false);
                return;
            }
            win.run_doc(() => {
                string dir = DirUtils.make_tmp("wave-separate-XXXXXX");
                string input = Path.build_filename(dir, "in.wav");
                string output = Path.build_filename(dir, "voice.wav");
                var o = new ExportOptions();
                o.format = ExportFormat.WAV;
                o.is_float = true;
                o.start = a;
                o.end = b;
                Exporter.export_sync(doc, input, o);
                string[] argv;
                GLib.Shell.parse_argv(cmd.replace("%i", input).replace("%o", output), out argv);
                int status;
                Process.spawn_sync(null, argv, null, SpawnFlags.SEARCH_PATH, null, null, null, out status);
                if (!FileUtils.test(output, FileTest.EXISTS)) throw new IOError.FAILED(_("The voice separation command did not write %s").printf(output));
                var media = Decoder.decode_sync(output);
                var buf = new float[media.source.frames * doc.channels];
                media.source.read(0, media.source.frames, buf, 0, doc.channels);
                doc.process_replace(a, b, title, buf, media.source.frames);
                FileUtils.unlink(input);
                FileUtils.unlink(output);
                DirUtils.remove(dir);
            });
        }
    }

    namespace ExportDialog {
        public void show_for(WaveWindow win, Renderable src, string title, Metadata meta, Gee.List<Marker> markers, int64 start, int64 end, bool as_save = false) {
            Box body;
            ChoiceRow? fmt = null;
            ChoiceRow? depth = null;
            ChoiceRow? rate = null;
            ChoiceRow? channels = null;
            SpinButton? bitrate = null;
            Switch? chapters = null;
            Switch? cue = null;
            Switch? json = null;
            Switch? only_sel = null;
            Switch? dither = null;
            var formats = new Gee.ArrayList<ExportFormat>();
            foreach (var f in ExportFormat.all()) {
                if (f.available()) formats.add(f);
            }
            string[] names = {};
            foreach (var f in formats) names += f.label();
            int[] rates = { 0, 22050, 44100, 48000, 96000 };
            var dlg = Dialogs.form(win, as_save ? _("Save Audio") : _("Export Audio"), as_save ? _("Save") : _("Export"), out body, () => {
                var o = win.export_defaults(formats[(int) fmt.index]);
                string[] depths = { "16", "24", "32f" };
                string d = depths[depth.index];
                o.bits = d == "16" ? 16 : 24;
                o.is_float = d == "32f";
                o.dither = dither.active;
                o.rate = rates[rate.index];
                o.channels = channels.index == 0 ? 0 : channels.index == 1 ? 1 : 2;
                o.bitrate = (int) bitrate.value;
                o.chapters = chapters.active;
                o.cue_sheet = cue.active;
                o.chapters_json = json.active;
                o.metadata = meta;
                o.markers = markers;
                if (only_sel.active && end > start) {
                    o.start = start;
                    o.end = end;
                }
                var f = o.format;
                string base_name = title;
                int dot = base_name.last_index_of(".");
                if (dot > 0) base_name = base_name.substring(0, dot);
                Dialogs.save.begin(win, _("Export"), "%s.%s".printf(base_name, f.extension()), f.label(), { f.extension() }, (obj, r) => {
                    var file = Dialogs.save.end(r);
                    if (file == null) return;
                    string path = Dialogs.ensure_suffix(file.get_path(), f.extension());
                    if (as_save && src == win.doc) {
                        win.write_document.begin(path, o);
                        return;
                    }
                    run_export.begin(win, src, path, o);
                });
            });
            var g = new PreferencesGroup(_("Encoding"));
            fmt = Dialogs.choice_row(g, _("Format"), names, 0);
            depth = Dialogs.choice_row(g, _("Bit Depth"), { _("16 bit"), _("24 bit"), _("32 bit float") }, win.app.str("bit-depth", "24") == "16" ? 0 : win.app.str("bit-depth", "24") == "32f" ? 2 : 1, _("WAV, BWF, AIFF, CAF and FLAC"));
            dither = Dialogs.switch_row(g, _("Dither"), win.app.flag("dither", true), _("Noise shaped dither when reducing to 16 bit"));
            rate = Dialogs.choice_row(g, _("Sample Rate"), { _("Same as Source"), "22050 Hz", "44100 Hz", "48000 Hz", "96000 Hz" }, 0);
            channels = Dialogs.choice_row(g, _("Channels"), { _("Same as Source"), _("Mono"), _("Stereo") }, 0);
            bitrate = Dialogs.spin_row(g, _("Bitrate"), 32, 320, 8, 192, 0, "kbit/s", _("MP3, Ogg, Opus and AAC"));
            body.append(g);
            var m = new PreferencesGroup(_("Chapters and Selection"));
            chapters = Dialogs.switch_row(m, _("Markers as Chapters"), true, _("ID3 chapters, Vorbis chapters, WAV cue points"));
            cue = Dialogs.switch_row(m, _("CUE Sheet"), false);
            json = Dialogs.switch_row(m, _("Podcast Chapters File"), false, _("JSON chapters for podcast hosts"));
            only_sel = Dialogs.switch_row(m, _("Only the Selection"), end > start && !as_save);
            only_sel.sensitive = end > start;
            body.append(m);
            dlg.present();
        }

        public async void run_export(WaveWindow win, Renderable src, string path, ExportOptions o) {
            win.set_busy(true);
            var ex = new Exporter();
            try {
                if (src is Session) ((Session) src).mixer.prepare_clips();
                yield ex.export(src, path, o);
                win.toast(_("Exported %s").printf(Path.get_basename(path)));
            } catch (Error e) {
                win.show_error(_("Could Not Export"), e.message);
            }
            win.set_busy(false);
        }

        public void stems(WaveWindow win, Session s) {
            Dialogs.folder.begin(win, _("Choose a Folder for the Stems"), (o, r) => {
                var dir = Dialogs.folder.end(r);
                if (dir == null) return;
                export_stems.begin(win, s, dir.get_path());
            });
        }

        private async void export_stems(WaveWindow win, Session s, string dir) {
            win.set_busy(true);
            int n = 0;
            try {
                s.mixer.prepare_clips();
                foreach (var t in s.tracks) {
                    if (t.kind != TrackKind.AUDIO || t.clips.size == 0) continue;
                    s.mixer.only_track = t.id;
                    s.mixer.skip_master_rack = true;
                    s.mixer.reset();
                    var o = win.export_defaults(ExportFormat.WAV);
                    yield new Exporter().export(s, Path.build_filename(dir, "%02d %s.wav".printf(++n, t.name.replace("/", "-"))), o);
                }
            } catch (Error e) {
                win.show_error(_("Could Not Export"), e.message);
            }
            s.mixer.only_track = null;
            s.mixer.skip_master_rack = false;
            s.mixer.reset();
            win.set_busy(false);
            win.toast(ngettext("%d stem written", "%d stems written", n).printf(n));
        }
    }

    namespace BatchDialog {
        public void show_batch(WaveWindow win) {
            var job = new BatchJob();
            Box body;
            Label? files_label = null;
            ChoiceRow? fmt = null;
            ChoiceRow? chain = null;
            Switch? norm = null;
            ChoiceRow? target = null;
            Label? out_label = null;
            var formats = new Gee.ArrayList<ExportFormat>();
            foreach (var f in ExportFormat.all()) {
                if (f.available()) formats.add(f);
            }
            string[] names = {};
            foreach (var f in formats) names += f.label();
            string[] chain_ids = { "", "voice", "podcast-master", "telephone", "music-bed" };
            string[] chain_names = { _("None"), _("Voice Clarity"), _("Podcast Master"), _("Telephone"), _("Music Bed") };
            foreach (string p in Presets.list("rack")) {
                chain_ids += "user:" + p;
                chain_names += p;
            }
            var dlg = Dialogs.form(win, _("Batch Process"), _("Process"), out body, () => {
                if (job.files.size == 0) return;
                string id = chain_ids[chain.index];
                if (id.has_prefix("user:")) job.rack = Presets.load("rack", id.substring(5));
                else if (id != "") job.rack = Presets.factory_rack(id);
                job.normalize = norm.active;
                job.target_lufs = LoudnessTarget.all()[target.index].lufs;
                job.ceiling = LoudnessTarget.all()[target.index].true_peak;
                job.options = win.export_defaults(formats[(int) fmt.index]);
                win.set_busy(true);
                int done = 0;
                job.file_done.connect((i, o, e) => {
                    done++;
                    if (e != null) win.toast("%s: %s".printf(Path.get_basename(i), e));
                });
                job.run.begin((obj, res) => {
                    int ok = job.run.end(res);
                    win.set_busy(false);
                    win.toast(_("%d of %d files processed").printf(ok, job.files.size));
                });
            }, 520);
            var g = new PreferencesGroup(_("Files"));
            var pick = Dialogs.header_button(g, "document-open-symbolic", _("Add Files…"));
            var folder = Dialogs.header_button(g, "folder-open-symbolic", _("Add Folder…"));
            var frow = new ActionRow(_("Input"));
            files_label = new Label(_("No files yet"));
            files_label.add_css_class("dim-label");
            frow.add_suffix(files_label);
            g.add_row(frow);
            pick.clicked.connect(() => {
                Dialogs.open_many.begin(win, _("Add Files"), (o, r) => {
                    var list = Dialogs.open_many.end(r);
                    if (list == null) return;
                    for (uint i = 0; i < list.get_n_items(); i++) job.files.add(((File) list.get_item(i)).get_path());
                    files_label.label = ngettext("%d file", "%d files", job.files.size).printf(job.files.size);
                });
            });
            folder.clicked.connect(() => {
                Dialogs.folder.begin(win, _("Add Folder"), (o, r) => {
                    var d = Dialogs.folder.end(r);
                    if (d == null) return;
                    job.files.add_all(BatchJob.collect(d.get_path(), true));
                    files_label.label = ngettext("%d file", "%d files", job.files.size).printf(job.files.size);
                });
            });
            body.append(g);
            var p = new PreferencesGroup(_("Processing"));
            chain = Dialogs.choice_row(p, _("Effects Chain"), chain_names, 0, _("Rack presets saved from the Effects panel appear here"));
            norm = Dialogs.switch_row(p, _("Match Loudness"), true);
            string[] tl = {};
            foreach (var lt in LoudnessTarget.all()) tl += lt.label;
            target = Dialogs.choice_row(p, _("Target"), tl, 0);
            body.append(p);
            var o = new PreferencesGroup(_("Output"));
            fmt = Dialogs.choice_row(o, _("Format"), names, 0);
            var orow = new ActionRow(_("Folder"));
            out_label = new Label(_("Next to each file"));
            out_label.add_css_class("dim-label");
            var choose = new Button.with_label(_("Choose…"));
            choose.valign = Align.CENTER;
            choose.clicked.connect(() => {
                Dialogs.folder.begin(win, _("Output Folder"), (obj, r) => {
                    var d = Dialogs.folder.end(r);
                    if (d == null) return;
                    job.output_dir = d.get_path();
                    out_label.label = d.get_basename();
                });
            });
            orow.add_suffix(out_label);
            orow.add_suffix(choose);
            o.add_row(orow);
            var suffix = Dialogs.entry_row(o, _("Name Suffix"), "-processed");
            suffix.entry_changed.connect(() => job.suffix = suffix.text);
            job.suffix = "-processed";
            body.append(o);
            dlg.present();
        }

        public void show_match(WaveWindow win) {
            var files = new Gee.ArrayList<string>();
            Box body;
            ChoiceRow? target = null;
            Gee.List<MatchEntry>? entries = null;
            string out_dir = "";
            var dlg = Dialogs.form(win, _("Match Loudness"), _("Match"), out body, () => {
                if (files.size == 0) return;
                var t = LoudnessTarget.all()[target.index];
                win.set_busy(true);
                new Thread<void>("wave-match", () => {
                    var list = LoudnessMatch.analyze(files);
                    LoudnessMatch.apply(list, t.lufs, t.true_peak, out_dir, ExportFormat.WAV);
                    Idle.add(() => {
                        win.set_busy(false);
                        int ok = 0;
                        foreach (var e in list) {
                            if (e.error == null) ok++;
                        }
                        win.toast(_("%d files matched to %.0f LUFS").printf(ok, t.lufs));
                        return GLib.Source.REMOVE;
                    });
                });
            }, 560);
            var g = new PreferencesGroup(_("Files"), _("Every file is measured and written again at the same loudness"));
            var add = Dialogs.header_button(g, "document-open-symbolic", _("Add Files…"));
            var none = new ActionRow(_("No files yet"));
            none.add_css_class("dim-label");
            g.add_row(none);
            body.append(g);
            add.clicked.connect(() => {
                Dialogs.open_many.begin(win, _("Add Files"), (o, r) => {
                    var list = Dialogs.open_many.end(r);
                    if (list == null) return;
                    for (uint i = 0; i < list.get_n_items(); i++) files.add(((File) list.get_item(i)).get_path());
                    entries = LoudnessMatch.analyze(files);
                    g.clear();
                    foreach (var e in entries) g.add_row(new ActionRow(Path.get_basename(e.path), e.error ?? "%s, %s".printf(LoudnessResult.format_lufs(e.before.integrated), LoudnessResult.format_db(e.before.true_peak, "dBTP"))));
                });
            });
            var p = new PreferencesGroup(_("Target"));
            string[] tl = {};
            foreach (var lt in LoudnessTarget.all()) tl += lt.label;
            target = Dialogs.choice_row(p, _("Loudness"), tl, 0);
            var orow = new ActionRow(_("Output Folder"), _("Matched files get a -matched suffix next to the originals"));
            var choose = new Button.with_label(_("Choose…"));
            choose.valign = Align.CENTER;
            choose.clicked.connect(() => {
                Dialogs.folder.begin(win, _("Output Folder"), (obj, r) => {
                    var d = Dialogs.folder.end(r);
                    if (d != null) {
                        out_dir = d.get_path();
                        orow.subtitle = out_dir;
                    }
                });
            });
            orow.add_suffix(choose);
            p.add_row(orow);
            body.append(p);
            dlg.present();
        }
    }
}
