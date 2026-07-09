#include "Daemon.hpp"
#include "../shared/IPC.hpp"
#include "daemon/Monitor.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "shared/utils.hpp"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <EGL/egl.h>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <poll.h>
#include <stdexcept>
#include <sys/poll.h>
#include <va/va_wayland.h>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>
Daemon::Daemon(HardwareAccelerationBackend hab)
    : m_hardwareAccelerationBackend(hab) {
  initWayland();
}
Daemon::~Daemon() {}

static void handle_global(void *data, struct wl_registry *registry,
                          uint32_t name, const char *interface,
                          uint32_t version) {
  auto daemon = static_cast<Daemon *>(data);
  daemon->bindGlobal(registry, name, interface, version);
}

static void handle_global_remove(void *data, struct wl_registry *registry,
                                 uint32_t name) {}

static const struct wl_registry_listener registry_listener = {
    .global = handle_global,
    .global_remove = handle_global_remove,
};

void Daemon::initWayland() {
  m_waylandDisplay = wl_display_connect(NULL);
  if (m_waylandDisplay == nullptr) {
    throw std::runtime_error("Could not connect to a Wayland Compositor");
  }
  createEGL();
  if (m_hardwareAccelerationBackend == Vaapi) {
    m_vaDisplay = vaGetDisplayWl(m_waylandDisplay);
    assert(m_vaDisplay != nullptr);
  }
  int major, minor;
  auto wl_registry = wl_display_get_registry(m_waylandDisplay);
  wl_registry_add_listener(wl_registry, &registry_listener, this);
  if (wl_display_roundtrip(m_waylandDisplay) < 0) {
    throw std::runtime_error("Failed to roundtrip wayland display");
  }
  if (m_hardwareAccelerationBackend == Vaapi) {
    if (vaInitialize(m_vaDisplay, &major, &minor) != VA_STATUS_SUCCESS) {
      throw std::runtime_error("Failed to init VA display");
    }
  }
  ensureGlobals();
}

void Daemon::bindGlobal(struct wl_registry *registry, uint32_t name,
                        const char *interface, uint32_t version) {
  if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
    m_waylandCompositor = static_cast<wl_compositor *>(
        wl_registry_bind(registry, name, &wl_compositor_interface, 4));
  }
  // if (std::strcmp(interface, wl_shm_interface.name) == 0) {
  //   m_waylandSharedMemory = static_cast<wl_shm *>(
  //       wl_registry_bind(registry, name, &wl_shm_interface, 1));
  // }
  if (std::strcmp(interface, zwlr_layer_shell_v1_interface.name) == 0) {
    m_layerShell = static_cast<zwlr_layer_shell_v1 *>(
        wl_registry_bind(registry, name, &zwlr_layer_shell_v1_interface, 1));
  }
  if (std::strcmp(interface, wl_output_interface.name) == 0) {
    auto wl_output = static_cast<struct wl_output *>(
        wl_registry_bind(registry, name, &wl_output_interface, 4));
    auto monitor = std::make_unique<Monitor>(wl_output, *this);
    m_monitors.push_back(std::move(monitor));
  }
  if (std::strcmp(interface, wp_fractional_scale_manager_v1_interface.name) ==
      0) {
    m_fractionalScaleManager =
        static_cast<wp_fractional_scale_manager_v1 *>(wl_registry_bind(
            registry, name, &wp_fractional_scale_manager_v1_interface, 1));
  }
  if (std::strcmp(interface, wp_viewporter_interface.name) == 0) {
    m_waylandViewporter = static_cast<wp_viewporter *>(
        wl_registry_bind(registry, name, &wp_viewporter_interface, 1));
  }
}

void Daemon::ensureGlobals() {
  if (!m_layerShell || !m_waylandCompositor)
    throw std::runtime_error(
        "Compositor does not implement required protocols");
}

void Daemon::run() {
  auto ipc = IPC{};
  ipc.serverCreate();
  int wl_fd = wl_display_get_fd(m_waylandDisplay);
  struct pollfd fds[2];
  fds[0].fd = wl_fd;
  fds[0].events = POLLIN;

  fds[1].fd = ipc.m_serverFd;
  fds[1].events = POLLIN;
  while (true) {
    {
      wl_display_flush(m_waylandDisplay);
    }
    int _ = poll(fds, 2, -1);
    if ((fds[0].revents & POLLIN) != 0) {
      wl_display_dispatch(m_waylandDisplay);
    }
    if ((fds[1].revents & POLLIN) != 0) {
      ipc.serverAccept(*this);
    }
  }
}

wl_compositor *Daemon::getCompositor() { return m_waylandCompositor; }
bool Daemon::hasFractionScaleManager() {
  return m_fractionalScaleManager != nullptr;
}

wp_fractional_scale_manager_v1 *Daemon::getFractionalScaleManager() {
  return m_fractionalScaleManager;
}

// wl_shm *Daemon::getWaylandShm() { return m_waylandSharedMemory; }
zwlr_layer_shell_v1 *Daemon::getLayerShell() { return m_layerShell; }

void Daemon::createEGL() {
  m_eglDisplay =
      eglGetDisplay(reinterpret_cast<EGLNativeDisplayType>(m_waylandDisplay));
  if (m_eglDisplay == EGL_NO_DISPLAY) {
    throw std::runtime_error("eglGetDisplay failed");
  }

  EGLint major = 0;
  EGLint minor = 0;
  if (eglInitialize(m_eglDisplay, &major, &minor) != EGL_TRUE) {
    throw std::runtime_error("eglInitialize failed");
  }

  if (eglBindAPI(EGL_OPENGL_API) != EGL_TRUE) {
    throw std::runtime_error("eglBindAPI failed");
  }

  constexpr EGLint kConfigAttributes[] = {
      EGL_SURFACE_TYPE,
      EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE,
      EGL_OPENGL_ES2_BIT,
      EGL_RED_SIZE,
      8,
      EGL_GREEN_SIZE,
      8,
      EGL_BLUE_SIZE,
      8,
      EGL_ALPHA_SIZE,
      0,
      EGL_NONE,
  };

  constexpr EGLint kContextAttributes[] = {
      EGL_CONTEXT_CLIENT_VERSION,
      2,
      EGL_NONE,
  };
  EGLint configCount = 0;
  if (eglChooseConfig(m_eglDisplay, kConfigAttributes, &m_eglConfig, 1,
                      &configCount) != EGL_TRUE ||
      configCount != 1) {
    throw std::runtime_error("eglChooseConfig failed");
  }

  m_eglContext = eglCreateContext(m_eglDisplay, m_eglConfig, EGL_NO_CONTEXT,
                                  kContextAttributes);
  if (m_eglContext == EGL_NO_CONTEXT) {
    throw std::runtime_error("eglCreateContext failed");
  }

  // locate gl procs
  eglCreateImageKHR = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  eglDestroyImageKHR = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  glEGLImageTargetTexture2DOES =
      reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
          eglGetProcAddress("glEGLImageTargetTexture2DOES"));
  glGenVertexArrays = reinterpret_cast<PFNGLGENVERTEXARRAYSPROC>(
      eglGetProcAddress("glGenVertexArrays"));
  glBindVertexArray = reinterpret_cast<PFNGLBINDVERTEXARRAYPROC>(
      eglGetProcAddress("glBindVertexArray"));

  if (!eglCreateImageKHR || !eglDestroyImageKHR ||
      !glEGLImageTargetTexture2DOES || !glBindVertexArray ||
      !glGenVertexArrays) {
    throw std::runtime_error("Missing GL procs");
  }
}
