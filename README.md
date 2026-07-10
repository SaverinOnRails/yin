


## Yin
Yin is an efficient, very lightweight( < 200kb) animated wallpaper daemon inspired by [swww](https://github.com/LGFae/swww).
Yin is IPC controlled, hardware accelerated and can play videos and images. It depends only on wayland and ffmpeg. Yin is still early in dev and VERY unstable.

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

# For nvidia support
meson setup release -Denable_cuda=true --buildtype=release
```
in the project directory.


# Install
Yin is also available in the AUR:
```
yay -S yin-git

For Nvidia support(will unfortunately pull in cuda to build)
yay -S yin-nvidia-git
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
- GPU based transitions
- Does not depend on any external video players like mpv, vlc or Qt media kit

# Important
There is currently no software rendering fallback for videos should hardware decoding fail. Which means if your video drivers are not properly configured you cannot use yin. You can setup your display drivers correctly for your distro.
For example with intel on arch linux:
```
sudo pacman -S mesa libva-intel-driver intel-media-driver
```

# Nvidia
Yin supports nvidia, it will decode videos on the appropriate gpu, but unlike the VAAPI implementation, it is not zero copy so there is some extra CPU usage. To use yin with Nvidia , first ensure you have compiled yin with Nvidia support( follow instructions above). And then explicitly instruct yin to use it on startup:
```
yin --use-cuda-copy
```
It SHOULD work afterwards, there is an issue concerining implementing zero copy NVDEC support.


