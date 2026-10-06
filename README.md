# singularity-wave

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Wave for the [Singularity Desktop Environment](https://github.com/singularityos-lab): record, edit, restore and mix audio.

## Requirements

- [Meson](https://mesonbuild.com/) ≥ 1.0
- [Vala](https://vala.dev/) compiler
- libgee-0.8, json-glib-1.0, libxml-2.0, zlib, cairo, pangocairo, GTK4, gstreamer-1.0, gstreamer-app-1.0, gstreamer-audio-1.0, gstreamer-pbutils-1.0, gstreamer-video-1.0
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## Third-party code

- `src/plugins/abi_clap.h`, `abi_lv2.h` and `abi_ladspa.h`: the plugin interfaces of [CLAP](https://github.com/free-audio/clap) (MIT License), [LV2](https://lv2plug.in/) (ISC License) and [LADSPA](https://www.ladspa.org/) (GNU LGPL 2.1), written out so Wave can host those plugins.
- `src/dsp/reverb.c`: the comb and allpass delay lengths of Freeverb by Jezar at Dreampoint, public domain.

## License

GPL-3.0-only - see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-wave. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
