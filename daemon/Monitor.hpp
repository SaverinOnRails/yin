#pragma once
#include "daemon/Buffer.hpp"
#include "daemon/Daemon.hpp"
#include "daemon/Wallpaper.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "shared/utils.hpp"
#include "viewporter-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <EGL/egl.h>
#include <GL/gl.h>
#include <GLES2/gl2.h>
#include <chrono>
#include <filesystem>
#include <memory>
#include <string>
#include <wayland-client-protocol.h>
#include <wayland-egl-core.h>
#include <wayland-egl.h>

struct TransitionState {
  std::chrono::steady_clock::time_point m_startTime =
      std::chrono::steady_clock::now();
  std::chrono::milliseconds m_duration = std::chrono::seconds(3);
};

class Monitor {
public:
  Monitor(wl_output *output, Daemon &daemon);
  void setListener();
  void setName(const char *name);
  void createLayerSurface();
  zwlr_layer_surface_v1 *getLayerSurface();
  u32 m_height, m_width;
  u32 m_bufferHeight, m_bufferWidth;
  i32 m_scale = 0;
  u32 m_fractScale = 0;
  u32 configure_serial;
  std::string m_name;
  void resizeEGL();
  void createAndAttachBuffer();
  std::chrono::steady_clock::time_point m_nextVideoFrame;
  std::unique_ptr<Buffer> m_buffer;
  WallpaperBindError setWallpaper(std::string img_path);
  WallpaperBindError restoreWallpaper();
  void setupGl();
  void onFrame(u32 scheduledID);
  void onScaleChanged();
  bool m_glSetup = false;
  void setPlayPause(bool play);
  u32 m_wallpaperID = 0;

private:
  wl_surface *m_waylandSurface = nullptr;
  Daemon &m_daemon;
  zwlr_layer_surface_v1 *m_layerSurface = nullptr;
  wp_fractional_scale_v1 *m_fractionalScale = nullptr;
  wp_viewport *m_viewport =  nullptr;
  wl_output *m_waylandOutput = nullptr;
  u32 m_waylandName;
  wl_egl_window *m_eglWindow =  nullptr;
  EGLSurface m_eglSurface = EGL_NO_SURFACE;
  std::unique_ptr<Wallpaper> m_wallpaper = nullptr;
  void nextFrame();
  bool m_wallpaperPlaying = true; // this just means not paused
  void setBufferSize();
  std::filesystem::path historyFile();
  void cudaNV12GLUpload(AVFrame *frame);
  void stageNV12Buffers(u32 width, u32 height);


  // GL STATE
  GLuint m_textures[2]{}; //current display texture
  GLuint m_toTextures[2]{}; // textures we are transitioning to
  GLuint m_fromTextures[2]{}; //textures we are tranisition from
  EGLImage m_eglImages[2]{}; //this is used for VAAPI ONLY
  u32 m_VAO;
  GLuint m_glShaderProgram;
  void render();
  void renderVAAPI();
  void renderCUDACopy();
  void renderSoftwareNV12();
  void continueTransition();

  // Transition state
  bool m_isFirstAnimationFrame = false;
  bool m_hasPreviousFrame = false;
  bool m_renderIntoTempTexture = false;
  bool useTransitions = true;
  std::unique_ptr<TransitionState> m_transitionState = nullptr;
  // software data for cuda and generic nv12 frames
  std::vector<uint8_t> m_hostY;
  std::vector<uint8_t> m_hostUV;
};

struct FrameCallbackData {
  Monitor *monitor;
  uint64_t scheduledID;
};
