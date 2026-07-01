#pragma once
#include "daemon/Monitor.hpp"
#include <cstddef>
#include <optional>
#include <string>
class Daemon;
class Monitor;
class IPC {
public:
  void clientConnect();
  void serverCreate();
  void serverAccept(Daemon &daemon);
  void clientWrite(unsigned char *data, size_t len);
  size_t clientRead(char *buffer, size_t len);
  Monitor *daemonFindMonitor(Daemon &daemon,
                             const std::optional<std::string> &monitorName);
  int m_serverFd;
  int m_clientFd;
};
