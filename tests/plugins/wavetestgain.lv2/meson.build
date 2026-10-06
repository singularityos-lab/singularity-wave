lv2_gain = shared_module('wavetestgain', 'wavetestgain.c',
  name_prefix: '',
  include_directories: plugin_abi_inc,
)
lv2_gain_ui = shared_module('wavetestgain_ui', 'wavetestgain_ui.c',
  name_prefix: '',
  include_directories: plugin_abi_inc,
)
configure_file(input: 'manifest.ttl', output: 'manifest.ttl', copy: true)
configure_file(input: 'wavetestgain.ttl', output: 'wavetestgain.ttl', copy: true)
