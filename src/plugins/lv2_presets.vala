namespace Singularity.Apps.Wave {

    public class Lv2Preset : Object {
        public string uri { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public string bundle { get; set; default = ""; }
        public Gee.HashMap<string, double?> values { get; default = new Gee.HashMap<string, double?>(); }
    }

    public class Lv2Presets {
        public static Gee.List<Lv2Preset> read(string uri) {
            var list = new Gee.ArrayList<Lv2Preset>();
            var parser = new Json.Parser();
            try {
                parser.load_from_data(WavePlug.lv2_presets_json(uri));
            } catch (Error e) {
                return list;
            }
            var root = parser.get_root();
            if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return list;
            foreach (var node in root.get_array().get_elements()) {
                var o = node.get_object();
                var p = new Lv2Preset();
                p.uri = o.get_string_member_with_default("uri", "");
                p.label = o.get_string_member_with_default("label", p.uri);
                p.bundle = o.get_string_member_with_default("bundle", "");
                if (o.has_member("values")) {
                    var values = o.get_object_member("values");
                    foreach (string member in values.get_members()) p.values[member] = values.get_double_member(member);
                }
                list.add(p);
            }
            list.sort((a, b) => a.label.collate(b.label));
            return list;
        }

        public static Gee.List<string> list(string uri) {
            var labels = new Gee.ArrayList<string>();
            foreach (var p in read(uri)) labels.add(p.label);
            return labels;
        }

        public static bool load(PluginEffect e, string preset_uri_or_label) {
            if (!e.kind.has_prefix("lv2:")) return false;
            foreach (var p in read(e.info.uri)) {
                if (p.uri != preset_uri_or_label && p.label != preset_uri_or_label) continue;
                foreach (var entry in p.values.entries) e.set_plugin_value(entry.key, entry.value);
                return true;
            }
            return false;
        }

        private static string slug(string text) {
            var b = new StringBuilder();
            unichar c;
            int i = 0;
            while (text.get_next_char(ref i, out c)) {
                if (c.isalnum() && c < 128) b.append_unichar(c.tolower());
                else if (b.len > 0 && b.str[b.len - 1] != '_') b.append_c('_');
            }
            string s = b.str;
            while (s.has_suffix("_")) s = s.substring(0, s.length - 1);
            return s != "" ? s : "preset";
        }

        private static string literal(string text) {
            return "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"";
        }

        private static string number(double v) {
            var buf = new char[double.DTOSTR_BUF_SIZE];
            unowned string s = v.to_str(buf);
            return s.contains(".") || s.contains("e") || s.contains("n") ? s.dup() : s + ".0";
        }

        public static string save(PluginEffect e, string label, string dir) throws Error {
            if (!e.kind.has_prefix("lv2:")) throw new IOError.NOT_SUPPORTED(_("Only LV2 plugins have presets"));
            string uri = e.info.uri;
            string bundle = Path.build_filename(dir, slug(e.info.name + " " + label) + ".preset.lv2");
            DirUtils.create_with_parents(bundle, 0755);
            string file = slug(label) + ".ttl";
            const string PREFIXES = "@prefix lv2: <http://lv2plug.in/ns/lv2core#> .\n@prefix pset: <http://lv2plug.in/ns/ext/presets#> .\n@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .\n@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n\n";
            var b = new StringBuilder(PREFIXES);
            b.append("<%s>\n    a pset:Preset ;\n    lv2:appliesTo <%s> ;\n    rdfs:label %s".printf(file, uri, literal(label)));
            var ports = new Gee.ArrayList<string>();
            foreach (var p in e.info.parameters) ports.add("[\n        lv2:symbol %s ;\n        pset:value %s\n    ]".printf(literal(p.id), number(e.get_plugin_value(p.id))));
            if (ports.size > 0) b.append(" ;\n    lv2:port " + string.joinv(" , ", ports.to_array()));
            b.append(" .\n");
            FileUtils.set_contents(Path.build_filename(bundle, file), b.str);
            string manifest = PREFIXES + "<%s>\n    a pset:Preset ;\n    lv2:appliesTo <%s> ;\n    rdfs:seeAlso <%s> .\n".printf(file, uri, file);
            FileUtils.set_contents(Path.build_filename(bundle, "manifest.ttl"), manifest);
            return File.new_for_path(Path.build_filename(bundle, file)).get_uri();
        }
    }
}
