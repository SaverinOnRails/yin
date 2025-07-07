## Yin
Yin is an efficient animated wallpaper daemon inspired by [swww](https://github.com/LGFae/swww).
It is controlled at runtime allowing you to switch between wallpapers without restarting the daemon.
Currently, can display many image formats : png, jpeg, gif and even mp4 videos in a more cpu efficient way that other tools like mpvpaper (atleast for short videos). Still under development, use at your own risk. Animated wallpapers can also be paused/resumed using IPC.

## Dependencies
- Wayland client and protocols
- Zig 0.14
- LZ4 for compression
- ffmpeg for rendering videos
- stb for resizing images


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



https://github.com/user-attachments/assets/e97912b1-6d31-4ee8-800b-73f1c1de1a7e


# TODO
- Resize to best resolution for monitor
- Use DMABUF instead of wl_shm
- Maybe some slide transitions with pixman
- Cleanup god awful code


# IMPORTANT THINGS TO NOTE
- While this can play MP4s, it does so by extracting, compressing and storing the frames and then later loading it all into memory. It is optimised for videos and gifs that do not change alot in between frames so really most things you'll find on live wallpaper websites. It should use significantly less cpu but if you want to play highres very long videos, other tools like mpvpaper will probably serve you better.

- I built this mainly to solve a problem i was having with swww(converting videos to gif which causes a lot banding and quality losses) and to learn how to use the Zig Programming Language. I also only have one laptop screen so if you try to use this with a multi monitor setup, expect catastrophic failure. If you still go ahead and encounter any issues which you will, please file a specific issue and i'll see what i can do about it. Contributions are also welcome.

