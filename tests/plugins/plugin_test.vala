using Singularity.Apps.Wave;

delegate bool Condition();

int failures = 0;

void check(bool ok, string what) {
    print("%s %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}

float[] make_signal(int frames, int channels, int seed) {
    var buf = new float[frames * channels];
    for (int i = 0; i < buf.length; i++) buf[i] = (float) (Math.sin(i * 0.013 + seed) * 0.5 + Math.sin(i * 0.0021) * 0.25);
    return buf;
}

bool scaled(float[] input, float[] output, float k) {
    for (int i = 0; i < input.length; i++) {
        float expected = input[i] * k;
        if (output[i] != expected) {
            printerr("  sample %d: %g != %g\n", i, output[i], expected);
            return false;
        }
    }
    return true;
}

bool run_for(Effect e, float k, int frames = 10000) {
    var input = make_signal(frames, 2, frames);
    var buf = input.copy();
    e.process(buf, frames);
    return scaled(input, buf, k);
}

bool wait_until(Condition cond, int ms) {
    int64 deadline = get_monotonic_time() + ms * 1000;
    while (!cond() && get_monotonic_time() < deadline) {
        MainContext.default().iteration(false);
        Thread.usleep(5000);
    }
    return cond();
}

PluginInfo? by_name(PluginCatalog cat, string name) {
    foreach (var p in cat.plugins) {
        if (p.name == name) return p;
    }
    return null;
}

string ids(PluginInfo info) {
    string[] list = {};
    foreach (var p in info.parameters) list += p.id;
    return string.joinv(",", list);
}

int main() {
    string home = Environment.get_home_dir();
    DirUtils.create_with_parents(Path.build_filename(home, ".lv2"), 0755);
    string old_bundle = Path.build_filename(home, ".lv2", "wave_test_gain_quiet_night.preset.lv2");
    FileUtils.remove(Path.build_filename(old_bundle, "manifest.ttl"));
    FileUtils.remove(Path.build_filename(old_bundle, "quiet_night.ttl"));
    DirUtils.remove(old_bundle);

    print("helper %s\n", WavePlug.helper_path());
    var cat = PluginCatalog.get_default();
    cat.rescan();
    foreach (var p in cat.plugins) print("found %s [%s] %s params=%s in=%d out=%d\n", p.name, p.format, p.kind, ids(p), p.audio_inputs, p.audio_outputs);
    foreach (var problem in cat.problems) print("problem %s\n", problem);
    check(cat.plugins.size == 4, "scan finds the four test plugins (%d)".printf(cat.plugins.size));
    bool scan_crash_seen = false;
    foreach (var problem in cat.problems) {
        if (problem.contains("wavetest_scancrash") && problem.contains("crashed")) scan_crash_seen = true;
    }
    check(scan_crash_seen, "a plugin crashing during the scan is reported and does not stop the scan");

    var lv2 = by_name(cat, "Wave Test Gain");
    var ladspa = by_name(cat, "Wave Test Gain (LADSPA)");
    var clap = by_name(cat, "Wave Test Gain (CLAP)");
    var crash = by_name(cat, "Wave Test Crash");
    check(lv2 != null && ladspa != null && clap != null && crash != null, "all test plugins are listed by name");
    if (lv2 == null || ladspa == null || clap == null || crash == null) return 1;

    check(lv2.format == "LV2" && lv2.kind == "lv2:urn:singularity:wave-test:gain" && lv2.vendor == "Singularity", "LV2 kind, format and vendor from Turtle");
    check(ids(lv2) == "gain,invert,mode" && lv2.audio_inputs == 1 && lv2.audio_outputs == 1, "LV2 control ports become parameters in index order");
    check(lv2.parameters[0].max == 4 && lv2.parameters[0].fallback == 1 && lv2.parameters[0].logarithmic, "LV2 range, default and logarithmic property");
    check(lv2.parameters[1].toggle, "LV2 toggled property");
    check(string.joinv(",", lv2.parameters[2].choices) == "Clean,Warm,Bright", "LV2 enumeration scale points sorted by value");
    check(lv2.has_native_ui, "LV2 external UI detected");
    check(ladspa.format == "LADSPA" && ladspa.kind.has_suffix("wavetest_ladspa.so#4242") && ladspa.audio_inputs == 2 && ladspa.audio_outputs == 2, "LADSPA kind and stereo ports");
    check(ids(ladspa) == "0" && ladspa.parameters[0].label == "Gain" && ladspa.parameters[0].fallback == 1 && ladspa.parameters[0].max == 4, "LADSPA control port hints");
    check(clap.format == "CLAP" && clap.kind.has_suffix("wavetest_gain.clap#dev.sinty.wave.test.gain") && clap.audio_inputs == 2, "CLAP kind and audio ports");
    check(ids(clap) == "7,9" && string.joinv(",", clap.parameters[1].choices) == "Clean,Warm,Bright", "CLAP parameters and enum labels");
    check(crash.parameters.size == 2 && crash.parameters[1].toggle, "crash plugin parameters");

    PluginInfo[] gains = { lv2, ladspa, clap };
    foreach (var info in gains) {
        foreach (bool isolated in new bool[] { false, true }) {
            string mode = isolated ? "isolated" : "in-process";
            var e = new PluginEffect(info, isolated);
            string gain_id = info.parameters[0].id;
            e.set_value(gain_id, 0.5);
            e.prepare(48000, 2);
            check(e.load_error == null, "%s %s loads".printf(info.format, mode));
            check(run_for(e, 0.5f), "%s %s applies exact gain 0.5 over 10000 stereo frames".printf(info.format, mode));
            e.set_value(gain_id, 2.0);
            check(run_for(e, 2.0f, 777), "%s %s follows a parameter change to 2.0".printf(info.format, mode));
            if (info.format == "LV2") {
                check(e.latency() == 3, "%s %s reports latency from the reportsLatency port (%d)".printf(info.format, mode, e.latency()));
                e.set_value("invert", 1);
                check(run_for(e, -2.0f, 300), "%s %s toggle parameter inverts".printf(info.format, mode));
            }
            if (isolated) check(e.host_pid() > 0 && e.host_pid() != Posix.getpid(), "%s runs in helper process %d".printf(info.format, e.host_pid()));
        }
    }

    var ce = new PluginEffect(crash, true);
    ce.set_value("0", 2.0);
    ce.prepare(48000, 2);
    check(run_for(ce, 2.0f, 1000), "crash plugin works before the crash (dual mono)");
    bool crashed = false;
    string message = "";
    ce.crashed.connect((m) => {
        crashed = true;
        message = m;
    });
    int first_pid = ce.host_pid();
    ce.set_value("1", 1);
    var input = make_signal(1000, 2, 7);
    var buf = input.copy();
    ce.process(buf, 1000);
    check(scaled(input, buf, 1.0f), "audio passes through unchanged for the block where the plugin crashed");
    bool fired = wait_until(() => crashed, 3000);
    check(fired, "crashed signal fires: %s".printf(message));
    check(true, "the test process survived the plugin crash");
    ce.set_value("1", 0);
    check(run_for(ce, 2.0f, 1000), "next block works after automatic restart");
    check(ce.host_pid() > 0 && ce.host_pid() != first_pid, "the helper was restarted (%d then %d)".printf(first_pid, ce.host_pid()));

    var pe = new PluginEffect(lv2, false);
    pe.prepare(48000, 2);
    pe.set_value("gain", 0.75);
    pe.set_value("invert", 1);
    pe.set_value("mode", 2);
    string preset_uri = "";
    try {
        preset_uri = Lv2Presets.save(pe, "Quiet Night", Path.build_filename(home, ".lv2"));
    } catch (Error e) {
        print("save failed: %s\n", e.message);
    }
    check(preset_uri.has_suffix("quiet_night.ttl"), "LV2 preset saved as %s".printf(preset_uri));
    check(Lv2Presets.list(lv2.uri).contains("Quiet Night"), "saved preset is listed");
    pe.set_value("gain", 1);
    pe.set_value("invert", 0);
    pe.set_value("mode", 0);
    check(Lv2Presets.load(pe, "Quiet Night"), "preset loads by label");
    check(pe.get_value("gain") == 0.75 && pe.get_value("invert") == 1 && pe.get_value("mode") == 2, "preset restores gain, toggle and enumeration");
    check(run_for(pe, -0.75f, 500), "restored preset is applied to the audio");
    pe.set_value("gain", 1);
    check(Lv2Presets.load(pe, preset_uri) && pe.get_value("gain") == 0.75, "preset loads by URI");

    var se = new PluginEffect(clap, true);
    se.prepare(48000, 2);
    se.set_value("7", 1.5);
    se.set_value("9", 1);
    run_for(se, 1.5f, 64);
    var state = se.save_state();
    check(state != null && ((string) state).has_prefix("wave-test-gain"), "CLAP state saved through the isolated host");
    se.set_value("7", 1.0);
    se.set_value("9", 0);
    run_for(se, 1.0f, 64);
    check(state != null && se.load_state(state), "CLAP state loads");
    check(se.get_value("7") == 1.5 && se.get_value("9") == 1, "CLAP state restores parameter values");
    check(run_for(se, 1.5f, 256), "CLAP restored state is applied to the audio");
    var json = se.to_json();
    check(json.has_member("state") && json.get_string_member("kind") == clap.kind, "effect JSON keeps kind and plugin state");
    var se2 = new PluginEffect(clap, false);
    se2.load_json(json);
    se2.prepare(44100, 2);
    check(run_for(se2, 1.5f, 256), "effect JSON round trip restores the plugin");

    foreach (bool isolated in new bool[] { true, false }) {
        string mode = isolated ? "isolated" : "in-process";
        var ue = new PluginEffect(lv2, isolated);
        ue.prepare(48000, 2);
        check(ue.has_native_ui && ue.show_native_ui(true), "%s external UI shown".printf(mode));
        bool written = wait_until(() => ue.get_value("gain") == 0.25, 3000);
        check(written, "%s external UI writes a parameter back (gain %g)".printf(mode, ue.get_value("gain")));
        check(run_for(ue, 0.25f, 400), "%s value written by the UI reaches the audio".printf(mode));
        check(ue.show_native_ui(false), "%s external UI hidden".printf(mode));
    }

    print("%s: %d failures\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
