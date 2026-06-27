#include "shared/utils.hpp"
#include <stdexcept>
#include <variant>
#include <vector>

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
