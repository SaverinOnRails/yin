#pragma once
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
using u32 = uint32_t;
using u64 = uint64_t;
using i32 = int32_t;
using u8 = uint8_t;
class Daemon;

enum Messages : u8 { MonitorSize = 0, SetWallpaper = 1, PlayPause = 2, Restore = 3 };

class VectorWriter {
public:
  VectorWriter(std::vector<u8> &data);
  void write(u8 data);
  void writeu32(u32 data);
  void writeString(std::string_view data);
  void writeOptionalMonitor(const std::optional<std::string> &monitor) {
    if (!monitor) {
      write(0);
      return;
    }
    if (monitor->length() > 255) {
      throw std::runtime_error("Monitor name is too long");
    }

    write(static_cast<u8>(monitor->length()));
    writeString(*monitor);
  }

private:
  std::vector<u8> &m_data;
};

class BufReader {
public:
  BufReader(char *buf, size_t len);
  u8 read();
  u32 readu32();
  std::string readString(size_t len);
  std::optional<std::string> readOptionalMonitor() {
    u8 length = read();

    if (length == 0) {
      return std::nullopt;
    }
    return readString(length);
  }

private:
  char *m_buf;
  size_t m_len;
  size_t m_index = 0;
};

struct MonitorSizeMessage {
  std::optional<std::string> monitor;
};

struct SetWallpaperMessage {
  std::optional<std::string> monitor;
  std::optional<std::string> transition;
  std::string imgPath;
};
struct PlayPauseMessage {
  std::optional<std::string> monitor;
  bool play;
};

struct RestoreMessage {
  std::optional<std::string> monitor;
};

using Message =
    std::variant<MonitorSizeMessage, SetWallpaperMessage, PlayPauseMessage , RestoreMessage>;

std::vector<u8> SerializeMessage(Message &msg);
Message DeserializeMessage(char *buf, size_t len);
void cacheVideo(std::string_view filepath, std::string_view write_to, u32 width,
                u32 height);
std::string getCachePath(u32 width, u32 height, std::string_view path);

enum HardwareAccelerationBackend { Vaapi, CudaCopy };
