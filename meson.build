project('singularity-wave', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-wave"', language: 'c')
add_project_arguments('-w', language: 'c')
add_project_arguments('-DWAVE_SYSCONFDIR="@0@"'.format(get_option('prefix') / get_option('sysconfdir')), language: 'c')
subdir('po')

cc = meson.get_compiler('c')
math_dep = cc.find_library('m')
dl_dep = cc.find_library('dl', required: false)
thread_dep = dependency('threads')
gee_dep = dependency('gee-0.8')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
json_dep = dependency('json-glib-1.0')
xml_dep = dependency('libxml-2.0')
zlib_dep = dependency('zlib')
cairo_dep = dependency('cairo')
pango_dep = dependency('pangocairo')
gtk_dep = dependency('gtk4')
gst_dep = dependency('gstreamer-1.0')
gst_app_dep = dependency('gstreamer-app-1.0')
gst_audio_dep = dependency('gstreamer-audio-1.0')
gst_pbutils_dep = dependency('gstreamer-pbutils-1.0')
gst_video_dep = dependency('gstreamer-video-1.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('src/dsp')
subdir('src/plugins')

vapi_args = ['--vapidir', meson.current_source_dir() / 'vapi', '--pkg', 'wavedsp', '--pkg', 'zlib', '--pkg', 'posix', '--pkg', 'libxml-2.0']

engine = files(
  'src/engine/effect.vala',
  'src/engine/source.vala',
  'src/engine/metadata.vala',
  'src/engine/riff.vala',
  'src/engine/decoder.vala',
  'src/engine/document.vala',
  'src/engine/builtin_effects.vala',
  'src/engine/rack.vala',
  'src/engine/loudness.vala',
  'src/engine/processes.vala',
  'src/engine/export.vala',
  'src/engine/session.vala',
  'src/engine/mixer.vala',
  'src/engine/zip.vala',
  'src/engine/session_file.vala',
  'src/engine/interchange.vala',
  'src/engine/player.vala',
  'src/engine/recorder.vala',
  'src/engine/workflows.vala',
  'src/engine/transcript.vala',
)

engine_deps = [gee_dep, gio_dep, gio_unix_dep, json_dep, xml_dep, zlib_dep, math_dep, thread_dep, gst_dep, gst_app_dep, gst_audio_dep, gst_pbutils_dep, dsp_dep] + plugin_deps
engine_sources = engine + plugin_vala

ui = files(
  'src/ui/app.vala',
  'src/ui/window.vala',
  'src/ui/dialogs.vala',
  'src/ui/widgets.vala',
  'src/ui/rack_panel.vala',
  'src/ui/waveform_view.vala',
  'src/ui/transport.vala',
  'src/ui/panels.vala',
  'src/ui/timeline_view.vala',
  'src/ui/mixer_view.vala',
  'src/ui/session_panels.vala',
  'src/ui/process_dialogs.vala',
  'src/ui/print_cloud.vala',
  'src/ui/test_script.vala',
  'src/ui/ribbon.vala',
)

gnome = import('gnome')
resources = gnome.compile_resources(
  'singularity-wave-resources',
  'resources/dev.sinty.wave.gresource.xml',
  source_dir: meson.current_source_dir() / 'data' / 'icons',
)

executable('singularity-wave',
  engine_sources + ui + [resources],
  dependencies: engine_deps + [gtk_dep, cairo_dep, pango_dep, gst_video_dep, libsingularity_dep],
  vala_args: vapi_args + plugin_args,
  install: true
)

engine_test = executable('wave-engine-test',
  engine_sources + files('tests/engine_test.vala'),
  dependencies: engine_deps,
  vala_args: vapi_args + plugin_args,
)
test('wave-engine', engine_test, timeout: 900, is_parallel: false, env: ['WAVE_TEST_DIR=' + meson.current_build_dir() / 'engine-test', 'LC_ALL=C.UTF-8'])

install_data('data/dev.sinty.wave.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.wave.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/dev.sinty.wave.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)
install_data('data/dev.sinty.wave.open.ini',
  install_dir: get_option('datadir') / 'singularity' / 'files-actions'
)
install_data('data/dev.sinty.wave.xml',
  install_dir: get_option('datadir') / 'mime' / 'packages'
)
install_data('data/dev.sinty.wave.metainfo.xml',
  install_dir: get_option('datadir') / 'metainfo'
)
install_data('data/icons/dev.sinty.wave.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)

dsp_test = executable('wave-dsp-test',
  files('tests/dsp/dsp_test.c'),
  dependencies: [dsp_dep],
  c_args: ['-O2'],
)
test('wave-dsp', dsp_test, timeout: 300)

subdir('tests/plugins')
