## Yin
Yin is an efficient animated wallpaper daemon inspired by [swww](https://github.com/LGFae/swww).
It is controlled at runtime allowing you to switch between wallpapers without restarting the daemon.
Currently, can display many image formats : png, jpeg, gif and even mp4 videos in a more cpu efficient way that other tools like mpvpaper (atleast for short videos). Still under development, use at your own risk. Animated wallpapers can also be paused/resumed using IPC.

## Dependencies
- Wayland client and protocols
- Zig 0.14
- LZ4
- ffmpeg


# Build
Simply clone and run
```
zig build
```
in the project directory.


# Install
Yin is also available in the AUR:
```
yay -S yin-git
```

## Usage
First start the daemon by running:
```
yin
```

The control it with yinctl
```
yinctl --help
```



