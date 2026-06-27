#include "shared/utils.hpp"
#include <cstddef>
#include <iostream>
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
  const char hi[3] = "hi";
  write(m_clientFd, hi, 3);
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

void IPC::serverAccept() {
  int client = accept(m_serverFd, nullptr, nullptr);
  char buffer[1024];
  ssize_t bytes = ::read(client, buffer, sizeof(buffer));
  if (bytes > 0) {
    std::cout << "recieved " << bytes << "bytes" << std::endl;
  }
  const char reply[] = "Understood!";
  ::write(client, reply, sizeof(reply) - 1);
  close(client);
}

void IPC::clientWrite(unsigned char *data, size_t len) {
    std::cout << "writing " << len << "bytes" << std::endl;
  ::write(m_clientFd, reinterpret_cast<char *>(data), len);
}
void IPC::clientRead(char *buffer, size_t len) {
  ::read(m_clientFd, buffer, len);
}
