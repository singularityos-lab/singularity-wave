using Gtk;
using Singularity.Accounts;
using Singularity.Widgets;

namespace Singularity.Apps.Wave {

    public delegate void CloudFileFunc(GLib.File file);

    public class CloudActions : Object {
        private static string[] mime_types() {
            return { "application/x-wave-session", "application/zip", "audio/x-wav", "audio/flac", "audio/mpeg", "audio/ogg", "audio/mp4", "audio/x-aiff" };
        }

        public static async void open(Gtk.Window window, owned CloudFileFunc open_file) {
            var file = yield CloudFileDialog.open(window, mime_types());
            if (file != null) open_file(file.local);
        }

        public static async void save(WaveWindow window) {
            string dir;
            try {
                dir = DirUtils.make_tmp("singularity-wave-XXXXXX");
            } catch (Error e) {
                window.toast(e.message);
                return;
            }
            string name;
            GLib.File source;
            try {
                if (window.view_name == "waveform" && window.doc != null) {
                    name = window.doc.title.down().has_suffix(".wav") || window.doc.title.down().has_suffix(".flac") ? window.doc.title : window.doc.title + ".wav";
                    source = GLib.File.new_for_path(Path.build_filename(dir, name));
                    var o = window.export_defaults(name.down().has_suffix(".flac") ? ExportFormat.FLAC : ExportFormat.WAV);
                    o.metadata = window.doc.metadata;
                    o.markers = window.doc.markers;
                    Exporter.export_sync(window.doc, source.get_path(), o);
                } else if (window.session != null) {
                    name = (window.session.title != "" ? window.session.title : _("Untitled")) + ".wave";
                    source = GLib.File.new_for_path(Path.build_filename(dir, name));
                    SessionFile.save(window.session, source.get_path());
                } else {
                    return;
                }
            } catch (Error e) {
                window.show_error(_("Could Not Save"), e.message);
                return;
            }
            var cloud = yield CloudFileDialog.save(window, source, name);
            FileUtils.remove(source.get_path());
            DirUtils.remove(dir);
            if (cloud == null) return;
            window.toast(_("Saved to %s").printf(account_name(cloud.local)));
        }

        public static void sync_back(Singularity.Widgets.Window window, GLib.File file) {
            if (CloudFile.for_local(file) == null) return;
            CloudFile.sync_back.begin(file, null, (obj, res) => {
                try {
                    if (CloudFile.sync_back.end(res)) window.add_toast(new Toast(_("Saved to %s").printf(account_name(file))));
                } catch (Error e) {
                    window.add_toast(new Toast(_("Not saved to %s: %s").printf(account_name(file), e.message)));
                }
            });
        }

        private static string account_name(GLib.File file) {
            var cloud = CloudFile.for_local(file);
            var account = cloud != null ? Manager.get_default().get_account(cloud.account_id) : null;
            return account != null ? account.display_name : _("Online Account");
        }
    }

    public class WavePrintSource : Singularity.Print.PageSource {
        private Document? doc = null;
        private Session? session = null;
        private Transcript? transcript = null;
        private Singularity.Print.PageFormat? format = null;
        private int pages = 1;
        private Gee.ArrayList<string> lines = new Gee.ArrayList<string>();

        public WavePrintSource.for_document(Document d, Transcript? t) {
            doc = d;
            transcript = t;
            title = d.title;
            setup();
        }

        public WavePrintSource.for_session(Session s, Transcript? t) {
            session = s;
            transcript = t;
            title = s.title;
            setup();
        }

        private void setup() {
            var x = new Singularity.Print.ExtraOptions(_("Audio"), _("What is printed next to the overview"));
            x.add_switch("markers", _("Markers and Chapters"), null, true);
            x.add_switch("transcript", _("Transcript"), null, true);
            x.add_switch("tracks", _("Track Sheet"), null, true);
            extra_options = x;
        }

        public override async int paginate(Singularity.Print.PageFormat f) throws Error {
            format = f;
            page_width = f.width;
            page_height = f.height;
            lines.clear();
            int rate = doc != null ? doc.rate : session.rate;
            var markers = doc != null ? doc.markers : session.markers;
            if (extra_options.get_bool("tracks") && session != null) {
                lines.add("#" + _("Tracks"));
                foreach (var t in session.tracks) {
                    string fx = "";
                    foreach (var e in t.rack.effects) fx += (fx != "" ? ", " : "") + e.title;
                    lines.add("%s    %s    %.1f dB    %s".printf(t.name, t.kind == TrackKind.BUS ? _("Bus") : t.kind == TrackKind.VIDEO ? _("Video") : ngettext("%d clip", "%d clips", t.clips.size).printf(t.clips.size), t.volume_db, fx));
                }
                lines.add("");
            }
            if (extra_options.get_bool("markers") && markers.size > 0) {
                lines.add("#" + _("Markers"));
                foreach (var m in markers) lines.add("%s    %s".printf(Timecode.format(m.start, rate), m.name));
                lines.add("");
            }
            if (extra_options.get_bool("transcript") && transcript != null) {
                lines.add("#" + _("Transcript"));
                var sb = new StringBuilder();
                foreach (var w in transcript.words) {
                    if (w.deleted) continue;
                    if (sb.len > 90) {
                        lines.add(sb.str);
                        sb.truncate();
                    }
                    if (sb.len > 0) sb.append_c(' ');
                    sb.append(w.text);
                }
                if (sb.len > 0) lines.add(sb.str);
            }
            double first_page = (f.content_height - 260) / 14;
            double per_page = f.content_height / 14;
            pages = 1 + (lines.size > first_page ? (int) Math.ceil((lines.size - first_page) / per_page) : 0);
            return pages;
        }

        public override void render_page(Cairo.Context cr, int index) {
            if (format == null) return;
            double x = format.margin_left, y = format.margin_top, w = format.content_width;
            int start_line = 0;
            cr.set_source_rgb(0, 0, 0);
            if (index == 0) {
                text(cr, title, x, y, 16, true);
                y += 26;
                Renderable src = doc != null ? (Renderable) doc : (Renderable) session;
                int rate = src.sample_rate;
                text(cr, "%s, %d Hz, %d %s".printf(Timecode.format(src.total_frames, rate), rate, src.channel_count, _("channels")), x, y, 9, false);
                y += 20;
                double h = 160;
                cr.set_source_rgb(0.95, 0.95, 0.95);
                cr.rectangle(x, y, w, h);
                cr.fill();
                int cols = (int) w;
                if (doc != null) {
                    var lo = new float[cols];
                    var hi = new float[cols];
                    double fpp = (double) int64.max(1, doc.length) / cols;
                    for (int c = 0; c < doc.channels && c < 2; c++) {
                        doc.peaks(0, fpp, cols, c, lo, hi);
                        double mid = y + h / (doc.channels > 1 ? 4 : 2) * (c * 2 + 1);
                        double amp = h / (doc.channels > 1 ? 4 : 2) - 4;
                        cr.set_source_rgb(0.21, 0.52, 0.89);
                        for (int i = 0; i < cols; i++) cr.rectangle(x + i, mid - hi[i] * amp, 1, double.max(0.5, (hi[i] - lo[i]) * amp));
                        cr.fill();
                    }
                } else {
                    int64 len = int64.max(1, session.length);
                    double lane = h / int.max(1, session.tracks.size);
                    for (int t = 0; t < session.tracks.size; t++) {
                        var tr = session.tracks[t];
                        var col = Gdk.RGBA();
                        col.parse(tr.color);
                        cr.set_source_rgba(col.red, col.green, col.blue, 0.6);
                        foreach (var c in tr.clips) cr.rectangle(x + w * c.position / len, y + t * lane + 2, double.max(1, w * c.length / len), lane - 4);
                        cr.fill();
                    }
                }
                var markers = doc != null ? doc.markers : session.markers;
                int64 total = int64.max(1, src.total_frames);
                cr.set_source_rgb(0.9, 0.6, 0.0);
                foreach (var m in markers) {
                    cr.rectangle(x + w * m.start / total, y, 1, h);
                    cr.fill();
                }
                y += h + 24;
            } else {
                double first_page = (format.content_height - 260) / 14;
                double per_page = format.content_height / 14;
                start_line = (int) (first_page + (index - 1) * per_page);
            }
            cr.set_source_rgb(0, 0, 0);
            for (int i = start_line; i < lines.size && y < format.margin_top + format.content_height - 14; i++) {
                string l = lines[i];
                if (l.has_prefix("#")) text(cr, l.substring(1), x, y, 12, true);
                else text(cr, l, x, y, 9, false);
                y += 14;
            }
        }

        private void text(Cairo.Context cr, string s, double x, double y, double size, bool bold) {
            var layout = Pango.cairo_create_layout(cr);
            var fd = new Pango.FontDescription();
            fd.set_family("Sans");
            fd.set_size((int) (size * Pango.SCALE));
            if (bold) fd.set_weight(Pango.Weight.BOLD);
            layout.set_font_description(fd);
            layout.set_text(s, -1);
            layout.set_width((int) (format.content_width * Pango.SCALE));
            layout.set_ellipsize(Pango.EllipsizeMode.END);
            cr.move_to(x, y);
            Pango.cairo_show_layout(cr, layout);
        }
    }
}
