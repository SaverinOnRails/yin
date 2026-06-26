#pragma once
#include "daemon/Buffer.hpp"
#include "daemon/Daemon.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "shared/utils.hpp"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <memory>
#include <string>
#include <wayland-client-protocol.h>
class Daemon;
class Monitor {
public:
  Monitor(wl_output *output, Daemon &daemon);
  void setListener();
  void setName(const char *name);
  void createLayerSurface();
  zwlr_layer_surface_v1 *getLayerSurface();
  bool readyForPaint = false;
  u32 m_height, m_width;
  i32 m_scale;
  u32 m_fractScale;
  u32 configure_serial;
  bool needs_ack = false;
  std::string m_name;
  void createAndAttachBuffer();
  std::unique_ptr<Buffer> m_buffer;

private:
  wl_surface *m_waylandSurface;
  Daemon &m_daemon;
  zwlr_layer_surface_v1 *m_layerSurface;
  wp_fractional_scale_v1 *m_fractionalScale;
  wl_output *m_waylandOutput;
  u32 m_waylandName;
  void getBufferSize(u32 &width, u32 &height);
};
