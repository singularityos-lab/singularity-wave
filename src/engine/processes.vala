namespace Singularity.Apps.Wave {

    namespace Processes {
        public void amplify(Document doc, int64 a, int64 b, double db) throws Error {
            doc.process(a, b, _("Amplify"), (buf, frames, channels, rate) => {
                WaveDsp.gain(buf, (int64) frames * channels, (float) db);
            });
        }

        public void normalize_peak(Document doc, int64 a, int64 b, double target_db, bool per_channel) throws Error {
            doc.process(a, b, _("Normalize"), (buf, frames, channels, rate) => {
                Loudness.normalize_peak(buf, frames, channels, target_db, per_channel);
            });
        }

        public void normalize_loudness(Document doc, int64 a, int64 b, double lufs, double ceiling) throws Error {
            doc.process(a, b, _("Match Loudness"), (buf, frames, channels, rate) => {
                Loudness.normalize(buf, frames, channels, rate, lufs, ceiling);
            });
        }

        public void invert(Document doc, int64 a, int64 b) throws Error {
            doc.process(a, b, _("Invert"), (buf, frames, channels, rate) => {
                for (int64 i = 0; i < (int64) frames * channels; i++) buf[i] = -buf[i];
            });
        }

        public void reverse(Document doc, int64 a, int64 b) throws Error {
            doc.process(a, b, _("Reverse"), (buf, frames, channels, rate) => {
                for (int64 i = 0, j = frames - 1; i < j; i++, j--) {
                    for (int c = 0; c < channels; c++) {
                        float t = buf[i * channels + c];
                        buf[i * channels + c] = buf[j * channels + c];
                        buf[j * channels + c] = t;
                    }
                }
            });
        }

        public void fade(Document doc, int64 a, int64 b, bool fade_in, int curve) throws Error {
            doc.process(a, b, fade_in ? _("Fade In") : _("Fade Out"), (buf, frames, channels, rate) => {
                WaveDsp.fade(buf, frames, channels, fade_in, curve);
            });
        }

        public void remove_dc(Document doc, int64 a, int64 b) throws Error {
            doc.process(a, b, _("Remove DC Offset"), (buf, frames, channels, rate) => {
                for (int c = 0; c < channels; c++) {
                    double sum = 0;
                    for (int64 f = 0; f < frames; f++) sum += buf[f * channels + c];
                    float mean = (float) (sum / int.max(frames, 1));
                    for (int64 f = 0; f < frames; f++) buf[f * channels + c] -= mean;
                }
            });
        }

        public void apply_effect(Document doc, int64 a, int64 b, Effect effect) throws Error {
            doc.process(a, b, effect.title, (buf, frames, channels, rate) => {
                effect.prepare(rate, channels);
                if (effect.offline_only()) {
                    effect.run(buf, frames);
                    return;
                }
                var rack = new EffectRack(rate, channels);
                rack.add(effect);
                rack.process_all(buf, frames);
            });
        }

        public void apply_rack(Document doc, int64 a, int64 b, EffectRack rack) throws Error {
            doc.process(a, b, _("Apply Effects"), (buf, frames, channels, rate) => {
                var copy = rack.copy();
                copy.configure(rate, channels);
                copy.process_all(buf, frames);
            });
        }

        public void reduce_noise(Document doc, int64 a, int64 b, double reduction, double sensitivity, double smoothing) throws Error {
            if (!doc.noise.ready) throw new IOError.FAILED(_("Capture a noise print first"));
            doc.process(a, b, _("Noise Reduction"), (buf, frames, channels, rate) => {
                doc.noise.profile.reduce(buf, frames, channels, (float) reduction, (float) sensitivity, (float) smoothing);
            });
        }

        public void capture_noise(Document doc, int64 a, int64 b) {
            if (b <= a) return;
            var buf = doc.read(a, b - a);
            doc.noise.learn(buf, b - a, doc.channels);
        }

        public void restore(Document doc, int64 a, int64 b, string kind, Gee.Map<string, double?> values) throws Error {
            var e = (RestoreEffect) EffectRegistry.create(kind);
            foreach (var entry in values.entries) e.set_value(entry.key, entry.value);
            if (kind == "denoise") e.profile = doc.noise.curve();
            apply_effect(doc, a, b, e);
        }

        public void enhance_speech(Document doc, int64 a, int64 b, double amount) throws Error {
            doc.process(a, b, _("Enhance Speech"), (buf, frames, channels, rate) => {
                SpeechChain.run(buf, frames, channels, rate, amount);
            });
        }

        public void time_stretch(Document doc, int64 a, int64 b, double ratio, double semitones) throws Error {
            if (b <= a) {
                a = 0;
                b = doc.length;
            }
            var buf = doc.read(a, b - a);
            int64 cap = WaveDsp.stretch_frames(b - a, ratio) + 16;
            var result = new float[cap * doc.channels];
            int64 n = WaveDsp.time_stretch(buf, b - a, doc.channels, doc.rate, ratio, semitones, result, cap);
            doc.process_replace(a, b, ratio != 1 ? _("Stretch") : _("Change Pitch"), result, n);
        }

        public void spectral(Document doc, int64 start, float[] mask, int columns, int bins, int fft, int hop, WaveDsp.SpectralMode mode, double gain_db) throws Error {
            int64 a = int64.max(0, start - fft);
            int64 b = int64.min(doc.length, start + (int64) columns * hop + fft * 2);
            string label = mode == WaveDsp.SpectralMode.HEAL ? _("Spectral Repair") : mode == WaveDsp.SpectralMode.AMPLIFY ? _("Spectral Boost") : _("Spectral Attenuate");
            doc.process(a, b, label, (buf, frames, channels, rate) => {
                WaveDsp.spectral_apply(buf, frames, channels, fft, hop, start - a, mask, columns, bins, mode, (float) gain_db);
            });
        }

        public int spot_heal(Document doc, int64 a, int64 b, double min_hz, double max_hz) throws Error {
            int healed = 0;
            int64 pad = doc.rate / 2;
            int64 ra = int64.max(0, a - pad);
            int64 rb = int64.min(doc.length, b + pad);
            doc.process(ra, rb, _("Spot Healing"), (buf, frames, channels, rate) => {
                healed = WaveDsp.spot_heal(buf, frames, channels, rate, a - ra, b - ra, (float) min_hz, (float) max_hz);
            });
            return healed;
        }

        public void generate_tone(Document doc, int64 at, double seconds, double freq, double level_db) throws Error {
            int64 n = (int64) (seconds * doc.rate);
            var buf = new float[n * doc.channels];
            double amp = Math.pow(10, level_db / 20);
            for (int64 f = 0; f < n; f++) {
                float v = (float) (amp * Math.sin(2 * Math.PI * freq * f / doc.rate));
                for (int c = 0; c < doc.channels; c++) buf[f * doc.channels + c] = v;
            }
            var src = PcmSource.from_samples(buf, doc.rate, doc.channels);
            doc.insert(at, { new Segment(src, 0, n) }, _("Generate Tone"));
        }
    }

    namespace SpeechChain {
        public void run(float[] buf, int64 frames, int channels, int rate, double amount) {
            amount = amount.clamp(0, 1);
            WaveDsp.denoise_adaptive(buf, frames, channels, rate, (float) (6 + 14 * amount), 6);
            WaveDsp.dereverb(buf, frames, channels, rate, (float) (0.25 + 0.4 * amount));
            var eq = new EqEffect("eq");
            eq.set_value("b0_on", 1);
            eq.set_value("b0_type", 3);
            eq.set_value("b0_freq", 75);
            eq.set_value("b1_on", 1);
            eq.set_value("b1_freq", 300);
            eq.set_value("b1_gain", -2 * amount);
            eq.set_value("b1_q", 1);
            eq.set_value("b4_on", 1);
            eq.set_value("b4_freq", 4000);
            eq.set_value("b4_gain", 3 * amount);
            eq.set_value("b4_q", 0.7);
            var ds = new DynamicsEffect("deesser");
            var comp = new DynamicsEffect("compressor");
            comp.set_value("threshold", -24);
            comp.set_value("ratio", 2.5 + 1.5 * amount);
            comp.set_value("makeup", 3);
            var rack = new EffectRack(rate, channels);
            rack.add(eq);
            rack.add(ds);
            rack.add(comp);
            rack.process_all(buf, frames);
        }
    }
}
