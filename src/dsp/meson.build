dsp_lib = static_library('wavedsp',
  files('fft.c', 'spectral.c', 'restore.c', 'eq.c', 'dynamics.c', 'loudness.c', 'reverb.c', 'mod.c', 'pitch.c', 'util.c'),
  include_directories: include_directories('.'),
  dependencies: [math_dep],
  c_args: ['-O3', '-std=gnu11'],
)
dsp_dep = declare_dependency(link_with: dsp_lib, include_directories: include_directories('.'), dependencies: [math_dep])
