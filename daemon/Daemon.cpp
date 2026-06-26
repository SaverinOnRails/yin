#include "Daemon.hpp"
#include "daemon/Monitor.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <cstring>
#include <memory>
#include <stdexcept>
#include <wayland-client-core.h>
#include <wayland-client-protocol.h>
Daemon::Daemon() { initWayland(); }
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
  m_waylandDisplay = wl_display_connect(nullptr);
  if (m_waylandDisplay == nullptr) {
    throw std::runtime_error("Could not connect to a Wayland Compositor");
  }
  auto wl_registry = wl_display_get_registry(m_waylandDisplay);
  wl_registry_add_listener(wl_registry, &registry_listener, this);
  if (wl_display_roundtrip(m_waylandDisplay) < 0) {
    throw std::runtime_error("Failed to roundtrip wayland display");
  }
  ensureGlobals();
}

void Daemon::bindGlobal(struct wl_registry *registry, uint32_t name,
                        const char *interface, uint32_t version) {
  if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
    m_waylandCompositor = static_cast<wl_compositor *>(
        wl_registry_bind(registry, name, &wl_compositor_interface, 4));
  }
  if (std::strcmp(interface, wl_shm_interface.name) == 0) {
    m_waylandSharedMemory = static_cast<wl_shm *>(
        wl_registry_bind(registry, name, &wl_shm_interface, 1));
  }
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
}

void Daemon::ensureGlobals() {
  if (!m_layerShell || !m_waylandCompositor || !m_waylandSharedMemory)
    throw std::runtime_error(
        "Compositor does not implement required protocols");
}

void Daemon::run() {
  while (wl_display_dispatch(m_waylandDisplay) != -1) {
  }
}

wl_compositor *Daemon::getCompositor() { return m_waylandCompositor; }
bool Daemon::hasFractionScaleManager() {
  return m_fractionalScaleManager != nullptr;
}

wp_fractional_scale_manager_v1 *Daemon::getFractionalScaleManager() {
  return m_fractionalScaleManager;
}

wl_shm *Daemon::getWaylandShm() { return m_waylandSharedMemory; }
zwlr_layer_shell_v1 *Daemon::getLayerShell() { return m_layerShell; }
