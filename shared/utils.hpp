#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>
using u32 = uint32_t;
using u64 = uint64_t;
using i32 = int32_t;
using u8 = uint8_t;
class Daemon;


enum Messages : u8 { MonitorSize = 0 };

class VectorWriter {
public:
  VectorWriter(std::vector<u8> &data);
  void write(u8 data);
  void writeString(std::string_view data);

private:
  std::vector<u8> &m_data;
};

class BufReader {
public:
  BufReader(char *buf, size_t len);
  u8 read();
  std::string readString(size_t len);

private:
  char *m_buf;
  size_t m_len;
  size_t m_index = 0;
};

struct MonitorSizeMessage {
  std::optional<std::string> monitor;
};

using Message = std::variant<MonitorSizeMessage>;

std::vector<u8> SerializeMessage(Message &msg);
Message DeserializeMessage(char * buf, size_t len);
void cacheVideo(std::string_view filepath ,u32 width, u32 height);
