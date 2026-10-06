using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public class PropertiesPanel : Box {
        private weak WaveWindow win;
        private Box body;

        public PropertiesPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            body = new Box(Orientation.VERTICAL, 12);
            body.vexpand = true;
            append(body);
        }

        public void refresh() {
            Dialogs.clear(body);
            var s = win.session;
            if (s == null || win.view_name == "waveform") {
                body.append(Singularity.Widgets.InspectorPanel.empty_state("audio-x-generic", _("Multitrack Only"), _("Track and clip settings are available in multitrack sessions.")));
                return;
            }
            var t = win.session_page.selected_track;
            var c = win.session_page.selected_clip;
            if (c != null) {
                var g = new PreferencesGroup(_("Clip"));
                var name = Dialogs.entry_row(g, _("Name"), c.name);
                name.entry_changed.connect(() => c.name = name.text);
                var gain = Dialogs.spin_row(g, _("Gain"), -48, 24, 0.5, c.gain_db, 1, "dB");
                gain.value_changed.connect(() => {
                    c.gain_db = gain.value;
                    win.session_page.edited(_("Clip Gain"));
                });
                var fi = Dialogs.spin_row(g, _("Fade In"), 0, 600, 0.05, (double) c.fade_in / s.rate, 2, "s");
                fi.value_changed.connect(() => {
                    c.fade_in = (int64) (fi.value * s.rate);
                    win.session_page.edited(_("Clip Fade"));
                });
                string[] curves = { _("Linear"), _("Logarithmic"), _("S-Curve"), _("Exponential") };
                var fic = Dialogs.choice_row(g, _("Fade In Curve"), curves, c.fade_in_curve);
                fic.notify["index"].connect(() => {
                    c.fade_in_curve = (int) fic.index;
                    win.session_page.edited(_("Clip Fade"));
                });
                var fo = Dialogs.spin_row(g, _("Fade Out"), 0, 600, 0.05, (double) c.fade_out / s.rate, 2, "s");
                fo.value_changed.connect(() => {
                    c.fade_out = (int64) (fo.value * s.rate);
                    win.session_page.edited(_("Clip Fade"));
                });
                var foc = Dialogs.choice_row(g, _("Fade Out Curve"), curves, c.fade_out_curve);
                foc.notify["index"].connect(() => {
                    c.fade_out_curve = (int) foc.index;
                    win.session_page.edited(_("Clip Fade"));
                });
                body.append(g);
                var tg = new PreferencesGroup(_("Time and Pitch"), _("Phase vocoder rendering, the source file is not changed"));
                var stretch = Dialogs.spin_row(tg, _("Length"), 25, 400, 1, c.stretch * 100, 0, "%");
                var pitch = Dialogs.spin_row(tg, _("Pitch"), -24, 24, 0.5, c.pitch, 1, _("st"));
                Dialogs.button_row(tg, _("Apply Time and Pitch"), null, _("Render"), () => {
                    double old = c.stretch;
                    c.stretch = stretch.value / 100;
                    c.length = (int64) (c.length / old * c.stretch);
                    c.pitch = pitch.value;
                    try {
                        c.prepare_render();
                    } catch (Error e) {
                        win.show_error(_("Could Not Render"), e.message);
                    }
                    win.session_page.edited(_("Stretch Clip"));
                });
                body.append(tg);
                if (c.takes.size > 0) {
                    var takes = new PreferencesGroup(_("Takes"));
                    for (int i = 0; i < c.takes.size; i++) {
                        int idx = i;
                        var row = new ActionRow(c.takes[i].name, i == c.active_take ? _("In use") : null);
                        var use = new Button.with_label(_("Use"));
                        use.valign = Align.CENTER;
                        use.sensitive = i != c.active_take;
                        use.clicked.connect(() => {
                            c.use_take(idx);
                            win.session_page.edited(_("Choose Take"));
                            refresh();
                        });
                        row.add_suffix(use);
                        takes.add_row(row);
                    }
                    body.append(takes);
                }
            }
            if (t != null) {
                var g = new PreferencesGroup(_("Track"));
                var name = Dialogs.entry_row(g, _("Name"), t.name);
                name.entry_activated.connect(() => {
                    t.name = name.text;
                    win.session_page.edited(_("Rename Track"));
                    win.session_page.rebuild();
                });
                if (t.kind == TrackKind.AUDIO) {
                    var devs = win.app.devices.all();
                    string[] labels = {};
                    int active = 0;
                    for (int i = 0; i < devs.size; i++) {
                        labels += devs[i].label;
                        if (devs[i].id == t.input) active = i;
                    }
                    var input = Dialogs.choice_row(g, _("Input"), labels, active);
                    input.notify["index"].connect(() => t.input = devs[(int) input.index].id);
                    var ch = Dialogs.choice_row(g, _("Channels"), { _("Mono"), _("Stereo"), "5.1" }, t.channels == 1 ? 0 : t.channels == 6 ? 2 : 1);
                    ch.notify["index"].connect(() => {
                        int[] counts = { 1, 2, 6 };
                        t.channels = counts[ch.index];
                        t.rack.configure(s.rate, t.channels);
                        win.session_page.edited(_("Track Channels"));
                        win.session_page.rebuild();
                    });
                    string[] roles = { _("None"), _("Dialogue"), _("Music"), _("Sound Effects"), _("Ambience") };
                    string[] role_ids = { "", "dialogue", "music", "sfx", "ambience" };
                    int ri = 0;
                    for (int i = 0; i < role_ids.length; i++) {
                        if (role_ids[i] == t.role) ri = i;
                    }
                    var role = Dialogs.choice_row(g, _("Role"), roles, ri);
                    role.notify["index"].connect(() => {
                        t.role = role_ids[role.index];
                        if (t.role == "music") t.duck = true;
                        win.session_page.edited(_("Track Role"));
                    });
                    var duck = Dialogs.switch_row(g, _("Duck Under Speech"), t.duck, _("Lowered while dialogue tracks are speaking"));
                    duck.notify["active"].connect(() => t.duck = duck.active);
                    var depth = Dialogs.spin_row(g, _("Ducking Depth"), -40, 0, 1, t.duck_db, 0, "dB");
                    depth.value_changed.connect(() => t.duck_db = depth.value);
                }
                body.append(g);
                if (t.sends.size > 0) {
                    var sg = new PreferencesGroup(_("Sends"));
                    foreach (var send in t.sends) {
                        var b = s.find_track(send.bus);
                        var sn = send;
                        var row = new SwitchRow(b != null ? b.name : "?", _("Before the fader"), send.pre_fader);
                        row.switch_btn.notify["active"].connect(() => sn.pre_fader = row.switch_btn.active);
                        sg.add_row(row);
                    }
                    body.append(sg);
                }
            }
            var sess = new PreferencesGroup(_("Session"));
            var tempo = Dialogs.spin_row(sess, _("Tempo"), 30, 300, 1, s.tempo, 0, _("BPM"));
            tempo.value_changed.connect(() => {
                s.tempo = tempo.value;
                win.session_page.sync_tempo();
                win.session_page.queue_draw_all();
            });
            var beats = Dialogs.spin_row(sess, _("Beats per Bar"), 1, 12, 1, s.beats_per_bar, 0);
            beats.value_changed.connect(() => s.beats_per_bar = (int) beats.value);
            var metro = Dialogs.switch_row(sess, _("Metronome"), s.metronome, _("Clicks while playing and recording, never exported"));
            metro.notify["active"].connect(() => {
                s.metronome = metro.active;
                win.transport.metronome_button.active = metro.active;
            });
            body.append(sess);
        }
    }

    public class EssentialPanel : Box {
        private weak WaveWindow win;
        private Box body;

        public EssentialPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            body = new Box(Orientation.VERTICAL, 12);
            body.vexpand = true;
            append(body);
        }

        private EffectRack? target_rack(out string label, out PcmSource? src, out int64 offset, out int64 length, out string role) {
            label = "";
            src = null;
            offset = 0;
            length = 0;
            role = "";
            if (win.view_name == "waveform" && win.doc != null) {
                label = win.doc.title;
                var segs = win.doc.get_segments();
                if (segs.length > 0 && segs[0].source != null) {
                    src = segs[0].source;
                    offset = segs[0].offset;
                    length = segs[0].length;
                }
                role = win.doc.metadata.genre == "Speech" ? "dialogue" : "";
                return win.doc.rack;
            }
            var c = win.session_page.selected_clip;
            if (c != null) {
                label = c.name;
                src = c.source;
                offset = c.source_offset;
                length = c.length;
                role = c.role;
                return c.rack;
            }
            return null;
        }

        public void refresh() {
            Dialogs.clear(body);
            string label, role;
            PcmSource? src;
            int64 offset, length;
            var rack = target_rack(out label, out src, out offset, out length, out role);
            if (rack == null) {
                body.append(Singularity.Widgets.InspectorPanel.empty_state("audio-headphones", _("Select a Clip"), _("Choose a clip to tag it as dialogue, music, effects or ambience and get simple controls.")));
                return;
            }
            string[] ids = { "dialogue", "music", "sfx", "ambience" };
            string[] names = { _("Dialogue"), _("Music"), _("Effects"), _("Ambience") };
            int current = -1;
            for (int i = 0; i < ids.length; i++) {
                if (ids[i] == role) current = i;
            }
            var g = new PreferencesGroup(label, _("Tag the audio to get simple controls for it"));
            var detect = new Button.with_label(_("Detect"));
            detect.valign = Align.CENTER;
            detect.tooltip_text = _("Detect Automatically");
            g.add_header_suffix(detect);
            var type = Dialogs.choice_row(g, _("Audio Type"), names, current < 0 ? 0 : current);
            if (current < 0) type.current_value = _("Not Set");
            body.append(g);
            var controls = new Box(Orientation.VERTICAL, 12);
            body.append(controls);
            type.notify["index"].connect(() => {
                string id = ids[type.index];
                set_role(id);
                build_controls(controls, rack, id);
            });
            detect.clicked.connect(() => {
                if (src == null) return;
                var scores = EssentialSound.classify_source(src, offset, length);
                var r = EssentialSound.best(scores);
                for (int i = 0; i < ids.length; i++) {
                    if (ids[i] == r.id()) type.index = i;
                }
                win.toast(_("Looks like %s (%.0f%% sure)").printf(r.label().down(), scores[(int) r] * 100));
            });
            if (role != "") build_controls(controls, rack, role);
        }

        private void set_role(string id) {
            var c = win.session_page.selected_clip;
            if (c != null && win.view_name != "waveform") {
                c.role = id;
                var t = win.session_page.selected_track;
                if (t != null && t.role == "") t.role = id;
                if (id == "music" && t != null) t.duck = true;
            }
        }

        private Scale slider(PreferencesGroup g, string title, double value, owned ValueFunc f) {
            var row = new ActionRow(title);
            var s = new Scale.with_range(Orientation.HORIZONTAL, 0, 1, 0.01);
            s.draw_value = false;
            s.hexpand = true;
            s.valign = Align.CENTER;
            s.set_size_request(110, -1);
            s.set_value(value);
            s.update_property(AccessibleProperty.LABEL, title, -1);
            s.value_changed.connect(() => f(s.get_value()));
            row.add_suffix(s);
            g.add_row(row);
            return s;
        }

        public delegate void ValueFunc(double v);

        private void build_controls(Box box, EffectRack rack, string role) {
            Dialogs.clear(box);
            var g = new PreferencesGroup(SoundRole.from_id(role).label());
            switch (role) {
            case "dialogue":
                slider(g, _("Reduce Noise"), 0, (v) => EssentialSound.set_noise(rack, v));
                slider(g, _("Reduce Rumble"), 0, (v) => EssentialSound.set_rumble(rack, v));
                slider(g, _("Clarity"), 0, (v) => EssentialSound.set_clarity(rack, v));
                var lev = Dialogs.switch_row(g, _("Even Out the Level"), false, _("Gentle compression for steady speech"));
                lev.notify["active"].connect(() => EssentialSound.set_leveler(rack, lev.active));
                Dialogs.button_row(g, _("Podcast Loudness"), _("Matches -16 LUFS"), _("Match"), () => {
                    var c = win.session_page.selected_clip;
                    if (c != null && win.session != null) LoudnessMatch.match_clips(win.session, single(c), -16);
                    else win.normalize_loudness.begin(-16, -1);
                });
                break;
            case "music":
                var duck = Dialogs.switch_row(g, _("Duck Under Dialogue"), true, _("Lowers the music while someone speaks"));
                duck.notify["active"].connect(() => {
                    var t = win.session_page.selected_track;
                    if (t != null) t.duck = duck.active;
                });
                slider(g, _("Ducking Depth"), 0.4, (v) => {
                    var t = win.session_page.selected_track;
                    if (t != null) t.duck_db = -6 - v * 24;
                });
                Dialogs.button_row(g, _("Automatic Ducking"), _("Writes volume automation now"), _("Duck"), () => {
                    var t = win.session_page.selected_track;
                    if (t != null && win.session != null) {
                        int n = Ducking.apply(win.session, t, t.duck_db, 250, 500);
                        win.toast(_("Music ducked under %d speech passages").printf(n));
                        win.session_page.toggle_lanes(t, true);
                    }
                });
                break;
            case "sfx":
                slider(g, _("Reverb"), 0, (v) => EssentialSound.set_reverb(rack, v));
                slider(g, _("Stereo Width"), 0.5, (v) => EssentialSound.set_width(rack, v * 2));
                break;
            default:
                slider(g, _("Reverb"), 0, (v) => EssentialSound.set_reverb(rack, v));
                slider(g, _("Stereo Width"), 0.5, (v) => EssentialSound.set_width(rack, v * 2));
                var duck2 = Dialogs.switch_row(g, _("Duck Under Dialogue"), false);
                duck2.notify["active"].connect(() => {
                    var t = win.session_page.selected_track;
                    if (t != null) t.duck = duck2.active;
                });
                break;
            }
            box.append(g);
        }

        private Gee.List<Clip> single(Clip c) {
            var l = new Gee.ArrayList<Clip>();
            l.add(c);
            return l;
        }
    }

    public class TranscriptPanel : Box {
        private weak WaveWindow win;
        private FlowBox words;
        private PreferencesGroup status_group;
        private PreferencesGroup words_group;
        private Button run;
        private Button apply;
        private Transcript? transcript = null;
        private Gee.ArrayList<ToggleButton> chips = new Gee.ArrayList<ToggleButton>();
        private Cancellable? cancel = null;

        public TranscriptPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            var g = new PreferencesGroup(_("Speech to Text"));
            run = new Button.with_label(_("Transcribe"));
            run.valign = Align.CENTER;
            run.add_css_class("suggested-action");
            run.clicked.connect(() => transcribe.begin());
            g.add_header_suffix(run);
            g.description = _("Speech is turned into text on this computer with the desktop dictation engine. Click words to strike them out, then cut them from the audio.");
            append(g);
            status_group = g;
            words_group = new PreferencesGroup(_("Words"));
            apply = new Button.with_label(_("Cut Struck Words"));
            apply.valign = Align.CENTER;
            apply.tooltip_text = _("Cut Struck Words from the Audio");
            apply.clicked.connect(() => apply_cuts());
            words_group.add_header_suffix(apply);
            words = new FlowBox();
            words.selection_mode = SelectionMode.NONE;
            words.max_children_per_line = 30;
            words.column_spacing = 0;
            words.row_spacing = 0;
            words.margin_start = 8;
            words.margin_end = 8;
            words.margin_top = 8;
            words.margin_bottom = 8;
            words_group.add_row(words);
            words_group.visible = false;
            append(words_group);
        }

        private string status {
            set { status_group.description = value; }
        }

        public void refresh() {
            transcript = win.current_transcript();
            fill();
        }

        private void fill() {
            Widget? c;
            while ((c = words.get_first_child()) != null) words.remove(c);
            chips.clear();
            words_group.visible = transcript != null && transcript.words.size > 0;
            if (transcript == null) return;
            foreach (var w in transcript.words) {
                var b = new ToggleButton.with_label(w.text);
                b.add_css_class("flat");
                b.add_css_class("wave-word");
                b.active = w.deleted;
                if (w.deleted) b.add_css_class("deleted");
                var word = w;
                b.toggled.connect(() => {
                    word.deleted = b.active;
                    if (b.active) b.add_css_class("deleted");
                    else b.remove_css_class("deleted");
                });
                var right = new GestureClick();
                right.button = 3;
                right.pressed.connect(() => win.go_to_marker(new Marker(word.text, word.start, word.end - word.start)));
                b.add_controller(right);
                b.tooltip_text = Timecode.format(w.start, transcript.rate);
                words.append(b);
                chips.add(b);
            }
        }

        public void highlight(int64 frame) {
            if (transcript == null || chips.size != transcript.words.size || win.current_panel() != "transcript") return;
            for (int i = 0; i < chips.size; i++) {
                var w = transcript.words[i];
                if (frame >= w.start && frame < w.end) chips[i].add_css_class("current");
                else chips[i].remove_css_class("current");
            }
        }

        private async void transcribe() {
            Renderable? src = win.view_name == "waveform" ? (Renderable?) win.doc : (Renderable?) win.session;
            if (src == null) return;
            var tr = new Transcriber();
            if (tr.backend == null) {
                status = _("No speech engine is available. Install the dictation models from Settings, or set a command in the [Transcription] section of singularity/wave.conf.");
                return;
            }
            run.sensitive = false;
            status = _("Listening…");
            tr.progress.connect((f) => status = _("Transcribing, %.0f%%").printf(f * 100));
            cancel = new Cancellable();
            try {
                if (win.session != null && src == win.session) win.session.mixer.prepare_clips();
                transcript = yield tr.transcribe(src, win.app.str("transcription-language", ""), cancel);
                if (win.view_name == "waveform" && win.doc != null) win.doc.transcript_json = transcript.to_json();
                else if (win.session != null) win.session.transcript_json = transcript.to_json();
                status = ngettext("%d word", "%d words", transcript.words.size).printf(transcript.words.size);
                fill();
            } catch (Error e) {
                status = e.message;
            }
            run.sensitive = true;
        }

        private void apply_cuts() {
            if (transcript == null) return;
            win.stop_all();
            int n;
            if (win.view_name == "waveform" && win.doc != null) n = TextEdit.apply_document(win.doc, transcript);
            else if (win.session != null) n = TextEdit.apply_session(win.session, transcript);
            else return;
            win.after_edit();
            win.toast(ngettext("%d cut made", "%d cuts made", n).printf(n));
            fill();
        }

        public void export_srt() {
            var t = transcript ?? win.current_transcript();
            if (t == null) {
                win.toast(_("Transcribe the audio first"));
                return;
            }
            Dialogs.save.begin(win, _("Export Subtitles"), "transcript.srt", _("Subtitles"), { "srt" }, (o, r) => {
                var f = Dialogs.save.end(r);
                if (f == null) return;
                try {
                    FileUtils.set_contents(f.get_path(), t.srt());
                    win.toast(_("Subtitles exported"));
                } catch (Error e) {
                    win.show_error(_("Could Not Export"), e.message);
                }
            });
        }
    }

    public class VideoPanel : Box {
        private weak WaveWindow win;
        private Picture picture;
        private Widget empty;
        private PreferencesGroup group;
        private Singularity.Widgets.VideoPaintable? paintable = null;
        private dynamic Gst.Element? playbin = null;
        private string current_uri = "";
        private ActionRow info;
        private int64 last_seek = -1;

        public VideoPanel(WaveWindow win) {
            Object(orientation: Orientation.VERTICAL, spacing: 12);
            this.win = win;
            empty = Singularity.Widgets.InspectorPanel.empty_state("video-x-generic", _("No Video Reference"), _("Add a video reference from Add Track in a multitrack session; it follows the playhead."));
            append(empty);
            group = new PreferencesGroup(_("Video Reference"));
            picture = new Picture();
            picture.set_size_request(200, 160);
            picture.content_fit = ContentFit.CONTAIN;
            picture.margin_top = 8;
            picture.margin_bottom = 8;
            picture.margin_start = 8;
            picture.margin_end = 8;
            group.add_row(picture);
            info = new ActionRow(_("Frame"));
            group.add_row(info);
            append(group);
            group.visible = false;
        }

        public void refresh() {
            var s = win.session;
            bool has = s != null && win.view_name != "waveform" && s.video_track() != null;
            group.visible = has;
            empty.visible = !has;
            if (has) sync(win.session_page.playhead >= 0 ? win.session_page.playhead : win.session_page.cursor);
        }

        public void sync(int64 frame) {
            var s = win.session;
            if (s == null || win.current_panel() != "video") return;
            var vt = s.video_track();
            if (vt == null) return;
            VideoSegment? seg = null;
            foreach (var v in vt.video_segments) {
                int64 len = (v.end_ms - v.start_ms) * s.rate / 1000;
                if (frame >= v.position && frame < v.position + len) seg = v;
            }
            if (seg == null) return;
            if (seg.uri != current_uri) open(seg.uri);
            int64 ms = seg.start_ms + (frame - seg.position) * 1000 / s.rate;
            if (last_seek >= 0 && (ms - last_seek).abs() < 40) return;
            last_seek = ms;
            if (playbin != null) ((Gst.Element) playbin).seek_simple(Gst.Format.TIME, Gst.SeekFlags.FLUSH | Gst.SeekFlags.KEY_UNIT, ms * Gst.MSECOND);
            info.subtitle = "%s, %s".printf(Path.get_basename(File.new_for_uri(seg.uri).get_path() ?? seg.uri), Timecode.format(ms * s.rate / 1000, s.rate));
        }

        private void open(string uri) {
            if (playbin != null) ((Gst.Element) playbin).set_state(Gst.State.NULL);
            Singularity.Widgets.VideoPaintable.ensure_gstreamer();
            paintable = new Singularity.Widgets.VideoPaintable(false);
            playbin = Gst.ElementFactory.make("playbin", "wave-video");
            if (playbin == null || paintable.sink == null) {
                info.subtitle = _("Video playback is not available on this system");
                return;
            }
            playbin.uri = uri;
            playbin.video_sink = paintable.sink;
            playbin.audio_sink = Gst.ElementFactory.make("fakesink", null);
            picture.paintable = paintable;
            ((Gst.Element) playbin).set_state(Gst.State.PAUSED);
            current_uri = uri;
        }
    }
}
