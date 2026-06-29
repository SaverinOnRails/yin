#include "shared/utils.hpp"
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <variant>
#include <vector>
// ipc messages

std::vector<u8> SerializeMessage(Message &msg) {
  auto out = std::vector<u8>();
  auto sink = VectorWriter(out);
  if (std::holds_alternative<MonitorSizeMessage>(msg)) {
    sink.write(MonitorSize);
    auto _msg = std::get<MonitorSizeMessage>(msg);
    if (!_msg.monitor.has_value()) {
      sink.write(0);
    } else {
      auto val = _msg.monitor.value();
      if (val.length() > 255) {
        throw std::runtime_error("Monitor name is too long");
      }
      sink.write(val.length());
      sink.writeString(_msg.monitor.value());
    }
  }
  return out;
}

Message DeserializeMessage(char *buf, size_t len) {
  auto bufReader = BufReader(buf, len);
  u8 tag = bufReader.read();
  if (tag == MonitorSize) {
    auto monitor_name_length = bufReader.read();
    std::optional<std::string> monitor_name;
    if (monitor_name_length > 0) {
      monitor_name = bufReader.readString(monitor_name_length);
    }
    return MonitorSizeMessage{.monitor = monitor_name};
  } else {
    throw std::runtime_error("Unknown message");
  }
}
