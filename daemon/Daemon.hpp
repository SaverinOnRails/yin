#pragma once
#include "daemon/Monitor.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <memory>
#include <va/va.h>
#include <vector>
#include <wayland-client-protocol.h>
#include <wayland-client.h>

class Monitor;
class Daemon {
public:
  Daemon(HardwareAccelerationBackend hab);
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
  VADisplay m_vaDisplay = nullptr;
  PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR = nullptr;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES = nullptr;
  PFNGLGENVERTEXARRAYSPROC glGenVertexArrays = nullptr;
  PFNGLBINDVERTEXARRAYPROC glBindVertexArray = nullptr;
  HardwareAccelerationBackend m_hardwareAccelerationBackend = Vaapi;

private:
  wl_compositor *m_waylandCompositor;
  // wl_shm *m_waylandSharedMemory; we dont need this anymore for now
  wp_viewporter *m_waylandViewporter;
  zwlr_layer_shell_v1 *m_layerShell;
  wp_fractional_scale_manager_v1 *m_fractionalScaleManager;
  void initWayland();
  void ensureGlobals();
};
