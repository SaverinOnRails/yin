#include "IPC.hpp"
#include "shared/utils.hpp"
#include <cstddef>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <variant>

void IPC::clientConnect() {
  const char *SOCKET_PATH = "/tmp/yin";
  m_clientFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (m_clientFd == -1) {
    throw std::runtime_error(
        "Could not connect to Ipc socket, is Yin daemon running?");
  }
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

  if (connect(m_clientFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) ==
      -1)
    throw std::runtime_error(
        "Could not connect to Ipc socket, is Yin daemon running?");
}

void IPC::serverCreate() {
  constexpr const char *SOCKET_PATH = "/tmp/yin";
  unlink(SOCKET_PATH);
  m_serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (m_serverFd == -1) {
    throw std::runtime_error("Could not start IPC server");
  }

  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);

  if (bind(m_serverFd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) ==
      -1) {
    throw std::runtime_error("Could not start IPC server");
  }

  if (listen(m_serverFd, 5) == -1) {
    throw std::runtime_error("Could not start IPC server");
  }
}

void IPC::serverAccept(Daemon &daemon) {
  int client = accept(m_serverFd, nullptr, nullptr);
  char buffer[1024];
  ssize_t bytes = ::read(client, buffer, sizeof(buffer));
  if (bytes > 0) {
    auto message = DeserializeMessage(buffer, bytes);
    if (std::holds_alternative<MonitorSizeMessage>(message)) {
      auto mes = std::get<MonitorSizeMessage>(message);

      if (auto *monitor = daemonFindMonitor(daemon, mes.monitor)) {
        std::string dimensions = std::to_string(monitor->m_bufferWidth) + "x" +
                                 std::to_string(monitor->m_bufferHeight);

        write(client, dimensions.data(), dimensions.size());
      }
    }
  }
  close(client);
}

Monitor *IPC::daemonFindMonitor(Daemon &daemon,
                                const std::optional<std::string> &monitorName) {
  if (!monitorName.has_value()) {
    return daemon.m_monitors.empty() ? nullptr
                                     : daemon.m_monitors.front().get();
  }

  for (auto &monitor : daemon.m_monitors) {
    if (monitor->m_name == *monitorName) {
      return monitor.get();
    }
  }
  return nullptr;
}
void IPC::clientWrite(unsigned char *data, size_t len) {
  ::write(m_clientFd, reinterpret_cast<char *>(data), len);
}
size_t IPC::clientRead(char *buffer, size_t len) {
  return ::read(m_clientFd, buffer, len);
}
