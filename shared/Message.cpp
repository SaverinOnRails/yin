#include "shared/utils.hpp"
#include <cstddef>
#include <stdexcept>
#include <variant>
#include <vector>
// ipc messages

std::vector<u8> SerializeMessage(Message &msg) {
  std::vector<u8> out;
  VectorWriter writer(out);

  if (std::holds_alternative<MonitorSizeMessage>(msg)) {
    auto &m = std::get<MonitorSizeMessage>(msg);

    writer.write(MonitorSize);
    writer.writeOptionalMonitor(m.monitor);
  }
  if (std::holds_alternative<PlayPauseMessage>(msg)) {
    auto &m = std::get<PlayPauseMessage>(msg);
    writer.write(PlayPause);
    writer.writeOptionalMonitor(m.monitor);
    writer.write(m.play ? 1 : 0);
  }
  if (std::holds_alternative<SetWallpaperMessage>(msg)) {
    auto &m = std::get<SetWallpaperMessage>(msg);

    writer.write(SetWallpaper);
    writer.writeOptionalMonitor(m.monitor);
    writer.writeu32(m.imgPath.length());
    writer.writeString(m.imgPath);
  }

  return out;
}
Message DeserializeMessage(char *buf, size_t len) {
  auto bufReader = BufReader(buf, len);
  u8 tag = bufReader.read();
  switch (tag) {
  case MonitorSize:
    return MonitorSizeMessage{.monitor = bufReader.readOptionalMonitor()};
    break;
  case PlayPause: {
    PlayPauseMessage msg = {.monitor = bufReader.readOptionalMonitor()};
    msg.play = bufReader.read() == 1 ? true : 0;
    return msg;
  }
  case SetWallpaper: {
    SetWallpaperMessage msg = {.monitor = bufReader.readOptionalMonitor()};
    auto img_path_len = bufReader.readu32();
    msg.imgPath = bufReader.readString(img_path_len);
    return msg;
  };
  default:
    throw std::runtime_error("Unknown message");
  }
}
