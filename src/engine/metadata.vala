namespace Singularity.Apps.Wave {

    public class Metadata : Object {
        public string title { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public string album { get; set; default = ""; }
        public string genre { get; set; default = ""; }
        public string year { get; set; default = ""; }
        public string track { get; set; default = ""; }
        public string comment { get; set; default = ""; }
        public string copyright { get; set; default = ""; }
        public string description { get; set; default = ""; }
        public string originator { get; set; default = ""; }
        public string originator_reference { get; set; default = ""; }
        public string origination_date { get; set; default = ""; }
        public string origination_time { get; set; default = ""; }
        public int64 time_reference { get; set; default = 0; }
        public string coding_history { get; set; default = ""; }
        public string isrc { get; set; default = ""; }

        public Metadata copy() {
            var m = new Metadata();
            foreach (var spec in get_class().list_properties()) {
                var v = Value(spec.value_type);
                get_property(spec.name, ref v);
                m.set_property(spec.name, v);
            }
            return m;
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            foreach (var spec in get_class().list_properties()) {
                var v = Value(spec.value_type);
                get_property(spec.name, ref v);
                if (spec.value_type == typeof(string)) {
                    if ((string) v != "") o.set_string_member(spec.name, (string) v);
                } else if (spec.value_type == typeof(int64)) {
                    if ((int64) v != 0) o.set_int_member(spec.name, (int64) v);
                }
            }
            return o;
        }

        public static Metadata from_json(Json.Object? o) {
            var m = new Metadata();
            if (o == null) return m;
            foreach (var spec in m.get_class().list_properties()) {
                if (!o.has_member(spec.name)) continue;
                if (spec.value_type == typeof(string)) m.set_property(spec.name, o.get_string_member(spec.name));
                else if (spec.value_type == typeof(int64)) m.set_property(spec.name, o.get_int_member(spec.name));
            }
            return m;
        }

        public void merge_tags(Gst.TagList tags) {
            string s;
            if (tags.get_string(Gst.Tags.TITLE, out s)) title = s;
            if (tags.get_string(Gst.Tags.ARTIST, out s)) artist = s;
            if (tags.get_string(Gst.Tags.ALBUM, out s)) album = s;
            if (tags.get_string(Gst.Tags.GENRE, out s)) genre = s;
            if (tags.get_string(Gst.Tags.COMMENT, out s)) comment = s;
            if (tags.get_string(Gst.Tags.COPYRIGHT, out s)) copyright = s;
            if (tags.get_string(Gst.Tags.ISRC, out s)) isrc = s;
            uint n;
            if (tags.get_uint(Gst.Tags.TRACK_NUMBER, out n)) track = n.to_string();
            Gst.DateTime? dt;
            if (tags.get_date_time(Gst.Tags.DATE_TIME, out dt) && dt != null && dt.has_year()) year = dt.get_year().to_string();
            Date date = Date();
            if (year == "" && tags.get_date(Gst.Tags.DATE, out date) && date.valid()) year = ((int) date.get_year()).to_string();
        }

        public Gst.TagList to_tags() {
            var t = new Gst.TagList.empty();
            if (title != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.TITLE, title);
            if (artist != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.ARTIST, artist);
            if (album != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.ALBUM, album);
            if (genre != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.GENRE, genre);
            if (comment != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.COMMENT, comment);
            if (copyright != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.COPYRIGHT, copyright);
            if (isrc != "") t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.ISRC, isrc);
            if (track != "" && int.parse(track) > 0) t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.TRACK_NUMBER, (uint) int.parse(track));
            if (year != "" && int.parse(year) > 0) t.add(Gst.TagMergeMode.REPLACE, Gst.Tags.DATE_TIME, new Gst.DateTime.y(int.parse(year)));
            return t;
        }
    }

    public class Marker : Object {
        public string name { get; set; default = ""; }
        public int64 start { get; set; default = 0; }
        public int64 length { get; set; default = 0; }
        public string kind { get; set; default = "cue"; }

        public Marker(string name, int64 start, int64 length = 0, string kind = "cue") {
            Object(name: name, start: start, length: length, kind: kind);
        }

        public int64 end {
            get { return start + length; }
        }

        public bool is_range {
            get { return length > 0; }
        }

        public Marker copy() {
            return new Marker(name, start, length, kind);
        }

        public Json.Object to_json() {
            var o = new Json.Object();
            o.set_string_member("name", name);
            o.set_int_member("start", start);
            if (length > 0) o.set_int_member("length", length);
            o.set_string_member("kind", kind);
            return o;
        }

        public static Marker from_json(Json.Object o) {
            return new Marker(o.get_string_member_with_default("name", ""), o.get_int_member_with_default("start", 0),
                o.get_int_member_with_default("length", 0), o.get_string_member_with_default("kind", "cue"));
        }

        public static int compare(Marker a, Marker b) {
            return a.start < b.start ? -1 : a.start > b.start ? 1 : strcmp(a.name, b.name);
        }
    }

    namespace Timecode {
        public string format(int64 frames, int rate, bool with_ms = true) {
            if (rate <= 0) rate = 48000;
            bool neg = frames < 0;
            int64 f = neg ? -frames : frames;
            int64 ms = f * 1000 / rate;
            int64 h = ms / 3600000;
            int64 m = (ms / 60000) % 60;
            int64 s = (ms / 1000) % 60;
            string text = h > 0 ? "%lld:%02lld:%02lld".printf(h, m, s) : "%lld:%02lld".printf(m, s);
            if (with_ms) text += ".%03lld".printf(ms % 1000);
            return neg ? "-" + text : text;
        }

        public string clock(int64 frames, int rate) {
            if (rate <= 0) rate = 48000;
            int64 ms = int64.max(frames, 0) * 1000 / rate;
            return "%02lld:%02lld:%02lld.%03lld".printf(ms / 3600000, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000);
        }

        public int64 parse(string text, int rate) {
            string t = text.strip();
            if (t == "") return -1;
            string[] parts = t.split(":");
            double total = 0;
            foreach (string p in parts) {
                double v;
                if (!double.try_parse(p.replace(",", "."), out v)) return -1;
                total = total * 60 + v;
            }
            return (int64) Math.round(total * rate);
        }
    }
}
