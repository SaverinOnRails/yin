#include "shared/IPC.hpp"
#include <cstddef>
#include <cstring>
#include <stdexcept>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

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

void IPC::clientWrite(unsigned char *data, size_t len) {
  ::write(m_clientFd, reinterpret_cast<char *>(data), len);
}
size_t IPC::clientRead(char *buffer, size_t len) {
  return ::read(m_clientFd, buffer, len);
}
