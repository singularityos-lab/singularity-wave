namespace Singularity.Apps.Wave {

    public class PluginCatalog : Object {
        private static PluginCatalog? instance = null;

        public Gee.List<PluginInfo> plugins { get; default = new Gee.ArrayList<PluginInfo>(); }
        public Gee.List<string> problems { get; default = new Gee.ArrayList<string>(); }
        public bool scanned { get; private set; default = false; }

        public signal void changed();

        public static PluginCatalog get_default() {
            if (instance == null) instance = new PluginCatalog();
            return instance;
        }

        public void rescan() {
            var found = new Gee.ArrayList<PluginInfo>();
            var issues = new Gee.ArrayList<string>();
            var parser = new Json.Parser();
            try {
                parser.load_from_data(WavePlug.candidates());
            } catch (Error e) {
                warning("Plugins: %s", e.message);
                return;
            }
            var root = parser.get_root();
            if (root != null && root.get_node_type() == Json.NodeType.ARRAY) {
                foreach (var node in root.get_array().get_elements()) {
                    var c = node.get_object();
                    string format = c.get_string_member("format");
                    string path = c.get_string_member("path");
                    string? error;
                    string? json = WavePlug.scan_isolated(format, path, 10000, out error);
                    if (json == null) {
                        issues.add(error ?? path);
                        continue;
                    }
                    var p = new Json.Parser();
                    try {
                        p.load_from_data(json);
                    } catch (Error e) {
                        issues.add("%s: %s".printf(path, e.message));
                        continue;
                    }
                    var list = p.get_root();
                    if (list == null || list.get_node_type() != Json.NodeType.ARRAY) continue;
                    foreach (var item in list.get_array().get_elements()) found.add(PluginInfo.from_json(item.get_object()));
                }
            }
            found.sort((a, b) => a.name.collate(b.name));
            plugins.clear();
            plugins.add_all(found);
            problems.clear();
            problems.add_all(issues);
            scanned = true;
            changed();
        }

        public PluginInfo? find(string kind) {
            if (!scanned) rescan();
            foreach (var info in plugins) {
                if (info.kind == kind) return info;
            }
            return null;
        }

        public Gee.List<PluginInfo> by_format(string format) {
            if (!scanned) rescan();
            var list = new Gee.ArrayList<PluginInfo>();
            foreach (var info in plugins) {
                if (info.format == format) list.add(info);
            }
            return list;
        }
    }
}
