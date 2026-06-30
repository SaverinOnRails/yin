#pragma once
#include "daemon/Monitor.hpp"
#include <EGL/egl.h>
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <memory>
#include <vector>
#include <wayland-client-protocol.h>
#include <wayland-client.h>

class Monitor;
class Daemon {
public:
  Daemon();
  ~Daemon();
  void bindGlobal(struct wl_registry *registry, uint32_t name,
                  const char *interface, uint32_t version);
  void run();
  wl_compositor *getCompositor();
  wp_fractional_scale_manager_v1 *getFractionalScaleManager();
  // wl_shm *getWaylandShm();
  wl_display *m_waylandDisplay;
  zwlr_layer_shell_v1 *getLayerShell();
  wp_viewporter *getViewporter() { return m_waylandViewporter; }
  bool hasFractionScaleManager();
  void createEGL();
  EGLDisplay m_eglDisplay = EGL_NO_DISPLAY;
  EGLConfig m_eglConfig = nullptr;
  EGLContext m_eglContext = EGL_NO_CONTEXT;
  std::vector<std::unique_ptr<Monitor>> m_monitors;

private:
  wl_compositor *m_waylandCompositor;
  // wl_shm *m_waylandSharedMemory;
  wp_viewporter *m_waylandViewporter;
  zwlr_layer_shell_v1 *m_layerShell;
  wp_fractional_scale_manager_v1 *m_fractionalScaleManager;
  void initWayland();
  void ensureGlobals();
};
