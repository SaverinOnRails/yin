project('Yin','cpp' ,'c')
wayland_client_dep = dependency('wayland-client')

wayland_scanner = dependency('wayland-scanner', version: '>=1.14.91', native: true)
wayland_protos = dependency('wayland-protocols', version: '>=1.31')
wayland_scanner_prog = find_program(wayland_scanner.get_variable('wayland_scanner'), native: true)

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
	# wl_protocol_dir / 'stable/viewporter/viewporter.xml',
	# wl_protocol_dir / 'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
	wl_protocol_dir / 'staging/fractional-scale/fractional-scale-v1.xml',
	'protocols/wlr-layer-shell-unstable-v1.xml',
]
protos_src = []
foreach filename : client_protocols
	protos_src += wayland_scanner_code.process(filename)
	protos_src += wayland_scanner_client.process(filename)
endforeach

executable('yin',['daemon/Monitor.cpp','daemon/main.cpp' , 'daemon/Daemon.cpp' , 'daemon/Daemon.cpp' , 'daemon/Buffer.cpp', 'shared/IPC.cpp'  , protos_src],dependencies:wayland_client_dep)

executable('yinctl' , ['client/main.cpp' , 'shared/IPC.cpp' , 'shared/Binary.cpp', 'shared/Message.cpp'])
