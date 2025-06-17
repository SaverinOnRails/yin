## Yin
Yin is an efficient animated wallpaper daemon inspired by [swww](https://github.com/LGFae/swww).
It is controlled at runtime allowing you to switch between wallpapers without restarting the daemon.
All wallpapers are cached to the disk as (~/.cache/yin) initially allowing them to be loaded very swiftly subsequently.

## Dependencies
- Wayland client and protocols
- Zig 0.14
- LZ4

# Build
Simply clone and run
```
zig build
```
in the project directory.

## Usage
Yin can display any format supported by the [zigimg](https://github.com/zigimg/zigimg) library.
First start the daemon by running:
```
./yin
```
in the install directory.

The control it with yinctl
```
yinctl --help
```



