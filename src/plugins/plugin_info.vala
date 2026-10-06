namespace Singularity.Apps.Wave {

    public class PluginParamInfo : Object {
        public string id { get; set; default = ""; }
        public string label { get; set; default = ""; }
        public double min { get; set; default = 0; }
        public double max { get; set; default = 1; }
        public double fallback { get; set; default = 0; }
        public bool toggle { get; set; default = false; }
        public bool logarithmic { get; set; default = false; }
        public bool integer { get; set; default = false; }
        public string[] choices { get; set; default = {}; }
        public double[] choice_values = {};

        public static PluginParamInfo from_json(Json.Object o) {
            var p = new PluginParamInfo();
            p.id = o.get_string_member_with_default("id", "");
            p.label = o.get_string_member_with_default("label", p.id);
            p.min = o.get_double_member_with_default("min", 0);
            p.max = o.get_double_member_with_default("max", 1);
            p.fallback = o.get_double_member_with_default("default", p.min);
            p.toggle = o.get_boolean_member_with_default("toggle", false);
            p.logarithmic = o.get_boolean_member_with_default("log", false);
            p.integer = o.get_boolean_member_with_default("integer", false);
            string[] labels = {};
            double[] values = {};
            if (o.has_member("choices")) {
                foreach (var node in o.get_array_member("choices").get_elements()) labels += node.get_string();
            }
            if (o.has_member("values")) {
                foreach (var node in o.get_array_member("values").get_elements()) values += node.get_double();
            }
            if (labels.length == values.length) {
                p.choices = labels;
                p.choice_values = values;
            }
            return p;
        }
    }

    public class PluginInfo : Object {
        public string kind { get; set; default = ""; }
        public string name { get; set; default = ""; }
        public string format { get; set; default = ""; }
        public string vendor { get; set; default = ""; }
        public string path { get; set; default = ""; }
        public int audio_inputs { get; set; default = 0; }
        public int audio_outputs { get; set; default = 0; }
        public bool has_native_ui { get; set; default = false; }
        public string unsupported { get; set; default = ""; }
        public Gee.List<PluginParamInfo> parameters { get; default = new Gee.ArrayList<PluginParamInfo>(); }

        public string uri {
            owned get {
                return kind.has_prefix("lv2:") ? kind.substring(4) : kind;
            }
        }

        public static PluginInfo from_json(Json.Object o) {
            var info = new PluginInfo();
            info.kind = o.get_string_member_with_default("kind", "");
            info.name = o.get_string_member_with_default("name", info.kind);
            info.format = o.get_string_member_with_default("format", "");
            info.vendor = o.get_string_member_with_default("vendor", "");
            info.path = o.get_string_member_with_default("path", "");
            info.audio_inputs = (int) o.get_int_member_with_default("audio_inputs", 0);
            info.audio_outputs = (int) o.get_int_member_with_default("audio_outputs", 0);
            info.has_native_ui = o.get_boolean_member_with_default("native_ui", false);
            info.unsupported = o.get_string_member_with_default("unsupported", "");
            if (o.has_member("params")) {
                foreach (var node in o.get_array_member("params").get_elements()) info.parameters.add(PluginParamInfo.from_json(node.get_object()));
            }
            return info;
        }
    }
}
