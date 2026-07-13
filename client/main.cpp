#include "shaders_generated.hpp"
#include "shared/IPC.hpp"
#include "shared/utils.hpp"
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>

void setWallpaper();
void PlayPauseWallpaper(bool play);
void RestoreWallpaper();
void printHelp();
void getMonitorDimensions(u32 &width, u32 &height);
struct Arguments {
  std::optional<std::string> img_path;
  std::optional<std::string> monitor;
  std::optional<bool> play;
  std::optional<std::string> transition;
  bool help = false;
  bool restore = false;
  bool listTrans = false;
};

Arguments args = Arguments{};
IPC ipc = IPC{};

void process_args(int argc, char **argv) {
  for (int i = 0; i < argc; i++) {
    if (argv[i] == std::string_view{"--img"}) {
      if (i + 1 >= argc)
        throw std::runtime_error("Img not specified");
      args.img_path = argv[i + 1];
    } else if (argv[i] == std::string_view{"--output"}) {
      if (i + 1 >= argc)
        throw std::runtime_error("Output not specified");
      args.monitor = argv[i + 1];
    } else if (argv[i] == std::string_view{"--pause"}) {
      args.play = false;
    } else if (argv[i] == std::string_view{"--play"}) {
      args.play = true;
    } else if (argv[i] == std::string_view{"--restore"}) {
      args.restore = true;
    } else if (argv[i] == std::string_view{"--help"} ||
               argv[i] == std::string_view{"-h"}) {
      args.help = true;
    } else if (argv[i] == std::string_view{"--trans"}) {
      if (i + 1 >= argc)
        throw std::runtime_error("Transition not specified");
      args.transition = argv[i + 1];
    } else if (argv[i] == std::string_view{"--list-trans"}) {
      args.listTrans = true;
    }
  }
}

int main(int argc, char **argv) {
  process_args(argc, argv);
  if (args.help == true) {
    printHelp();
  } else if (args.listTrans) {
    std::cout << availableTransitions << std::endl;
    std::exit(0);
  }else{}

  ipc.clientConnect();
  if (args.img_path.has_value()) {
    setWallpaper();
  } else if (args.restore == true) {
    RestoreWallpaper();
  } else if (args.play.has_value()) {
    PlayPauseWallpaper(*args.play);
  } }

void printHelp() {
  std::cout << "Usage: " << "yinctl" << " [OPTIONS]\n\n"
            << "Options:\n"
            << "  --img <FILE>        Set the wallpaper to FILE\n"
            << "  --output <MONITOR>  Apply the action to a specific monitor\n"
            << "                      (defaults to first monitor)\n"
            << "  --play              Resume animated wallpaper playback\n"
            << "  --pause             Pause animated wallpaper playback\n"
            << "  --restore           Restore previously cached wallpapers\n"
            << " --trans <TRANSITION> Set the transition that will be used for "
               "this request\n"
            << " --list-trans         List all available transitions\n"
            << "  -h, --help          Show this help message\n\n"
            << "Examples:\n"
            << "  " << "yinctl" << " --img ~/Pictures/wallpaper.jpg\n"
            << "  " << "yinctl" << " --img video.mp4 --output HDMI-A-1\n"
            << "  " << "yinctl" << " --pause\n"
            << "  " << "yinctl" << " --play --output DP-1\n"
            << "  " << "yinctl" << " --restore\n";
  std::exit(0);
}

void PlayPauseWallpaper(bool play) {
  // get monitor dimensions is convenient for checking if the monitor supplied
  // exists or is correct so we're just gonna call it
  u32 width, height;
  getMonitorDimensions(width, height);
  Message message = PlayPauseMessage{.monitor = args.monitor, .play = play};
  // reset connection for fresh message
  auto payload = SerializeMessage(message);
  ipc.clientConnect();
  ipc.clientWrite(payload.data(), payload.size());
}
std::string getCachePath(u32 width, u32 height, const std::string &path) {
  //don't cache image files
  std::filesystem::path input_path(path);
  if(input_path.extension() != ".mp4" && input_path.extension() != ".mkv") {
    return path;
  }

  std::string cache_name = std::to_string(width) + "x" +
                           std::to_string(height) + "_" +
                           input_path.filename().string();
  const char *home = std::getenv("HOME");
  if (!home)
    throw std::runtime_error("HOME environment variable not set");

  std::filesystem::path cache_dir =
      std::filesystem::path(home) / ".cache" / "yin";

  std::filesystem::create_directories(cache_dir);

  return (cache_dir / cache_name).string();
}
void setWallpaper() {
  u32 width, height;
  getMonitorDimensions(width, height);

  // cache video
  auto cachePath = getCachePath(width, height, args.img_path.value());
  if (!std::filesystem::exists(cachePath)) {
    cacheVideo(args.img_path.value(), cachePath, width, height);
  }
  Message message = SetWallpaperMessage{.monitor = args.monitor,
                                        .transition = args.transition,
                                        .imgPath = cachePath};
  auto payload = SerializeMessage(message);

  // reset connection for fresh message
  ipc.clientConnect();
  ipc.clientWrite(payload.data(), payload.size());

  char msg[1024];
  auto bytes = ipc.clientRead(msg, sizeof(msg));
  std::string response(msg, bytes);
  std::cout << response << std::endl;
}

void RestoreWallpaper() {
  u32 width, height;
  getMonitorDimensions(width, height);
  Message message = RestoreMessage{.monitor = args.monitor};
  auto payload = SerializeMessage(message);
  auto len = payload.size();
  ipc.clientConnect();
  ipc.clientWrite(payload.data(), len);
  char msg[1024];
  auto bytes = ipc.clientRead(msg, sizeof(msg));
  std::string response(msg, bytes);
  std::cout << response << std::endl;
}

// get monitor buffer size
// will default to first available monitor if not specified
void getMonitorDimensions(u32 &width, u32 &height) {
  Message message = MonitorSizeMessage{.monitor = args.monitor};
  auto payload = SerializeMessage(message);
  auto len = payload.size();
  ipc.clientWrite(payload.data(), len);
  char msg[1024];
  auto bytes = ipc.clientRead(msg, sizeof(msg));
  std::string response(msg, bytes);
  if (response.length() == 0) {
    throw std::runtime_error("Could not find required monitor");
  }
  auto splitPoint = response.find('x');
  width = std::stoi(response.substr(0, splitPoint));
  height = std::stoi(response.substr(splitPoint + 1));
}
