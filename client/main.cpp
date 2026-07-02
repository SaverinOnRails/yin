#include "../shared/IPC.hpp"
#include "shared/utils.hpp"
#include <cstring>
#include <filesystem>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

void setWallpaper();
void PlayPauseWallpaper(bool play);
void RestoreWallpaper();
void getMonitorDimensions(u32 &width, u32 &height);
struct Arguments {
  std::optional<std::string> img_path;
  std::optional<std::string> monitor;
  bool play;
  bool restore =  false;
};

Arguments args = Arguments{};
IPC ipc = IPC{};

void process_args(int argc, char **argv) {
  for (int i = 0; i < argc; i++) {
    if (std::strcmp(argv[i], "--img") == 0) {
      if (i + 1 >= argc)
        throw std::runtime_error("Img not specified");
      args.img_path = argv[i + 1];
    }
    if (std::strcmp(argv[i], "--output") == 0) {
      if (i + 1 >= argc)
        throw std::runtime_error("Output not specified");
      args.monitor = argv[i + 1];
    }
    if (std::strcmp(argv[i], "--pause") == 0) {
      args.play = false;
    }
    if (std::strcmp(argv[i], "--play") == 0) {
      args.play = true;
    }
    if (std::strcmp(argv[i], "--restore") == 0) {
      args.restore = true;
    }
  }
}

int main(int argc, char **argv) {
  process_args(argc, argv);
  ipc.clientConnect();

  if (args.img_path.has_value()) {
    setWallpaper();
  }
  else if (args.restore == true) {
    RestoreWallpaper();
  }
  else if (args.play == false || args.play == true) {
    PlayPauseWallpaper(args.play);
  }
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
  std::filesystem::path input_path(path);

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
  Message message =
      SetWallpaperMessage{.monitor = args.monitor, .imgPath = cachePath};
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
