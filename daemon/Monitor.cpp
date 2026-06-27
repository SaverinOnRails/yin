#include "daemon/Monitor.hpp"
#include "daemon/Buffer.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <cassert>
#include <memory>
#include <stdexcept>
#include <wayland-client-protocol.h>

static void output_done(void *data, struct wl_output *wl_output) {
  auto monitor = static_cast<Monitor *>(data);
  if (monitor->getLayerSurface() == nullptr)
    monitor->createLayerSurface();
}

static void output_scale(void *data, struct wl_output *wl_output,
                         int32_t scale) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->m_scale = scale;
}

static void output_name(void *data, struct wl_output *wl_output,
                        const char *name) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->setName(name);
}

static void output_description(void *data, struct wl_output *wl_output,
                               const char *description) {}

static void output_geometry(void *data, struct wl_output *output, int32_t x,
                            int32_t y, int32_t width_mm, int32_t height_mm,
                            int32_t subpixel, const char *make,
                            const char *model, int32_t transform) {}

static void output_mode(void *data, struct wl_output *output, uint32_t flags,
                        int32_t width, int32_t height, int32_t refresh) {}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .done = output_done,
    .scale = output_scale,
    .name = output_name,
    .description = output_description,
};

static void fract_preferred_scale(void *data, struct wp_fractional_scale_v1 *f,
                                  uint32_t scale) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->m_fractScale = scale;
}

static const struct wp_fractional_scale_v1_listener fract_scale_listener = {
    .preferred_scale = fract_preferred_scale};

static void layer_surface_configure(void *data,
                                    struct zwlr_layer_surface_v1 *surface,
                                    uint32_t serial, uint32_t width,
                                    uint32_t height) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->m_height = height;
  monitor->m_width = width;
  zwlr_layer_surface_v1_ack_configure(monitor->getLayerSurface(), serial);
  monitor->createAndAttachBuffer();
}

static void layer_surface_closed(void *data,
                                 struct zwlr_layer_surface_v1 *surface) {}
Monitor::Monitor(wl_output *output, Daemon &daemon)
    : m_daemon(daemon), m_waylandOutput(output) {
  setListener();
}
static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
    .configure = layer_surface_configure,
    .closed = layer_surface_closed,
};

void Monitor::setListener() {
  if (m_waylandOutput == nullptr)
    throw std::runtime_error("Output was null, this should not happen");
  wl_output_add_listener(m_waylandOutput, &output_listener, this);
}

void Monitor::setName(const char *name) { m_name = name; }
zwlr_layer_surface_v1 *Monitor::getLayerSurface() { return m_layerSurface; }

void Monitor::createLayerSurface() {
  m_waylandSurface = wl_compositor_create_surface(m_daemon.getCompositor());
  assert(m_waylandSurface);
  auto input_region = wl_compositor_create_region(m_daemon.getCompositor());
  assert(input_region);
  wl_surface_set_input_region(m_waylandSurface, input_region);
  wl_region_destroy(input_region);

  if (m_daemon.hasFractionScaleManager()) {
    m_fractionalScale = wp_fractional_scale_manager_v1_get_fractional_scale(
        m_daemon.getFractionalScaleManager(), m_waylandSurface);
    wp_fractional_scale_v1_add_listener(m_fractionalScale,
                                        &fract_scale_listener, this);
  }
  m_layerSurface = zwlr_layer_shell_v1_get_layer_surface(
      m_daemon.getLayerShell(), m_waylandSurface, m_waylandOutput,
      ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, "yin-wallpaper");
  zwlr_layer_surface_v1_set_size(m_layerSurface, 0, 0);
  zwlr_layer_surface_v1_set_anchor(m_layerSurface,
                                   ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                       ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT);
  zwlr_layer_surface_v1_set_exclusive_zone(m_layerSurface, -1);

  zwlr_layer_surface_v1_add_listener(m_layerSurface, &layer_surface_listener,
                                     this);
  wl_surface_commit(m_waylandSurface);
}

void Monitor::getBufferSize(u32 &width, u32 &height) {
  if (m_fractScale != 0) {
    width = (m_width * m_fractScale + 120 / 2) / 120;
    height = (m_height * m_fractScale + 120 / 2) / 120;
  } else {
    width = width * m_scale;
    height = height * m_scale;
  }
}

void Monitor::createAndAttachBuffer() {
  if (m_buffer == nullptr) {
    u32 width, height = 0;
    getBufferSize(width, height);
    m_buffer =
        std::make_unique<Buffer>(height, width, m_daemon.getWaylandShm());
    wl_surface_attach(m_waylandSurface, m_buffer.get()->m_waylandBuffer, 0, 0);
    wl_surface_commit(m_waylandSurface);
  }
}
