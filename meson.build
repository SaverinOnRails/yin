project('Yin','cpp' ,'c')
wayland_client_dep = dependency('wayland-client')
avformat = dependency('libavformat')
wl_egl=dependency('wayland-egl')
egl=dependency('egl')
va_wayland=dependency('libva-wayland')
# gles_dep = dependency('glesv2')
gl=dependency('gl')
avcodec = dependency('libavcodec')
avutil = dependency('libavutil')
wayland_scanner = dependency('wayland-scanner', version: '>=1.14.91', native: true)
wayland_protos = dependency('wayland-protocols', version: '>=1.31')
wayland_scanner_prog = find_program(wayland_scanner.get_variable('wayland_scanner'), native: true)

cpp = meson.get_compiler('cpp')

cuda_inc = include_directories('/opt/cuda/include')

cuda = cpp.find_library(
  'cuda',
  dirs: ['/opt/cuda/lib64', '/usr/lib'],
  required: true
)

wayland_scanner_code = generator(
	wayland_scanner_prog,
	output: '@BASENAME@-protocol.c',
	arguments: ['private-code', '@INPUT@', '@OUTPUT@'],
)
wayland_scanner_client = generator(
	wayland_scanner_prog,
	output: '@BASENAME@-client-protocol.h',
	arguments: ['client-header', '@INPUT@', '@OUTPUT@'],
)

wl_protocol_dir = wayland_protos.get_variable('pkgdatadir')
client_protocols = [
	wl_protocol_dir / 'stable/xdg-shell/xdg-shell.xml',
	wl_protocol_dir / 'stable/viewporter/viewporter.xml',
	# wl_protocol_dir / 'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
	wl_protocol_dir / 'staging/fractional-scale/fractional-scale-v1.xml',
	'protocols/wlr-layer-shell-unstable-v1.xml',
]
protos_src = []
foreach filename : client_protocols
	protos_src += wayland_scanner_code.process(filename)
	protos_src += wayland_scanner_client.process(filename)
endforeach

executable('yin',['daemon/Monitor.cpp','daemon/main.cpp' ,  'daemon/Daemon.cpp' , 'daemon/Buffer.cpp', 'daemon/IPC_Server.cpp', 'shared/Binary.cpp' ,'shared/Message.cpp' ,'daemon/Wallpaper.cpp' , protos_src],dependencies:[wayland_client_dep , wl_egl, egl, gl, avcodec,avformat,avutil,va_wayland,cuda], include_directories:[cuda_inc])

 executable('yinctl' , ['client/main.cpp' , 'client/IPC_Client.cpp' , 'shared/Binary.cpp', 'shared/Message.cpp' , 'client/Ffmpeg.cpp']  )
