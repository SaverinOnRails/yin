


## Yin
Yin is an efficient animated wallpaper daemon inspired by [swww](https://github.com/LGFae/swww).
Yin is IPC controlled, hardware accelerated and can play pretty much anything that ffmpeg can. It is also extremely lightweight, depending only on wayland and ffmpeg.

## Dependencies
- Wayland client and protocols
- Latest c++ compiler
- ffmpeg


# Build
Simply clone and run. Ensure meson is installed
```
meson setup release --buildtype=release
meson compile -C release
sudo cp release/yin /usr/bin
sudo cp release/yinctl /usr/bin
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

Then control it with yinctl
```
yinctl --help
```
https://github.com/user-attachments/assets/552923ae-e535-4461-a34f-fb7d5c7c057a


# FEATURES
- Runtime control via IPC without ever needing to restart the daemon
- Hardware acceleration , will play anything efficiently.
- Can play videos, gifs, and static images.
- Multi monitor support
- Runtime pause and play commands

# Limitations
There is currently no software rendering fallback should hardware decoding fail. Which means if your video drivers are not properly configured you cannot use yin. You can setup your display drivers correctly for your distro.
For example with intel on arch linux:
```
sudo pacman -S mesa libva-intel-driver intel-media-driver
```

Nvidia currently might NOT WORK with yin, i'm still trying to figure that out, if you know anything about using NVDEC or the tweaking the code to work with the nvidia vaapi driver, please contribute. 


