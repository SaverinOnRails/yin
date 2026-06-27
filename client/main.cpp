#include "shared/utils.hpp"
#include <cstring>
#include <iostream>
#include <optional>
#include <stdexcept>

void setWallpaper();
void getMonitorDimensions(u32 &width, u32 &height);
struct Arguments {
  std::optional<std::string> img_path;
  std::optional<std::string> monitor;
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
  }
}

int main(int argc, char **argv) {
  process_args(argc, argv);
  ipc.clientConnect();

  if (args.img_path.has_value()) {
    setWallpaper();
  }
}

void setWallpaper() {
  u32 width, height;
  std::cout << "getting montitor dimensions" << std::endl;
  getMonitorDimensions(width, height);
}

// get monitor logical size
// will default to first available monitor if not specified
void getMonitorDimensions(u32 &width, u32 &height) {
  Message message = MonitorSizeMessage{.monitor = args.monitor};
  auto payload = SerializeMessage(message);
  auto len = payload.size();
  ipc.clientWrite(payload.data(), len);

  char msg[1024];
  ipc.clientRead(msg, sizeof(msg));
  std::cout << msg << std::endl;
}
