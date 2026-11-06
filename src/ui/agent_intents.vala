namespace Singularity.Apps.Wave {

    internal class WaveIntents : Object {
        private const string[] EDITS = {
            "silence", "crop", "delete", "invert", "reverse", "dc", "fade-in", "fade-out", "enhance", "heal",
            "amplify", "normalize-peak", "normalize-loudness", "insert-silence", "tone"
        };
        private const string[] FORMATS = { "wav", "bwf", "aiff", "caf", "flac", "mp3", "ogg", "opus", "m4a" };

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static double num (Json.Object args, string key, double fallback) {
            return args.has_member (key) ? args.get_double_member (key) : fallback;
        }

        private static Json.Node obj (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            return node;
        }

        private static string list (string[] values) {
            var b = new StringBuilder ("[");
            for (int i = 0; i < values.length; i++) {
                if (i > 0) b.append (",");
                b.append ("\"").append (values[i]).append ("\"");
            }
            return b.append ("]").str;
        }

        private static double seconds (int64 frames, int rate) {
            return rate <= 0 ? 0.0 : Math.round (frames * 1000.0 / rate) / 1000.0;
        }

        private static int64 frames (double secs, int rate) {
            return (int64) Math.round (secs * rate);
        }

        private static Document need_doc (WaveWindow w) throws Error {
            if (w.doc == null || w.view_name != "waveform") throw new IOError.FAILED ("no audio file is open in the waveform editor");
            return w.doc;
        }

        private static Json.Node outline (WaveWindow w, bool loudness) {
            var o = new Json.Object ();
            o.set_string_member ("view", w.view_name);
            var d = w.doc;
            if (d != null && w.view_name == "waveform") {
                o.set_string_member ("title", d.title);
                o.set_string_member ("path", d.path);
                o.set_int_member ("sample_rate", d.rate);
                o.set_int_member ("channels", d.channels);
                o.set_double_member ("duration", seconds (d.length, d.rate));
                o.set_boolean_member ("modified", d.modified);
                o.set_boolean_member ("can_undo", d.can_undo);
                o.set_boolean_member ("can_redo", d.can_redo);
                if (w.wave.has_selection) {
                    var s = new Json.Object ();
                    s.set_double_member ("start", seconds (w.wave.sel_a, d.rate));
                    s.set_double_member ("end", seconds (w.wave.sel_b, d.rate));
                    o.set_object_member ("selection", s);
                }
                var marks = new Json.Array ();
                foreach (var m in d.markers) {
                    var mo = new Json.Object ();
                    mo.set_string_member ("name", m.name);
                    mo.set_double_member ("start", seconds (m.start, d.rate));
                    if (m.length > 0) mo.set_double_member ("length", seconds (m.length, d.rate));
                    mo.set_string_member ("kind", m.kind);
                    marks.add_object_element (mo);
                }
                o.set_array_member ("markers", marks);
                if (loudness && d.length > 0) {
                    var r = Loudness.measure_renderable (d);
                    var lo = new Json.Object ();
                    if (r.integrated.is_finite ()) lo.set_double_member ("integrated_lufs", Math.round (r.integrated * 10) / 10.0);
                    if (r.true_peak.is_finite ()) lo.set_double_member ("true_peak_db", Math.round (r.true_peak * 10) / 10.0);
                    if (r.sample_peak.is_finite ()) lo.set_double_member ("sample_peak_db", Math.round (r.sample_peak * 10) / 10.0);
                    lo.set_double_member ("range_lu", Math.round (r.range * 10) / 10.0);
                    o.set_object_member ("loudness", lo);
                }
            } else if (w.session != null) {
                var s = w.session;
                o.set_string_member ("title", s.title);
                o.set_string_member ("path", s.path);
                o.set_double_member ("duration", seconds (s.length, s.rate));
                var tracks = new Json.Array ();
                foreach (var t in s.tracks) tracks.add_string_element (t.name);
                o.set_array_member ("tracks", tracks);
            }
            return obj (o);
        }

        private static void range (WaveWindow w, Document d, Json.Object args, out int64 a, out int64 b) {
            if (args.has_member ("start") || args.has_member ("end")) {
                a = frames (num (args, "start", 0), d.rate).clamp (0, d.length);
                b = args.has_member ("end") ? frames (num (args, "end", 0), d.rate).clamp (0, d.length) : d.length;
            } else if (w.wave.has_selection) {
                a = w.wave.sel_a;
                b = w.wave.sel_b;
            } else {
                a = 0;
                b = d.length;
            }
        }

        private static void edit (WaveWindow w, Json.Object args) throws Error {
            var d = need_doc (w);
            string op = text (args, "operation");
            if (!(op in EDITS)) throw new IOError.INVALID_ARGUMENT ("unknown operation %s", op);
            int64 a, b;
            range (w, d, args, out a, out b);
            bool ranged = op != "insert-silence" && op != "tone";
            if (ranged && b <= a) throw new IOError.INVALID_ARGUMENT ("the range is empty");
            w.stop_all ();
            switch (op) {
            case "silence": d.silence (a, b); break;
            case "crop": d.trim_to (a, b); break;
            case "delete": d.delete_range (a, b); break;
            case "invert": Processes.invert (d, a, b); break;
            case "reverse": Processes.reverse (d, a, b); break;
            case "dc": Processes.remove_dc (d, a, b); break;
            case "fade-in": Processes.fade (d, a, b, true, w.wave.fade_curve); break;
            case "fade-out": Processes.fade (d, a, b, false, w.wave.fade_curve); break;
            case "enhance": Processes.enhance_speech (d, a, b, num (args, "amount", 0.6).clamp (0, 1)); break;
            case "heal": Processes.spot_heal (d, a, b, 20, d.rate / 2); break;
            case "amplify":
                if (!args.has_member ("db")) throw new IOError.INVALID_ARGUMENT ("amplify needs db");
                Processes.amplify (d, a, b, num (args, "db", 0).clamp (-60, 40));
                break;
            case "normalize-peak": Processes.normalize_peak (d, a, b, num (args, "db", -1).clamp (-60, 0), false); break;
            case "normalize-loudness": Processes.normalize_loudness (d, a, b, num (args, "lufs", -16).clamp (-70, 0), num (args, "db", -1).clamp (-20, 0)); break;
            case "insert-silence": {
                double len = num (args, "seconds", 0);
                if (len <= 0) throw new IOError.INVALID_ARGUMENT ("insert-silence needs seconds");
                int64 at = args.has_member ("start") ? a : w.wave.cursor.clamp (0, d.length);
                d.insert_silence (at, frames (len, d.rate));
                break;
            }
            default: {
                double len = num (args, "seconds", 0);
                if (len <= 0) throw new IOError.INVALID_ARGUMENT ("tone needs seconds");
                int64 at = args.has_member ("start") ? a : w.wave.cursor.clamp (0, d.length);
                Processes.generate_tone (d, at, len, num (args, "frequency", 440).clamp (10, d.rate / 2.0), num (args, "db", -12).clamp (-60, 0));
                break;
            }
            }
            if (op == "crop" || op == "delete") w.wave.set_selection (0, 0);
            w.after_edit ();
            if (op == "crop") w.wave.zoom_fit ();
        }

        private static ExportFormat format_for (string path, string id) throws Error {
            if (id != "") {
                if (!(id in FORMATS)) throw new IOError.INVALID_ARGUMENT ("unknown format %s", id);
                return ExportFormat.from_id (id);
            }
            string lower = path.down ();
            foreach (var f in ExportFormat.all ()) if (lower.has_suffix ("." + f.extension ())) return f;
            throw new IOError.INVALID_ARGUMENT ("give a format or a path ending in a known extension");
        }

        private static string with_extension (string path, ExportFormat f) {
            return path.down ().has_suffix ("." + f.extension ()) ? path : path + "." + f.extension ();
        }

        private static async Json.Node handle (WaveApp app, string name, Json.Object args) throws Error {
            var w = app.target_window ();
            switch (name) {
            case "wave_outline":
                return outline (w, args.has_member ("loudness") && args.get_boolean_member ("loudness"));
            case "wave_open": {
                string path = text (args, "path");
                if (!FileUtils.test (path, FileTest.IS_REGULAR)) throw new IOError.NOT_FOUND ("%s does not exist", path);
                var media = yield new Decoder ().decode (path);
                w.set_document (Document.from_media (media));
                return outline (w, false);
            }
            case "wave_select": {
                var d = need_doc (w);
                if (args.has_member ("clear") && args.get_boolean_member ("clear")) {
                    w.wave.set_selection (0, 0);
                } else {
                    int64 a, b;
                    if (!args.has_member ("start") && !args.has_member ("end")) {
                        a = 0;
                        b = d.length;
                    } else {
                        range (w, d, args, out a, out b);
                    }
                    if (b <= a) throw new IOError.INVALID_ARGUMENT ("the end must come after the start");
                    w.wave.set_selection (a, b);
                }
                return outline (w, false);
            }
            case "wave_edit":
                edit (w, args);
                return outline (w, false);
            case "wave_history": {
                var d = need_doc (w);
                string step = text (args, "step");
                if (step == "undo") {
                    if (!d.can_undo) throw new IOError.FAILED ("there is nothing to undo");
                    d.undo ();
                } else if (step == "redo") {
                    if (!d.can_redo) throw new IOError.FAILED ("there is nothing to redo");
                    d.redo ();
                } else {
                    throw new IOError.INVALID_ARGUMENT ("step must be undo or redo");
                }
                w.after_edit ();
                return outline (w, false);
            }
            case "wave_marker": {
                var d = need_doc (w);
                string label = text (args, "name").strip ();
                if (args.has_member ("remove") && args.get_boolean_member ("remove")) {
                    Marker? found = null;
                    foreach (var m in d.markers) if (m.name == label) { found = m; break; }
                    if (found == null) throw new IOError.NOT_FOUND ("there is no marker named %s", label);
                    d.remove_marker (found);
                } else {
                    if (!args.has_member ("at")) throw new IOError.INVALID_ARGUMENT ("a marker needs at, in seconds");
                    int64 at = frames (num (args, "at", 0), d.rate).clamp (0, d.length);
                    int64 len = frames (num (args, "length", 0), d.rate).clamp (0, d.length - at);
                    if (label == "") label = _("Marker %d").printf (d.markers.size + 1);
                    d.add_marker (new Marker (label, at, len, len > 0 ? "chapter" : "cue"));
                }
                w.after_edit ();
                return outline (w, false);
            }
            case "wave_save": {
                var d = need_doc (w);
                string path = text (args, "path");
                if (path == "") path = d.path;
                if (path == "") throw new IOError.INVALID_ARGUMENT ("the file has no path yet; give one");
                var f = format_for (path, text (args, "format"));
                path = with_extension (path, f);
                var o = w.export_defaults (f);
                o.metadata = d.metadata;
                o.markers = d.markers;
                string tmp = path + ".saving";
                try {
                    yield new Exporter ().export (d, tmp, o);
                    FileUtils.rename (tmp, path);
                } catch (Error e) {
                    FileUtils.unlink (tmp);
                    throw e;
                }
                d.modified = false;
                d.path = path;
                d.title = Path.get_basename (path);
                w.update_title ();
                return outline (w, false);
            }
            default: {
                var d = need_doc (w);
                string path = text (args, "path");
                if (path == "") throw new IOError.INVALID_ARGUMENT ("a path is required");
                var f = format_for (path, text (args, "format"));
                if (!f.available ()) throw new IOError.NOT_SUPPORTED ("%s export is not available on this system", f.label ());
                path = with_extension (path, f);
                var o = w.export_defaults (f);
                o.metadata = d.metadata;
                o.markers = d.markers;
                yield new Exporter ().export (d, path, o);
                var r = new Json.Object ();
                r.set_string_member ("path", path);
                r.set_string_member ("format", f.id ());
                return obj (r);
            }
            }
        }

        private static void add (WaveApp app, string name, string description, string schema, Singularity.AppIntentRisk risk) {
            app.agent.add_async_intent (name, description, schema, risk, (args, reply) => {
                handle.begin (app, name, args, (o, res) => {
                    try {
                        reply (handle.end (res), null);
                    } catch (Error e) {
                        reply (null, e);
                    }
                });
            });
        }

        internal static void install (WaveApp app) {
            add (app, "wave_outline", "Read the open audio file: path, sample rate, channels, duration, selection, markers and undo state; with loudness, also measure integrated loudness and peaks. For a multitrack session, its tracks.",
                "{\"type\":\"object\",\"properties\":{\"loudness\":{\"type\":\"boolean\"}}}", Singularity.AppIntentRisk.READ);
            add (app, "wave_open", "Open an audio or video file in the waveform editor.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}", Singularity.AppIntentRisk.UNDOABLE);
            add (app, "wave_select", "Select a time range in seconds. Without start and end it selects everything; clear removes the selection.",
                "{\"type\":\"object\",\"properties\":{\"start\":{\"type\":\"number\"},\"end\":{\"type\":\"number\"},\"clear\":{\"type\":\"boolean\"}}}", Singularity.AppIntentRisk.UNDOABLE);
            add (app, "wave_edit", "Edit the audio in a range (start and end in seconds, else the selection, else the whole file): silence, crop, delete, invert, reverse, remove DC, fades, speech enhance, click heal, amplify by db, normalize peak to db, normalize loudness to lufs with a db ceiling, insert silence or a tone of seconds at start.",
                "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"enum\":" + list (EDITS) + "},\"start\":{\"type\":\"number\"},\"end\":{\"type\":\"number\"},\"db\":{\"type\":\"number\"},\"lufs\":{\"type\":\"number\"},\"amount\":{\"type\":\"number\"},\"seconds\":{\"type\":\"number\"},\"frequency\":{\"type\":\"number\"}},\"required\":[\"operation\"]}", Singularity.AppIntentRisk.UNDOABLE);
            add (app, "wave_history", "Undo or redo the last edit.",
                "{\"type\":\"object\",\"properties\":{\"step\":{\"type\":\"string\",\"enum\":[\"undo\",\"redo\"]}},\"required\":[\"step\"]}", Singularity.AppIntentRisk.UNDOABLE);
            add (app, "wave_marker", "Add a marker at a time in seconds (with a length it becomes a chapter), or remove a marker by name.",
                "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"at\":{\"type\":\"number\"},\"length\":{\"type\":\"number\"},\"remove\":{\"type\":\"boolean\"}}}", Singularity.AppIntentRisk.UNDOABLE);
            add (app, "wave_save", "Save the audio file, over itself or to a new path; the format follows the extension unless given.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"format\":{\"type\":\"string\",\"enum\":" + list (FORMATS) + "}}}", Singularity.AppIntentRisk.IRREVERSIBLE);
            add (app, "wave_export", "Export a copy of the audio to a file, keeping the open file as it is.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"format\":{\"type\":\"string\",\"enum\":" + list (FORMATS) + "}},\"required\":[\"path\"]}", Singularity.AppIntentRisk.IRREVERSIBLE);
        }
    }
}
