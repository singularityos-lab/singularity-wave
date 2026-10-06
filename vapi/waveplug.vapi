[CCode (cheader_filename = "waveplug.h", lower_case_cprefix = "wp_")]
namespace WavePlug {
    [Compact]
    [CCode (cname = "WpInstance", free_function = "wp_instance_free", lower_case_cprefix = "wp_instance_")]
    public class Instance {
        [CCode (cname = "wp_instance_open")]
        public static Instance? open(string kind, string path, int rate, int channels, int max_block, bool isolated, out string? error);
        public int process([CCode (array_length = false)] float[] buf, int frames);
        public int param_count();
        public void set_param(int index, double value);
        public double get_param(int index);
        public int sync_params([CCode (array_length = false)] double[] values, int n);
        public int latency();
        public bool alive();
        public bool is_isolated();
        public int restart(out string? error);
        public string? take_crash();
        public int save_state([CCode (array_length_type = "size_t")] out uint8[] data);
        public int load_state([CCode (array_length_type = "size_t")] uint8[] data);
        public bool has_native_ui();
        public int show_native_ui(bool show, out string? error);
        public bool native_ui_visible();
        public void idle();
        public int pid();
    }

    public string candidates();
    public string? scan_isolated(string format, string path, int timeout_ms, out string? error);
    public string lv2_presets_json(string uri);
    public unowned string helper_path();
}
