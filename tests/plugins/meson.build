plugin_abi_inc = include_directories('../../src/plugins')

subdir('wavetestgain.lv2')

ladspa_gain = shared_module('wavetest_ladspa', 'ladspa_gain.c',
  name_prefix: '',
  include_directories: plugin_abi_inc,
)
ladspa_crash = shared_module('wavetest_crash', 'ladspa_crash.c',
  name_prefix: '',
  include_directories: plugin_abi_inc,
)
ladspa_scancrash = shared_module('wavetest_scancrash', 'ladspa_scancrash.c',
  name_prefix: '',
  include_directories: plugin_abi_inc,
)
clap_gain = shared_module('wavetest_gain', 'clap_gain.c',
  name_prefix: '',
  name_suffix: 'clap',
  include_directories: plugin_abi_inc,
)

plugin_test_effect = configure_file(input: '../../src/engine/effect.vala', output: 'effect.vala', copy: true)

plugin_test = executable('wave-plugins-test',
  files('plugin_test.vala') + [plugin_test_effect] + plugin_vala,
  dependencies: [gee_dep, gio_dep, json_dep, math_dep] + plugin_deps,
  vala_args: ['--vapidir', meson.project_source_root() / 'vapi', '--pkg=posix'] + plugin_args,
)

test('wave-plugins', plugin_test,
  env: [
    'SINGULARITY_WAVE_PLUGIN_PATH=' + meson.current_build_dir(),
    'SINGULARITY_WAVE_PLUGIN_HOST=' + plugin_host.full_path(),
    'LV2_PATH=',
    'LADSPA_PATH=',
    'CLAP_PATH=',
    'HOME=' + meson.current_build_dir() / 'home',
    'LC_ALL=C.UTF-8',
  ],
  depends: [lv2_gain, lv2_gain_ui, ladspa_gain, ladspa_crash, ladspa_scancrash, clap_gain, plugin_host],
  timeout: 120,
  is_parallel: false,
)
