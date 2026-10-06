using Singularity.Apps.Wave;

int failures = 0;

void check(bool ok, string what) {
    if (ok) {
        print("ok %s\n", what);
    } else {
        print("FAIL %s\n", what);
        failures++;
    }
}

string scratch;

string tmp(string name) {
    return Path.build_filename(scratch, name);
}

float[] sine(int rate, int channels, double seconds, double freq, double amp) {
    int64 n = (int64) (seconds * rate);
    var b = new float[n * channels];
    for (int64 f = 0; f < n; f++) {
        float v = (float) (amp * Math.sin(2 * Math.PI * freq * f / rate));
        for (int c = 0; c < channels; c++) b[f * channels + c] = v;
    }
    return b;
}

Document make_doc(int rate, int channels, double seconds, double freq) throws Error {
    var src = PcmSource.from_samples(sine(rate, channels, seconds, freq, 0.5), rate, channels);
    return Document.from_source(src, "test");
}

void test_document() throws Error {
    var doc = make_doc(48000, 2, 2.0, 440);
    check(doc.length == 96000, "document length");
    var buf = doc.read(1000, 10);
    check(Math.fabsf(buf[0] - (float) (0.5 * Math.sin(2 * Math.PI * 440 * 1000 / 48000.0))) < 1e-6, "sample accurate read");
    var clip = doc.copy_range(0, 48000);
    doc.delete_range(0, 24000);
    check(doc.length == 72000, "delete shortens");
    doc.insert(72000, clip);
    check(doc.length == 120000, "paste appends");
    doc.silence(0, 4800);
    var s = doc.read(0, 4800);
    check(WaveDsp.peak(s, s.length) == 0, "silence writes zeros");
    doc.undo();
    check(WaveDsp.peak(doc.read(0, 4800), 9600) > 0.1, "undo restores audio");
    doc.redo();
    check(WaveDsp.peak(doc.read(0, 4800), 9600) == 0, "redo reapplies silence");
    int steps = doc.history.size;
    for (int i = 0; i < 300; i++) Processes.amplify(doc, 0, 100, 0.01);
    check(doc.history.size == steps + 300, "unlimited history keeps every step");
    for (int i = 0; i < 300; i++) doc.undo();
    check(doc.history_index == steps - 1, "undo walks all the way back");
    doc.add_marker(new Marker("Intro", 60000));
    doc.add_marker(new Marker("Range", 70000, 4800));
    doc.delete_range(0, 12000);
    check(doc.markers[0].start == 48000, "markers shift after delete");
    int64 z = doc.snap_zero(1003);
    var around = doc.read(z - 1, 2);
    check(Math.fabsf(around[2]) < 0.02 || (around[0] <= 0) != (around[2] <= 0), "snap to zero crossing");
    Processes.fade(doc, 0, 4800, true, 2);
    check(Math.fabsf(doc.read(0, 1)[0]) < 1e-4, "fade in starts silent");
    var d2 = make_doc(48000, 1, 1.0, 100);
    Processes.reverse(d2, 0, d2.length);
    check(Math.fabsf(d2.read(0, 1)[0] - (float) (0.5 * Math.sin(2 * Math.PI * 100 * 47999 / 48000.0))) < 1e-6, "reverse");
    Processes.invert(d2, 0, d2.length);
    Processes.normalize_peak(d2, 0, d2.length, -1, false);
    var all = d2.read(0, d2.length);
    check(Math.fabs(20 * Math.log10(WaveDsp.peak(all, all.length)) + 1) < 0.01, "normalize to -1 dBFS");
    var lo = new float[100];
    var hi = new float[100];
    d2.peaks(0, 480, 100, 0, lo, hi);
    check(hi[50] > 0.8 && lo[50] < -0.8, "multilevel peaks");
    var lo2 = new float[100];
    var hi2 = new float[100];
    d2.peaks(1000, 0.5, 100, 0, lo2, hi2);
    check(lo2[0] == hi2[0], "zoom to the single sample");
}

void test_formats() throws Error {
    var doc = make_doc(44100, 2, 3.0, 1000);
    doc.metadata.title = "Episode One";
    doc.metadata.artist = "Wave Test";
    doc.metadata.description = "Broadcast description";
    doc.metadata.originator = "Wave";
    doc.markers.add(new Marker("Chapter A", 0, 0, "chapter"));
    doc.markers.add(new Marker("Chapter B", 44100, 0, "chapter"));
    doc.markers.add(new Marker("Chapter C", 88200, 22050, "chapter"));
    foreach (var fmt in ExportFormat.all()) {
        if (!fmt.available()) {
            print("skip %s (encoder missing)\n", fmt.label());
            continue;
        }
        var o = new ExportOptions();
        o.format = fmt;
        o.bits = fmt == ExportFormat.FLAC ? 16 : 24;
        o.metadata = doc.metadata;
        o.markers = doc.markers;
        o.bitrate = 128;
        string path = tmp("roundtrip." + fmt.extension() + (fmt == ExportFormat.BWF ? ".bwf.wav" : ""));
        Exporter.export_sync(doc, path, o);
        var media = Decoder.decode_sync(path);
        int64 expect = fmt == ExportFormat.OPUS ? 3 * 48000 : 3 * 44100;
        bool len_ok = (media.source.frames - expect).abs() < (fmt.lossless() ? 1 : 4000);
        check(len_ok, "%s length %lld".printf(fmt.label(), media.source.frames));
        var a = new float[media.source.frames * media.source.channels];
        media.source.read(0, media.source.frames, a);
        float peak = WaveDsp.peak(a, a.length);
        check(Math.fabsf(peak - 0.5f) < (fmt.lossless() ? 0.001f : 0.08f), "%s level %.4f".printf(fmt.label(), peak));
        if (fmt != ExportFormat.CAF && fmt != ExportFormat.AIFF) check(media.metadata.title == "Episode One", "%s title tag '%s'".printf(fmt.label(), media.metadata.title));
        if (fmt == ExportFormat.WAV || fmt == ExportFormat.BWF || fmt == ExportFormat.AIFF || fmt == ExportFormat.CAF || fmt == ExportFormat.FLAC || fmt == ExportFormat.OGG || fmt == ExportFormat.OPUS || fmt == ExportFormat.MP3) {
            check(media.markers.size == 3 && media.markers[1].name == "Chapter B", "%s chapters %d".printf(fmt.label(), media.markers.size));
        }
        if (fmt == ExportFormat.BWF) check(media.metadata.description == "Broadcast description" && media.metadata.originator == "Wave", "BWF bext metadata");
        if (fmt == ExportFormat.WAV) check(media.markers.size == 3 && media.markers[2].length == 22050, "WAV range marker length");
    }
    var fl = new ExportOptions();
    fl.format = ExportFormat.WAV;
    fl.is_float = true;
    Exporter.export_sync(doc, tmp("float.wav"), fl);
    var fm = Decoder.decode_sync(tmp("float.wav"));
    var fa = new float[20];
    fm.source.read(1000, 10, fa);
    check(Math.fabsf(fa[0] - doc.read(1000, 1)[0]) < 1e-7, "32 bit float WAV is bit exact");
    var conv = new ExportOptions();
    conv.format = ExportFormat.WAV;
    conv.rate = 48000;
    conv.channels = 1;
    conv.cue_sheet = true;
    conv.chapters_json = true;
    conv.markers = doc.markers;
    Exporter.export_sync(doc, tmp("converted.wav"), conv);
    var cm = Decoder.decode_sync(tmp("converted.wav"));
    check(cm.source.rate == 48000 && cm.source.channels == 1 && (cm.source.frames - 144000).abs() < 64, "rate and channel conversion on export");
    string? audio;
    var cue = Interchange.read_cue(tmp("converted.cue"), 48000, out audio);
    check(cue.size == 3 && cue[1].name == "Chapter B" && (cue[1].start - 48000).abs() < 700, "CUE sheet chapters");
    var cj = Interchange.read_chapters_json(tmp("converted.wav.chapters.json"), 48000);
    check(cj.size == 3 && cj[2].length == 24000, "podcast chapters JSON");
}

void test_loudness() throws Error {
    var b = sine(48000, 2, 10, 1000, Math.pow(10, -20 / 20.0));
    var r = Loudness.measure(b, b.length / 2, 2, 48000);
    check(Math.fabs(r.integrated + 20) < 0.2, "integrated loudness %.2f".printf(r.integrated));
    Loudness.normalize(b, b.length / 2, 2, 48000, -16, -1);
    var r2 = Loudness.measure(b, b.length / 2, 2, 48000);
    check(Math.fabs(r2.integrated + 16) < 0.3, "normalized to -16 LUFS: %.2f".printf(r2.integrated));
    check(r2.true_peak <= -0.9, "true peak under ceiling: %.2f".printf(r2.true_peak));
    var loud = sine(48000, 2, 10, 1000, 0.9);
    Loudness.normalize(loud, loud.length / 2, 2, 48000, -9, -1);
    var r3 = Loudness.measure(loud, loud.length / 2, 2, 48000);
    check(r3.true_peak <= -0.9, "limiter holds the ceiling when the target is hot: %.2f".printf(r3.true_peak));
}

void test_effects() throws Error {
    foreach (var k in EffectRegistry.builtin()) {
        var e = EffectRegistry.create(k.kind);
        check(e != null && e.title != "", "create %s".printf(k.kind));
        e.prepare(48000, 2);
        var b = sine(48000, 2, 0.2, 440, 0.3);
        if (e.offline_only()) e.run(b, b.length / 2);
        else e.run(b, b.length / 2);
        bool finite = true;
        foreach (float v in b) {
            if (!v.is_finite()) finite = false;
        }
        check(finite, "%s output is finite".printf(k.kind));
        var json = e.to_json();
        var copy = EffectRegistry.from_json(json);
        check(copy != null && copy.parameters.size == e.parameters.size, "%s round trips as JSON".printf(k.kind));
    }
    var eq = (EqEffect) EffectRegistry.create("eq");
    eq.prepare(48000, 1);
    eq.set_value("b3_on", 1);
    eq.set_value("b3_freq", 1000);
    eq.set_value("b3_gain", 6);
    var resp = eq.response({ 1000f });
    check(Math.fabs(resp[0] - 6) < 0.2, "parametric EQ response %.2f".printf(resp[0]));
    var comp = (DynamicsEffect) EffectRegistry.create("compressor");
    comp.prepare(48000, 2);
    comp.set_value("threshold", -30);
    comp.set_value("ratio", 4);
    var loud = sine(48000, 2, 0.5, 440, 0.9);
    comp.run(loud, loud.length / 2);
    check(comp.last_reduction > 6, "compressor reports gain reduction %.1f".printf(comp.last_reduction));
    var rack = new EffectRack(48000, 2);
    rack.add(EffectRegistry.create("utility"));
    rack.effects[0].set_value("gain", -6);
    var b2 = sine(48000, 2, 0.1, 440, 0.5);
    rack.process(b2, b2.length / 2);
    check(Math.fabsf(WaveDsp.peak(b2, b2.length) - 0.25f) < 0.01, "rack applies gain");
    rack.effects[0].bypass = true;
    var b3 = sine(48000, 2, 0.1, 440, 0.5);
    rack.process(b3, b3.length / 2);
    check(Math.fabsf(WaveDsp.peak(b3, b3.length) - 0.5f) < 0.001, "bypass passes audio");
    Presets.save("utility", "Half", rack.effects[0].to_json());
    check(Presets.list("utility").contains("Half") && Presets.load("utility", "Half") != null, "effect presets saved and listed");
}

void test_restoration() throws Error {
    int rate = 48000;
    int64 n = rate * 3;
    var noisy = new float[n];
    uint32 seed = 7;
    for (int64 i = 0; i < n; i++) {
        seed = seed * 1664525 + 1013904223;
        float noise = (float) ((seed >> 8) / 8388608.0 - 1.0) * 0.02f;
        noisy[i] = noise + (i > rate ? (float) (0.4 * Math.sin(2 * Math.PI * 440 * i / rate)) : 0);
    }
    var doc = Document.from_source(PcmSource.from_samples(noisy, rate, 1), "noisy");
    Processes.capture_noise(doc, 0, rate);
    check(doc.noise.ready, "noise print captured");
    Processes.reduce_noise(doc, 0, doc.length, 24, 6, 0.5);
    var head = doc.read(rate / 4, rate / 2);
    check(WaveDsp.rms(head, head.length) < 0.02 / Math.sqrt(3) / 5, "noise floor lowered");
    var tone = doc.read(rate * 2, rate / 2);
    check(Math.fabs(WaveDsp.rms(tone, tone.length) - 0.4 / Math.sqrt(2)) < 0.03, "tone kept after noise reduction");
}

Session make_session() throws Error {
    var s = new Session(48000, 2);
    var t1 = s.add_track("Voice", TrackKind.AUDIO, 1);
    var t2 = s.add_track("Music", TrackKind.AUDIO, 2);
    var a = PcmSource.from_samples(sine(48000, 1, 2, 440, 0.5), 48000, 1);
    var b = PcmSource.from_samples(sine(48000, 1, 2, 660, 0.5), 48000, 1);
    s.add_clip(t1, a, "", 0);
    s.add_clip(t1, b, "", 72000);
    var m = PcmSource.from_samples(sine(48000, 2, 4, 220, 0.25), 48000, 2);
    s.add_clip(t2, m, "", 0);
    return s;
}

void test_session() throws Error {
    var s = make_session();
    var t1 = s.tracks[0];
    var t2 = s.tracks[1];
    check(s.length == 72000 + 96000 || s.length == 192000, "session length %lld".printf(s.length));
    t2.mute = true;
    var mix = new float[4800 * 2];
    s.render(0, 4800, mix);
    double l = WaveDsp.rms(mix, mix.length);
    check(Math.fabs(l - 0.5 * Math.cos(Math.PI / 4) / Math.sqrt(2)) < 0.01, "mono track panned centre at -3 dB: %.4f".printf(l));
    t1.pan = -1;
    s.render(0, 4800, mix);
    float right = 0;
    for (int i = 0; i < 4800; i++) right = float.max(right, Math.fabsf(mix[i * 2 + 1]));
    check(right < 1e-6, "hard left pan silences the right side");
    t1.pan = 0;
    var xf = new float[2 * 2];
    s.render(84000, 1, xf);
    var only_a = new float[1];
    t1.clips[0].source.read(84000, 1, only_a);
    check(Math.fabsf(xf[0]) < Math.fabsf(only_a[0] * 0.7071f) + 0.5f, "crossfade region renders");
    double mid_a = Math.cos(Math.PI / 4), mid_b = Math.sin(Math.PI / 4);
    check(Math.fabs(mid_a - mid_b) < 1e-9, "equal power crossfade law");
    t1.solo = true;
    t2.mute = false;
    s.render(0, 4800, mix);
    check(Math.fabs(WaveDsp.rms(mix, mix.length) - l) < 0.01, "solo excludes the other track");
    t1.solo = false;
    t1.mute = true;
    t2.mute = true;
    var bus = s.add_track("Reverb", TrackKind.BUS, 2);
    t1.sends.add(new Send(bus.id));
    t1.mute = false;
    t1.volume_db = -60;
    t1.sends[0].pre_fader = true;
    t1.sends[0].level_db = 0;
    s.render(0, 4800, mix);
    check(WaveDsp.rms(mix, mix.length) > 0.1, "pre fader send reaches the bus with the fader down");
    t1.sends[0].pre_fader = false;
    s.mixer.reset();
    s.render(0, 4800, mix);
    check(WaveDsp.rms(mix, mix.length) < 0.01, "post fader send follows the fader");
    t1.sends.clear();
    t1.volume_db = 0;
    var lane = t1.lane("volume");
    lane.add(0, 0);
    lane.add(48000, -60);
    s.render(47000, 100, mix);
    check(WaveDsp.rms(mix, 200) < 0.01, "volume automation is read");
    lane.points.clear();
    s.master.rack.add(EffectRegistry.create("utility"));
    s.master.rack.effects[0].set_value("gain", -6);
    s.render(0, 4800, mix);
    check(Math.fabs(WaveDsp.rms(mix, mix.length) - l / 2) < 0.01, "master rack processes the mix");
    s.master.rack.clear();
    var rec = new AutomationRecorder();
    s.mixer.recorder = rec;
    t1.automation = AutomationMode.TOUCH;
    rec.touch(t1, "volume", -12);
    s.render(96000, 1024, mix);
    rec.release(t1, "volume");
    check(t1.find_lane("volume") != null && t1.find_lane("volume").points.size > 0 && Math.fabs(t1.find_lane("volume").points[0].value + 12) < 0.01, "touch automation writes points");
    s.mixer.recorder = null;
    t1.lanes.clear();
    t1.automation = AutomationMode.READ;
    var c = t1.clips[0];
    c.stretch = 1.5;
    c.length = (int64) (96000 * 1.5);
    c.prepare_render();
    check(c.rendered != null && (c.rendered.frames - 144000).abs() < 64, "clip time stretch renders %lld".printf(c.rendered != null ? c.rendered.frames : 0));
    var mono = new float[4096];
    c.rendered.read(20000, 4096, mono, 0, 1);
    float hz = WaveDsp.detect_pitch(mono, 4096, 48000);
    check(Math.fabs(hz - 440) < 5, "stretch keeps the pitch: %.1f Hz".printf(hz));
    c.stretch = 1;
    c.length = 96000;
    c.pitch = 12;
    c.prepare_render();
    c.rendered.read(20000, 4096, mono, 0, 1);
    hz = WaveDsp.detect_pitch(mono, 4096, 48000);
    check(Math.fabs(hz - 880) < 12, "clip pitch shift: %.1f Hz".printf(hz));
    c.pitch = 0;
    c.prepare_render();
    s.checkpoint("edit");
    t1.name = "Changed";
    s.checkpoint("rename");
    s.undo();
    check(s.tracks[0].name == "Voice", "session undo");
    s.redo();
    check(s.tracks[0].name == "Changed", "session redo");
}

void test_surround() throws Error {
    var s = new Session(48000, 6);
    var t = s.add_track("Dialog", TrackKind.AUDIO, 1);
    s.add_clip(t, PcmSource.from_samples(sine(48000, 1, 1, 440, 0.5), 48000, 1), "", 0);
    t.azimuth = 0;
    var mix = new float[4800 * 6];
    s.render(0, 4800, mix);
    float[] ch = new float[6];
    for (int i = 0; i < 4800; i++) {
        for (int c = 0; c < 6; c++) ch[c] = float.max(ch[c], Math.fabsf(mix[i * 6 + c]));
    }
    check(ch[2] > 0.45 && ch[0] < 0.01 && ch[1] < 0.01, "centre azimuth feeds the centre speaker");
    t.azimuth = 110;
    s.render(0, 4800, mix);
    for (int c = 0; c < 6; c++) ch[c] = 0;
    for (int i = 0; i < 4800; i++) {
        for (int c = 0; c < 6; c++) ch[c] = float.max(ch[c], Math.fabsf(mix[i * 6 + c]));
    }
    check(ch[5] > 0.45 && ch[2] < 0.01, "right surround azimuth");
    t.lfe = 0.5;
    s.render(0, 4800, mix);
    float lfe = 0;
    for (int i = 0; i < 4800; i++) lfe = float.max(lfe, Math.fabsf(mix[i * 6 + 3]));
    check(lfe > 0.2, "LFE send");
    var o = new ExportOptions();
    o.format = ExportFormat.WAV;
    o.bits = 24;
    Exporter.export_sync(s, tmp("surround.wav"), o);
    var m = Decoder.decode_sync(tmp("surround.wav"));
    check(m.source.channels == 6, "5.1 export has six channels");
    var r = Loudness.measure_renderable(s);
    check(r.integrated.is_finite(), "5.1 loudness measured %.1f".printf(r.integrated));
}

void test_session_io() throws Error {
    var s = make_session();
    s.tracks[0].rack.add(EffectRegistry.create("compressor"));
    s.tracks[0].lane("volume").add(1000, -3);
    s.markers.add(new Marker("Hello", 4800));
    string path = tmp("io.wave");
    SessionFile.save(s, path);
    check(FileUtils.test(SessionFile.media_dir(path), FileTest.IS_DIR), "recorded media written next to the session");
    var back = SessionFile.load(path);
    check(back.tracks.size == 2 && back.tracks[0].clips.size == 2, "session reloads tracks and clips");
    check(back.tracks[0].rack.effects.size == 1 && back.tracks[0].rack.effects[0].kind == "compressor", "session keeps effect racks");
    check(back.tracks[0].find_lane("volume") != null && back.tracks[0].find_lane("volume").points.size == 1, "session keeps automation");
    check(back.markers.size == 1 && back.markers[0].name == "Hello", "session keeps markers");
    var a = new float[9600];
    var b2 = new float[9600];
    s.render(1000, 4800, a);
    back.render(1000, 4800, b2);
    float diff = 0;
    for (int i = 0; i < 9600; i++) diff = float.max(diff, Math.fabsf(a[i] - b2[i]));
    check(diff < 1e-5, "reloaded session renders the same audio");
    uint8[] raw;
    FileUtils.get_data(path, out raw);
    var zip = new ZipReader(raw);
    check(zip.has("session.json") && zip.has("mimetype"), "session is an open zip with JSON");
    string otio = Interchange.export_otio(back);
    FileUtils.set_contents(tmp("io.otio"), otio);
    var fromotio = Interchange.import_otio(tmp("io.otio"), 48000);
    check(fromotio.tracks.size == 2 && fromotio.tracks[0].clips.size == 2 && fromotio.tracks[0].clips[1].position == 96000 && fromotio.tracks[1].clips[0].length == 192000, "OpenTimelineIO round trip (overlaps become cuts)");
    var mo = new ExportOptions();
    mo.format = ExportFormat.WAV;
    mo.bits = 16;
    Exporter.export_sync(back, tmp("music.wav"), mo);
    string sesx = """<?xml version="1.0" encoding="UTF-8"?>
<sesx version="1.9"><session appBuild="1" sampleRate="48000" duration="96000"><tracks>
<audioTrack id="10001" index="1"><trackParameters><name>Interview</name></trackParameters>
<trackAudioParameters audioChannelType="stereo"><parameter index="1" name="volume" parameterValue="0.5"/></trackAudioParameters>
<audioClip id="1" name="Take" fileID="0" startPoint="4800" endPoint="52800" sourceInPoint="0" sourceOutPoint="48000"><fadeIn startPoint="0" endPoint="2400" shape="0"/></audioClip>
</audioTrack></tracks></session><files><file id="0" relativePath="music.wav" absolutePath="/nowhere/music.wav"/></files></sesx>""";
    FileUtils.set_contents(tmp("import.sesx"), sesx);
    var fromsesx = Interchange.import_sesx(tmp("import.sesx"));
    check(fromsesx.tracks.size == 1 && fromsesx.tracks[0].name == "Interview" && fromsesx.tracks[0].clips[0].position == 4800 && fromsesx.tracks[0].clips[0].fade_in == 2400, "Audition SESX import");
    check(Math.fabs(fromsesx.tracks[0].volume_db + 6.02) < 0.05, "SESX track volume");
}

void test_workflows() throws Error {
    var s = Templates.podcast(48000, -16);
    check(s.tracks.size >= 4 && s.tracks[0].role == "dialogue" && s.tracks[2].duck, "podcast template tracks");
    int rate = 48000;
    int64 n = rate * 8;
    var speech = new float[n];
    uint32 seed = 3;
    for (int64 i = 0; i < n; i++) {
        bool talking = (i / rate) % 4 < 2;
        double env = 0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * i / rate);
        seed = seed * 1664525 + 1013904223;
        double noise = ((seed >> 8) / 8388608.0 - 1.0);
        speech[i] = talking ? (float) (env * (0.3 * Math.sin(2 * Math.PI * 180 * i / rate) + 0.15 * Math.sin(2 * Math.PI * 360 * i / rate) + 0.05 * noise)) : 0;
    }
    s.add_clip(s.tracks[0], PcmSource.from_samples(speech, rate, 1), "", 0);
    s.add_clip(s.tracks[2], PcmSource.from_samples(sine(rate, 2, 8, 330, 0.2), rate, 2), "", 0);
    int ducks = Ducking.apply(s, s.tracks[2], -15, 200, 400);
    var lane = s.tracks[2].find_lane("volume");
    check(ducks >= 2 && lane != null && lane.value_at(rate / 2 * 2) < s.tracks[2].volume_db - 10, "auto ducking lowers music under speech (%d spans)".printf(ducks));
    check(lane.value_at((int64) (rate * 3)) > s.tracks[2].volume_db - 1, "music comes back between sentences");
    var scores = EssentialSound.classify_source(s.tracks[0].clips[0].source, 0, n);
    check(EssentialSound.best(scores) == SoundRole.DIALOGUE, "essential sound classifies speech (%.2f %.2f %.2f %.2f)".printf(scores[0], scores[1], scores[2], scores[3]));
    var rack = new EffectRack(rate, 1);
    EssentialSound.set_noise(rack, 0.5);
    EssentialSound.set_clarity(rack, 0.5);
    EssentialSound.set_rumble(rack, 0.5);
    check(rack.effects.size == 3, "essential sound controls build the chain");
    DirUtils.create_with_parents(tmp("batch/in"), 0755);
    for (int i = 0; i < 3; i++) {
        var d = Document.from_source(PcmSource.from_samples(sine(rate, 2, 2, 300 + i * 100, 0.05 + 0.2 * i), rate, 2), "b");
        var o = new ExportOptions();
        o.format = ExportFormat.WAV;
        o.bits = 16;
        Exporter.export_sync(d, tmp("batch/in/file%d.wav".printf(i)), o);
    }
    var job = new BatchJob();
    job.files.add_all(BatchJob.collect(tmp("batch/in"), false));
    var chain = new EffectRack(rate, 2);
    chain.add(EffectRegistry.create("eq"));
    job.rack = chain.to_json();
    job.normalize = true;
    job.target_lufs = -18;
    job.output_dir = tmp("batch/out");
    job.options.format = ExportFormat.FLAC;
    job.options.bits = 16;
    int done = job.run_sync();
    check(done == 3, "batch processed every file");
    bool all_ok = true;
    foreach (var f in BatchJob.collect(tmp("batch/out"), false)) {
        var m = Decoder.decode_sync(f);
        var r = Loudness.measure_renderable(Document.from_source(m.source, f));
        if (Math.fabs(r.integrated + 18) > 0.5) all_ok = false;
    }
    check(all_ok, "batch output matches the loudness target");
    var entries = LoudnessMatch.analyze(BatchJob.collect(tmp("batch/in"), false));
    LoudnessMatch.apply(entries, -20, -1, tmp("batch/match"), ExportFormat.WAV);
    bool matched = entries.size == 3;
    foreach (var e in entries) {
        if (e.after == null || Math.fabs(e.after.integrated + 20) > 0.5) matched = false;
    }
    check(matched, "match loudness aligns several files");
}

void test_transcript() throws Error {
    int rate = 16000;
    int64 n = rate * 6;
    var b = new float[n];
    for (int64 i = 0; i < n; i++) {
        bool on = (i > rate / 2 && i < rate * 2) || (i > rate * 3 && i < rate * 5);
        b[i] = on ? (float) ((0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * i / rate)) * 0.3 * Math.sin(2 * Math.PI * 200 * i / rate)) : 0;
    }
    var spans = Transcriber.utterances(b, n, rate);
    check(spans.size == 4, "speech split into utterances (%d)".printf(spans.size / 2));
    var t = new Transcript();
    t.rate = rate;
    Transcriber.align(t.words, "hello there world", b, spans[0], spans[1], rate);
    Transcriber.align(t.words, "second sentence here", b, spans[2], spans[3], rate);
    check(t.words.size == 6 && t.words[0].start >= spans[0] && t.words[5].end == spans[3], "words aligned inside utterances");
    var doc = Document.from_source(PcmSource.from_samples(b, rate, 1), "speech");
    int64 before = doc.length;
    t.words[1].deleted = true;
    int cuts = TextEdit.apply_document(doc, t);
    check(cuts == 1 && doc.length < before && t.words.size == 5, "deleting a word cuts the audio");
    check(t.text() == "hello world second sentence here", "transcript text after edit");
    var s = new Session(rate, 2);
    var tr = s.add_track("Voice", TrackKind.AUDIO, 1);
    s.add_clip(tr, PcmSource.from_samples(b, rate, 1), "", 0);
    var t2 = new Transcript();
    t2.rate = rate;
    Transcriber.align(t2.words, "hello there world", b, spans[0], spans[1], rate);
    t2.words[2].deleted = true;
    int64 len_before = s.length;
    TextEdit.apply_session(s, t2);
    check(s.length < len_before && tr.clips.size == 2, "deleting a word splits the session clip");
    check(t.srt().contains("-->"), "subtitle export");
    string script = tmp("fake-asr.sh");
    FileUtils.set_contents(script, "#!/bin/sh\necho one two three\n");
    FileUtils.chmod(script, 0755);
}

void run_loop(uint ms) {
    var loop = new MainLoop();
    Timeout.add(ms, () => {
        loop.quit();
        return GLib.Source.REMOVE;
    });
    loop.run();
}

void test_live() throws Error {
    Environment.set_variable("SINGULARITY_WAVE_TEST_INPUT", "tone", true);
    Environment.set_variable("SINGULARITY_WAVE_AUDIO_SINK", "fakesink sync=true", true);
    var devices = new InputDevices();
    var dev = devices.find("test");
    check(dev.id == "test", "test input device listed");
    var rec = new Recorder();
    PcmSource? got = null;
    int64 at = -1;
    rec.finished.connect((s, a) => {
        got = s;
        at = a;
    });
    rec.start(dev, 48000, 1, null);
    run_loop(1500);
    rec.stop();
    check(got != null && got.frames > 48000 / 2, "recording captured %lld frames".printf(got != null ? got.frames : 0));
    if (got != null) {
        var m = new float[4096];
        got.read(got.frames / 2, 4096, m);
        float hz = WaveDsp.detect_pitch(m, 4096, 48000);
        check(Math.fabs(hz - 440) < 5, "recorded the 440 Hz input: %.1f".printf(hz));
    }
    var punch = new Recorder();
    PcmSource? take = null;
    int64 take_at = -1;
    punch.finished.connect((s, a) => {
        take = s;
        take_at = a;
    });
    punch.start_frame = 0;
    punch.punch_in = 24000;
    punch.punch_out = 48000;
    punch.start(dev, 48000, 1, null);
    run_loop(1600);
    punch.stop();
    check(take != null && take_at == 24000 && (take.frames - 24000).abs() < 2400, "punch in keeps only the range (%lld frames at %lld)".printf(take != null ? take.frames : 0, take_at));
    var player = new Player();
    var doc = make_doc(48000, 2, 3, 440);
    player.open(doc);
    player.looping = true;
    player.loop_start = 0;
    player.loop_end = 24000;
    player.play(0);
    run_loop(1200);
    int64 pos = player.position;
    bool playing = player.playing;
    player.stop();
    check(playing && pos >= 0 && pos < 24000, "loop playback stays inside the loop (%lld)".printf(pos));
    check(player.meter.integrated.is_finite() || player.meter.momentary.is_finite(), "live loudness meter runs during playback");
    var mon = new Recorder();
    mon.start_monitor(dev, 48000, 2, 128);
    run_loop(600);
    int64 lat = mon.monitor_latency_ns();
    check(mon.monitoring, "input monitoring pipeline runs (latency %.2f ms)".printf(lat / 1e6));
    mon.stop_monitor();
}

void test_transcribe_command() throws Error {
    string conf = Path.build_filename(scratch, "config", "singularity");
    DirUtils.create_with_parents(conf, 0755);
    string script = Path.build_filename(scratch, "asr.sh");
    FileUtils.set_contents(script, "#!/bin/sh\necho hello world again\n");
    FileUtils.chmod(script, 0755);
    FileUtils.set_contents(Path.build_filename(conf, "wave.conf"), "[Transcription]\nCommand=%s %%f\n".printf(script));
    Environment.set_variable("XDG_CONFIG_HOME", Path.build_filename(scratch, "config"), true);
    Environment.set_variable("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent-wave-test", true);
    int rate = 16000;
    var b = new float[rate * 5];
    for (int i = 0; i < b.length; i++) {
        bool on = (i > rate / 2 && i < rate * 2) || (i > rate * 3 && i < rate * 4);
        b[i] = on ? (float) ((0.5 + 0.5 * Math.sin(2 * Math.PI * 4 * i / rate)) * 0.3 * Math.sin(2 * Math.PI * 200 * i / rate)) : 0;
    }
    var doc = Document.from_source(PcmSource.from_samples(b, rate, 1), "speech");
    var tr = new Transcriber();
    check(tr.backend != null && tr.backend.name == "command", "command transcription backend from wave.conf");
    Transcript? t = null;
    var loop = new MainLoop();
    tr.transcribe.begin(doc, "", null, (o, r) => {
        try {
            t = tr.transcribe.end(r);
        } catch (Error e) {
            print("FAIL transcribe %s\n", e.message);
        }
        loop.quit();
    });
    loop.run();
    check(t != null && t.words.size == 6 && t.words[3].start > rate * 2, "two utterances transcribed with word times");
}

int main(string[] args) {
    Gst.init(ref args);
    scratch = Environment.get_variable("WAVE_TEST_DIR") ?? Path.build_filename(Environment.get_tmp_dir(), "wave-test");
    DirUtils.create_with_parents(scratch, 0755);
    Environment.set_variable("XDG_CACHE_HOME", Path.build_filename(scratch, "cache"), true);
    Environment.set_variable("XDG_DATA_HOME", Path.build_filename(scratch, "data"), true);
    try {
        test_document();
        test_formats();
        test_loudness();
        test_effects();
        test_restoration();
        test_session();
        test_surround();
        test_session_io();
        test_workflows();
        test_transcript();
        test_live();
        test_transcribe_command();
    } catch (Error e) {
        print("FAIL exception %s\n", e.message);
        failures++;
    }
    print("%d failures\n", failures);
    return failures == 0 ? 0 : 1;
}
