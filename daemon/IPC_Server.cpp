#include "shared/IPC.hpp"
#include "daemon/Monitor.hpp"
#include "daemon/Wallpaper.hpp"
#include "shared/utils.hpp"
#include <cstring>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <variant>

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
  char bad_video_message[] =
      "Problem with video file, please delete ~/cache/yin and try again";
  char no_hardware_decoding[] =
      "Hardware decoding is unavailable, cannot proceed"; // maybe we can,
                                                          // we'll find out
  char no_history[] = "No wallpaper previously set on this monitor";
  char success_message[] = "Img sent to daemon!";
  if (bytes > 0) {
    auto message = DeserializeMessage(buffer, bytes);
    if (std::holds_alternative<MonitorSizeMessage>(message)) {
      auto mes = std::get<MonitorSizeMessage>(message);

      if (auto *monitor = daemonFindMonitor(daemon, mes.monitor)) {
        std::string dimensions = std::to_string(monitor->m_bufferWidth) + "x" +
                                 std::to_string(monitor->m_bufferHeight);

        write(client, dimensions.data(), dimensions.size());
      }
    } else if (std::holds_alternative<SetWallpaperMessage>(message)) {
      auto mes = std::get<SetWallpaperMessage>(message);

      auto monitor = daemonFindMonitor(daemon, mes.monitor);
      auto error = monitor->setWallpaper(mes.imgPath);

      if (error == BadVideo) {
        write(client, bad_video_message, std::strlen(bad_video_message));
      }
      if (error == NoHarwareDecoding) {
        write(client, no_hardware_decoding, std::strlen(no_hardware_decoding));
      }
      if (error == Success) {
        write(client, success_message, std::strlen(success_message));
      }
    } else if (std::holds_alternative<PlayPauseMessage>(message)) {
      auto mes = std::get<PlayPauseMessage>(message);
      auto monitor = daemonFindMonitor(daemon, mes.monitor);
      monitor->setPlayPause(mes.play);
    } else if (std::holds_alternative<RestoreMessage>(message)) {
      auto mes = std::get<RestoreMessage>(message);
      auto monitor = daemonFindMonitor(daemon, mes.monitor);
      auto error = monitor->restoreWallpaper();
      if (error == BadVideo) {
        write(client, bad_video_message, std::strlen(bad_video_message));
      }
      if (error == NoHarwareDecoding) {
        write(client, no_hardware_decoding, std::strlen(no_hardware_decoding));
      }
      if (error == Success) {
        write(client, success_message, std::strlen(success_message));
      }
      if (error == NoHistory) {
        write(client, no_history, std::strlen(no_history));
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
