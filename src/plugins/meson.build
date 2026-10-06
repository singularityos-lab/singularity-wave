plugin_host_install_path = get_option('prefix') / get_option('libexecdir') / 'singularity-wave-plugin-host'

plugin_c = static_library('waveplug',
  files('ttl.c', 'wp_util.c', 'lv2.c', 'ladspa.c', 'clap.c', 'plugin.c', 'instance.c', 'presets.c'),
  include_directories: include_directories('.'),
  dependencies: [dl_dep, math_dep, thread_dep],
  c_args: ['-DWAVE_PLUGIN_HOST_PATH="' + plugin_host_install_path + '"'],
)

plugin_c_dep = declare_dependency(
  link_with: plugin_c,
  include_directories: include_directories('.'),
  dependencies: [dl_dep, math_dep, thread_dep],
)

plugin_host = executable('singularity-wave-plugin-host',
  files('host_main.c'),
  dependencies: [plugin_c_dep],
  install: true,
  install_dir: get_option('libexecdir'),
)

plugin_vala = files(
  'plugin_info.vala',
  'plugin_catalog.vala',
  'plugin_effect.vala',
  'lv2_presets.vala',
)
plugin_deps = [plugin_c_dep]
plugin_args = ['--pkg', 'waveplug']
