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

class IPC {
public:
  void clientConnect();
  void serverCreate();
  void serverAccept();
  void clientWrite(unsigned char * data, size_t len);
  void clientRead(char * buffer, size_t len);
  int m_serverFd;
  int m_clientFd;
};

enum Messages : u8 { MonitorSize = 0 };


class VectorWriter  {
public:
  VectorWriter(std::vector<u8> &data);
  void write(u8 data) ;
  void writeString(std::string_view data) ;

private:
  std::vector<u8> &m_data;
};

struct MonitorSizeMessage {
  std::optional<std::string> monitor;
};

using Message = std::variant<MonitorSizeMessage>;

std::vector<u8> SerializeMessage(Message& msg);
