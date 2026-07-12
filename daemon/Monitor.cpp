// MONITOR AND RENDERING
#include "daemon/Monitor.hpp"
#include "daemon/Wallpaper.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "shaders_generated.hpp"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include <EGL/egl.h>
#include <GL/gl.h>
#include <GLES2/gl2.h>
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <drm/drm_fourcc.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <wayland-client-protocol.h>
#include <wayland-egl-core.h>
#include <wayland-egl.h>

#ifdef ENABLE_CUDA
#include <cuda.h>
#endif

static void output_done(void *data, struct wl_output *wl_output) {
  auto monitor = static_cast<Monitor *>(data);
  if (monitor->getLayerSurface() == nullptr)
    monitor->createLayerSurface();
}

static void output_scale(void *data, struct wl_output *wl_output,
                         int32_t scale) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->m_scale = scale;
  monitor->onScaleChanged();
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

static void frame_done(void *data, wl_callback *callback, uint32_t) {
  auto cbData = static_cast<FrameCallbackData *>(data);
  wl_callback_destroy(callback);
  cbData->monitor->onFrame(cbData->scheduledID);
  delete cbData;
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
};

static void fract_preferred_scale(void *data, struct wp_fractional_scale_v1 *f,
                                  uint32_t scale) {
  auto monitor = static_cast<Monitor *>(data);
  monitor->m_fractScale = scale;
  // monitor->onScaleChanged();
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
  monitor->resizeEGL();
  if (monitor->m_glSetup == false) {
    monitor->setupGl();
  }
  // monitor->createAndAttachBuffer();
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

    if (m_daemon.getViewporter() != nullptr) {
      m_viewport = wp_viewporter_get_viewport(m_daemon.getViewporter(),
                                              m_waylandSurface);
    }
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

void Monitor::setBufferSize() {
  if (m_fractScale != 0 && m_daemon.getViewporter() != nullptr) {
    m_bufferWidth = (m_width * m_fractScale + 120 / 2) / 120;
    m_bufferHeight = (m_height * m_fractScale + 120 / 2) / 120;
  } else {
    m_bufferWidth = m_width * m_scale;
    m_bufferHeight = m_height * m_scale;
  }
}

// void Monitor::createAndAttachBuffer() {
//   u32 width, height = 0;
//   setBufferSize(width, height);
//   m_bufferHeight = height;
//   m_bufferWidth = width;
//   m_buffer = std::make_unique<Buffer>(height, width,
//   m_daemon.getWaylandShm());

//   wl_surface_attach(m_waylandSurface, m_buffer.get()->m_waylandBuffer, 0, 0);
//   wl_surface_damage_buffer(m_waylandSurface, 0, 0, width, height);
//   if (m_viewport) {
//     wp_viewport_set_destination(m_viewport, m_width, m_height);
//   } else {
//     wl_surface_set_buffer_scale(m_waylandSurface, m_scale);
//   }
//   wl_surface_commit(m_waylandSurface);
// }

void Monitor::resizeEGL() {
  setBufferSize();
  if (m_viewport) {
    wp_viewport_set_destination(m_viewport, m_width, m_height);
  } else {
    wl_surface_set_buffer_scale(m_waylandSurface, m_scale);
  }
  if (m_daemon.m_eglDisplay == EGL_NO_DISPLAY ||
      m_daemon.m_eglContext == EGL_NO_CONTEXT) {
    throw std::runtime_error("OpenGL renderer is not bound");
  }
  if (m_eglWindow == nullptr) {
    m_eglWindow =
        wl_egl_window_create(m_waylandSurface, static_cast<int>(m_bufferWidth),
                             static_cast<int>(m_bufferHeight));
    if (m_eglWindow == nullptr) {
      throw std::runtime_error("wl_egl_window_create failed");
    }
  } else {
    wl_egl_window_resize(m_eglWindow, static_cast<int>(m_bufferWidth),
                         static_cast<int>(m_bufferHeight), 0, 0);
  }

  if (m_eglSurface == EGL_NO_SURFACE) {
    m_eglSurface = eglCreateWindowSurface(
        m_daemon.m_eglDisplay, m_daemon.m_eglConfig,
        reinterpret_cast<EGLNativeWindowType>(m_eglWindow), nullptr);
    if (m_eglSurface == EGL_NO_SURFACE) {
      throw std::runtime_error("eglCreateWindowSurface failed");
    }
  }

  if (eglMakeCurrent(m_daemon.m_eglDisplay, m_eglSurface, m_eglSurface,
                     m_daemon.m_eglContext) != EGL_TRUE) {
    throw std::runtime_error("eglMakeCurrent failed during resize");
  }
  glViewport(0, 0, static_cast<GLsizei>(m_bufferWidth),
             static_cast<GLsizei>(m_bufferHeight));

  if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
    std::cout << eglGetError() << std::endl;
    throw std::runtime_error("eglSwapBuffers failed");
  }
}

void Monitor::render() {
  if (eglMakeCurrent(m_daemon.m_eglDisplay, m_eglSurface, m_eglSurface,
                     m_daemon.m_eglContext) != EGL_TRUE) {
    throw std::runtime_error("eglMakeCurrent failed ");
  }
  glViewport(0, 0, static_cast<GLsizei>(m_bufferWidth),
             static_cast<GLsizei>(m_bufferHeight));

  // destory old egl images, this is safe to do even if the images are null for
  // some reason
  for (int i = 0; i < 2; ++i) {
    if (m_eglImages[i] != EGL_NO_IMAGE) {
      m_daemon.eglDestroyImageKHR(m_daemon.m_eglDisplay, m_eglImages[i]);
      m_eglImages[i] = EGL_NO_IMAGE;
    }
  }

  bool startTransition = false;

  // Kickoff transition if :
  // This is the very first frame of the video/image being rendered
  // There is a previous texture to transition from
  // Transitions are enabled
  // There is no active transition
  if (m_isFirstAnimationFrame && m_hasPreviousFrame && m_useTransitions &&
      !m_transitionState) {
    startTransition = true;
    m_renderIntoTempTexture = true;
  }
  if (m_transitionState != nullptr) {
    resumeTransition();
    return;
  }

  m_isFirstAnimationFrame = false;
  if (!m_wallpaper->m_isSingleFrame && !m_wallpaper->decodeNextFrame())
    return;
  if (m_wallpaper->m_frame->format == AV_PIX_FMT_VAAPI) {
    renderVAAPI();
  } else if (m_wallpaper->m_frame->format == AV_PIX_FMT_CUDA) {
#ifdef ENABLE_CUDA
    renderCUDACopy();
#endif
  } else if (m_wallpaper->m_frame->format == AV_PIX_FMT_NV12) {
    renderSoftwareNV12();
  }

  m_hasPreviousFrame = true;
  if (startTransition) {
    startTransition = false;
    m_renderIntoTempTexture = false;
    m_transitionState = std::make_unique<TransitionState>();
  }
}

void Monitor::resumeTransition() {
  GLuint transition = m_requiredTransitionShaderProgram;
  glUseProgram(transition);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, m_textures[0]);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, m_textures[1]);
  glActiveTexture(GL_TEXTURE2);
  glBindTexture(GL_TEXTURE_2D, m_toTextures[0]);
  glActiveTexture(GL_TEXTURE3);
  glBindTexture(GL_TEXTURE_2D, m_toTextures[1]);

  glUniform1i(glGetUniformLocation(transition, "uTexY_from"), 0);
  glUniform1i(glGetUniformLocation(transition, "uTexC_from"), 1);
  glUniform1i(glGetUniformLocation(transition, "uTexY_to"), 2);
  glUniform1i(glGetUniformLocation(transition, "uTexC_to"), 3);
  glUniform1f(glGetUniformLocation(transition, "ratio"),
              (static_cast<float>(m_bufferWidth) / m_bufferHeight));

  glUniform2f(glGetUniformLocation(m_glShaderProgram, "uTexCoordScale"),
              m_lastTextCoordScaleX, m_lastTextCoordScaleY);
  auto now = std::chrono::steady_clock::now();
  float progress =
      std::chrono::duration<float>(now - m_transitionState->m_startTime) /
      m_transitionState->m_duration;
  glUniform1f(glGetUniformLocation(transition, "progress"),
              std::clamp(progress, 0.0f, 1.0f));

  glViewport(0, 0, static_cast<GLsizei>(m_bufferWidth),
             static_cast<GLsizei>(m_bufferHeight));
  m_daemon.glBindVertexArray(m_VAO);
  glClear(GL_COLOR_BUFFER_BIT);
  glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);
  if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
    std::cout << eglGetError() << std::endl;
    throw std::runtime_error("eglSwapBuffers failed");
  }
  if (progress >= 1.0f) {
    m_transitionState = nullptr;
  }
  // we have to do this or future transitions from a static image will be from a
  // stale texture since static images will stop rendering after we nullify
  // m_transitionState
  if (m_wallpaper->m_isSingleFrame) {
    render();
  }
}

void Monitor::stageNV12Buffers(u32 width, u32 height) {

  //do not reset m_textures when we are not rendering into it, or VAAPI -> Software transitions will be broken
  if (!m_renderIntoTempTexture) {
    glBindTexture(GL_TEXTURE_2D, m_textures[0]);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED,
                 GL_UNSIGNED_BYTE, nullptr);
    glBindTexture(GL_TEXTURE_2D, m_textures[1]);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RG8, width / 2, height / 2, 0, GL_RG,
                 GL_UNSIGNED_BYTE, nullptr);
  }

  glBindTexture(GL_TEXTURE_2D, m_toTextures[0]);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, width, height, 0, GL_RED,
               GL_UNSIGNED_BYTE, nullptr);
  glBindTexture(GL_TEXTURE_2D, m_toTextures[1]);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RG8, width / 2, height / 2, 0, GL_RG,
               GL_UNSIGNED_BYTE, nullptr);

  glBindTexture(GL_TEXTURE_2D, 0);
  if ((m_hostY.size() == static_cast<size_t>(width) * height) &&
      (m_hostUV.size() == static_cast<size_t>(width) * (height / 2))) {
    return;
  }
  m_hostY.resize(static_cast<size_t>(width) * height);
  m_hostUV.resize(static_cast<size_t>(width) * (height / 2));
}

void Monitor::renderSoftwareNV12() {
  auto *frame = m_wallpaper->m_frame;
  int width = frame->width;
  int height = frame->height;

  stageNV12Buffers(width, height);
  glUseProgram(m_glShaderProgram);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexY"), 0);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexC"), 1);
  glUniform2f(glGetUniformLocation(m_glShaderProgram, "uTexCoordScale"), 1.0f,
              1.0f);
  m_lastTextCoordScaleX = 1.0f;
  m_lastTextCoordScaleY = 1.0f;

  m_daemon.glBindVertexArray(m_VAO);
  // Y plane
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D,
                m_renderIntoTempTexture ? m_toTextures[0] : m_textures[0]);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, frame->linesize[0]);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED,
                  GL_UNSIGNED_BYTE, frame->data[0]);

  // UV plane
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D,
                m_renderIntoTempTexture ? m_toTextures[1] : m_textures[1]);
  glPixelStorei(GL_UNPACK_ROW_LENGTH, frame->linesize[1] / 2);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width / 2, height / 2, GL_RG,
                  GL_UNSIGNED_BYTE, frame->data[1]);

  glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);

  if (!m_renderIntoTempTexture) {
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);
    if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
      std::cout << eglGetError() << std::endl;
      throw std::runtime_error("eglSwapBuffers failed");
    }
  }
}

#ifdef ENABLE_CUDA
void Monitor::renderCUDACopy() {
  cudaNV12GLUpload(m_wallpaper->m_frame);

  glUseProgram(m_glShaderProgram);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexY"), 0);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexC"), 1);
  glUniform2f(glGetUniformLocation(m_glShaderProgram, "uTexCoordScale"), 1.0f,
              1.0f);
  m_lastTextCoordScaleX = 1.0;
  m_lastTextCoordScaleY = 1.0;
  m_daemon.glBindVertexArray(m_VAO);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, m_renderIntoTempTexture
                                   ? m_toTextures[0]
                                   : m_textures[0]); // Y -> uTexY
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, m_renderIntoTempTexture
                                   ? m_toTextures[1]
                                   : m_textures[1]); // UV -> uTexC

  if (!m_renderIntoTempTexture) {
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);

    if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
      std::cout << eglGetError() << std::endl;
      throw std::runtime_error("eglSwapBuffers failed");
    }
  }
}
void Monitor::cudaNV12GLUpload(AVFrame *frame) {
  int width = frame->width;
  int height = frame->height;
  stageNV12Buffers(width, height);
  m_wallpaper->makeCudaContextCurrent();
  {
    CUDA_MEMCPY2D copy = {};
    copy.srcMemoryType = CU_MEMORYTYPE_DEVICE;
    copy.srcDevice = reinterpret_cast<CUdeviceptr>(frame->data[0]);
    copy.srcPitch = frame->linesize[0];

    copy.dstMemoryType = CU_MEMORYTYPE_HOST;
    copy.dstHost = m_hostY.data();
    copy.dstPitch = width;

    copy.WidthInBytes = width;
    copy.Height = height;
    CUresult res = cuMemcpy2D(&copy);
    if (res != CUDA_SUCCESS) {
      const char *errName = nullptr;
      const char *errStr = nullptr;
      cuGetErrorName(res, &errName);
      cuGetErrorString(res, &errStr);
      std::cerr << "cuMemcpy2D (Y plane) failed: "
                << (errName ? errName : "unknown") << " - "
                << (errStr ? errStr : "no description") << std::endl;
      throw std::runtime_error("CUDA memcopy of Y plane failed");
    }
  }
  {
    CUDA_MEMCPY2D copy = {};
    copy.srcMemoryType = CU_MEMORYTYPE_DEVICE;
    copy.srcDevice = reinterpret_cast<CUdeviceptr>(frame->data[1]);
    copy.srcPitch = frame->linesize[1];
    copy.dstMemoryType = CU_MEMORYTYPE_HOST; // <-- fixed
    copy.dstHost = m_hostUV.data();
    copy.dstPitch = width;
    copy.WidthInBytes = width;
    copy.Height = height / 2;
    CUresult res = cuMemcpy2D(&copy);
    if (res != CUDA_SUCCESS) {
      const char *errName = nullptr;
      const char *errStr = nullptr;
      cuGetErrorName(res, &errName);
      cuGetErrorString(res, &errStr);
      std::cerr << "cuMemcpy2D (UV plane) failed: "
                << (errName ? errName : "unknown") << " - "
                << (errStr ? errStr : "no description") << std::endl;
      throw std::runtime_error("CUDA memcopy of UV plane failed");
    }
  }
  glBindTexture(GL_TEXTURE_2D,
                m_renderIntoTempTexture ? m_toTextures[0] : m_textures[0]);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RED,
                  GL_UNSIGNED_BYTE, m_hostY.data());

  glBindTexture(GL_TEXTURE_2D, m_renderIntoTempTexture == true ? m_toTextures[1]
                                                               : m_textures[1]);
  glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width / 2, height / 2, GL_RG,
                  GL_UNSIGNED_BYTE, m_hostUV.data());

  glBindTexture(GL_TEXTURE_2D, 0);
}
#endif

void Monitor::renderVAAPI() {
  VASurfaceID va_surface = (uintptr_t)m_wallpaper->m_frame->data[3];
  VADRMPRIMESurfaceDescriptor prime;
  if (vaExportSurfaceHandle(m_daemon.m_vaDisplay, va_surface,
                            VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                            VA_EXPORT_SURFACE_READ_ONLY |
                                VA_EXPORT_SURFACE_SEPARATE_LAYERS,
                            &prime) != VA_STATUS_SUCCESS) {
    std::cout << "vaExportSurfaceHandle failed";
  }
  if (prime.fourcc != VA_FOURCC_NV12) {
    std::cout << "export format check failed";
    ; // we only support NV12 here
  }
  vaSyncSurface(m_daemon.m_vaDisplay, va_surface);
  float texcoord_x1 = 1.0f, texcoord_y1 = 1.0f;
  texcoord_x1 =
      (float)((double)m_wallpaper->m_codecContext->width / (double)prime.width);
  texcoord_y1 = (float)((double)m_wallpaper->m_codecContext->height /
                        (double)prime.height);
  glUseProgram(m_glShaderProgram);
  glUniform2f(glGetUniformLocation(m_glShaderProgram, "uTexCoordScale"),
              texcoord_x1, texcoord_y1);
  m_lastTextCoordScaleX = texcoord_x1;
  m_lastTextCoordScaleY = texcoord_y1;

  for (int i = 0; i < 2; ++i) {
    static const uint32_t formats[2] = {DRM_FORMAT_R8, DRM_FORMAT_GR88};
#define LAYER i
#define PLANE 0
    if (prime.layers[i].drm_format != formats[i]) {
      throw std::runtime_error("expected DRM format check");
    }
    EGLint img_attr[] = {
        EGL_LINUX_DRM_FOURCC_EXT,
        static_cast<EGLint>(formats[i]),
        EGL_WIDTH,
        static_cast<EGLint>(prime.width / (i + 1)), // half size
        EGL_HEIGHT,
        static_cast<EGLint>(prime.height / (i + 1)), // for chroma
        EGL_DMA_BUF_PLANE0_FD_EXT,
        prime.objects[prime.layers[LAYER].object_index[PLANE]].fd,
        EGL_DMA_BUF_PLANE0_OFFSET_EXT,
        static_cast<EGLint>(prime.layers[LAYER].offset[PLANE]),
        EGL_DMA_BUF_PLANE0_PITCH_EXT,
        static_cast<EGLint>(prime.layers[LAYER].pitch[PLANE]),
        EGL_NONE};
    m_eglImages[i] =
        m_daemon.eglCreateImageKHR(m_daemon.m_eglDisplay, EGL_NO_CONTEXT,
                                   EGL_LINUX_DMA_BUF_EXT, NULL, img_attr);
    if (!m_eglImages[i]) {
      throw std::runtime_error(i ? "chroma eglCreateImageKHR"
                                 : "luma eglCreateImageKHR");
    }
    glActiveTexture(GL_TEXTURE0 + i);
    glBindTexture(GL_TEXTURE_2D, m_renderIntoTempTexture == true
                                     ? m_toTextures[i]
                                     : m_textures[i]);
    while (glGetError()) {
    }
    m_daemon.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, m_eglImages[i]);
    if (glGetError()) {
      throw std::runtime_error("glEGLImageTargetTexture2DOES");
    }
  }

  for (int i = 0; i < (int)prime.num_objects; ++i) {
    close(prime.objects[i].fd);
  }
  if (!m_renderIntoTempTexture) {
    // draw
    glClear(GL_COLOR_BUFFER_BIT);
    m_daemon.glBindVertexArray(m_VAO);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_INT, 0);

    if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
      std::cout << eglGetError() << std::endl;
      throw std::runtime_error("eglSwapBuffers failed");
    }
  }
}

std::filesystem::path Monitor::historyFile() {
  const char *home = std::getenv("HOME");
  std::filesystem::path cache_dir =
      std::filesystem::path(home) / ".cache" / "yin";
  auto filename = m_name;
  return cache_dir / filename;
}
WallpaperBindError
Monitor::setWallpaper(std::string img_path,
                      std::optional<std::string> transition) {
  // reset state
  m_wallpaper = std::make_unique<Wallpaper>();
  m_wallpaperPlaying = true;
  m_isFirstAnimationFrame = true;
  m_useTransitions = false;
  m_requiredTransitionShaderProgram = {};
  if (transition.has_value()) {
    auto trans = *transition;
    m_useTransitions = true;
    if (m_transitionShaderPrograms.contains(trans)) {
      m_requiredTransitionShaderProgram = m_transitionShaderPrograms[trans];
    } else {
      // just ignore
      m_useTransitions = false;
    }
  }
  auto error = m_wallpaper->bind(img_path, m_daemon.m_vaDisplay,
                                 m_daemon.m_hardwareAccelerationBackend);
  if (error == Success) {
    m_nextVideoFrame = std::chrono::steady_clock::now();
    m_wallpaperID++;
    // write to history file
    auto file_path = historyFile();
    std::ofstream cachefile(file_path);
    cachefile << img_path;
    cachefile.close();
    // start playback
    nextFrame();
  } else {
    m_wallpaper = nullptr;
  }
  return error;
}

void Monitor::nextFrame() {
  auto *cb = wl_surface_frame(m_waylandSurface);
  auto cbData = new FrameCallbackData{this, m_wallpaperID};
  wl_callback_add_listener(cb, &frame_listener, cbData);
  wl_surface_commit(m_waylandSurface);
}

void Monitor::onFrame(u32 scheduledID) {
  if (scheduledID != m_wallpaperID)
    return;
  auto now = std::chrono::steady_clock::now();
  auto diff = std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - m_nextVideoFrame)
                  .count();
  // incase the compositor sends us to sleep
  if (diff > 100) {
    m_nextVideoFrame = now;
  }
  if (now >= m_nextVideoFrame && m_wallpaper != nullptr) {
    m_nextVideoFrame += m_wallpaper->m_frameDuration;
    render();
  }
  // don't render again if we have a single image unless we are in a transition
  if ((m_wallpaper->m_isSingleFrame && m_transitionState == nullptr) ||
      m_wallpaperPlaying == false)
    return;
  nextFrame();
}

void Monitor::onScaleChanged() {

  if (m_waylandSurface == nullptr || m_layerSurface == nullptr)
    return;

  setBufferSize();

  if (m_viewport) {
    wp_viewport_set_destination(m_viewport, m_width, m_height);
  } else {
    wl_surface_set_buffer_scale(m_waylandSurface, m_scale);
  }

  if (m_eglWindow != nullptr) {
    wl_egl_window_resize(m_eglWindow, static_cast<int>(m_bufferWidth),
                         static_cast<int>(m_bufferHeight), 0, 0);
    if (eglMakeCurrent(m_daemon.m_eglDisplay, m_eglSurface, m_eglSurface,
                       m_daemon.m_eglContext) == EGL_TRUE) {
      glViewport(0, 0, static_cast<GLsizei>(m_bufferWidth),
                 static_cast<GLsizei>(m_bufferHeight));
    }
  }
  wl_surface_commit(m_waylandSurface);
}

void Monitor::setupGl() {
  if (eglMakeCurrent(m_daemon.m_eglDisplay, m_eglSurface, m_eglSurface,
                     m_daemon.m_eglContext) != EGL_TRUE) {
    throw std::runtime_error("eglMakeCurrent failed during resize");
  }
  glViewport(0, 0, static_cast<GLsizei>(m_bufferWidth),
             static_cast<GLsizei>(m_bufferHeight));

  // full sized rectangle
  float vertices[] = {-1.f, 1.f,  0.f, 0.f, 0.f, -1.f, -1.f, 0.f, 0.f, 1.f,
                      1.f,  -1.f, 0.f, 1.f, 1.f, 1.f,  1.f,  0.f, 1.f, 0.f};

  u32 indices[] = {0, 1, 2, 2, 3, 0};

  uint32_t VAO;
  m_daemon.glGenVertexArrays(1, &VAO);
  m_daemon.glBindVertexArray(VAO);
  m_VAO = VAO;

  u32 VBO;
  glGenBuffers(1, &VBO);
  glBindBuffer(GL_ARRAY_BUFFER, VBO);
  glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);

  u32 EBO;
  glGenBuffers(1, &EBO);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, EBO);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices,
               GL_STATIC_DRAW);

  u32 vertexShader;
  vertexShader = glCreateShader(GL_VERTEX_SHADER);
  glShaderSource(vertexShader, 1, &vertexShaderSourceMain, NULL);
  glCompileShader(vertexShader);
  {

    GLint success;
    char infoLog[512];

    glGetShaderiv(vertexShader, GL_COMPILE_STATUS, &success);
    if (!success) {
      glGetShaderInfoLog(vertexShader, 512, nullptr, infoLog);
      std::cout << infoLog << std::endl;
    }
  }
  u32 fragmentShader;
  fragmentShader = glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(fragmentShader, 1, &fragmentShaderSourceMain, NULL);
  glCompileShader(fragmentShader);
  {
    GLint success;
    char infoLog[512];

    glGetShaderiv(fragmentShader, GL_COMPILE_STATUS, &success);
    if (!success) {
      glGetShaderInfoLog(fragmentShader, 512, nullptr, infoLog);
      std::cout << infoLog << std::endl;
    }
  }
  m_glShaderProgram = glCreateProgram();
  glAttachShader(m_glShaderProgram, vertexShader);
  glAttachShader(m_glShaderProgram, fragmentShader);
  glLinkProgram(m_glShaderProgram);

  compileTransitionShaders(vertexShader);
  glDeleteShader(vertexShader);
  glDeleteShader(fragmentShader);

  glUseProgram(m_glShaderProgram);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexY"), 0);
  glUniform1i(glGetUniformLocation(m_glShaderProgram, "uTexC"), 1);

  glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 5 * sizeof(float), (void *)0);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 5 * sizeof(float),
                        (void *)(3 * sizeof(float)));
  glEnableVertexAttribArray(1);

  // texture
  glGenTextures(2, m_textures);
  glGenTextures(2, m_toTextures);
  for (int i = 0; i < 2; ++i) {
    glBindTexture(GL_TEXTURE_2D, m_textures[i]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);

    glBindTexture(GL_TEXTURE_2D, m_toTextures[i]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  }
  glBindTexture(GL_TEXTURE_2D, 0);

  m_glSetup = true;
}

// TODO compiling transition shaders for every monitor is probably very
// inefficient
void Monitor::compileTransitionShaders(u32 vertexShader) {
  for (const auto &[key, value] : transitionSourceMap) {
    u32 shader;
    shader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(shader, 1, &value, NULL);
    glCompileShader(shader);
    {
      GLint success;
      char infoLog[512];
      glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
      if (!success) {
        glGetShaderInfoLog(shader, 512, nullptr, infoLog);
        std::cout << "Problem compiling shader " << key << std::endl;
        std::cout << infoLog << std::endl;
      }
    }
    auto shaderProgram = glCreateProgram();
    glAttachShader(shaderProgram, vertexShader);
    glAttachShader(shaderProgram, shader);
    glLinkProgram(shaderProgram);
    m_transitionShaderPrograms[key] = shaderProgram;
    glDeleteShader(shader);
  }
}

void Monitor::setPlayPause(bool play) {
  if (play && !m_wallpaperPlaying) {
    m_nextVideoFrame =
        std::chrono::steady_clock::now() + m_wallpaper->m_frameDuration;
    nextFrame();
  }
  m_wallpaperPlaying = play;
}
WallpaperBindError Monitor::restoreWallpaper() {
  auto history_file = historyFile();
  if (!std::filesystem::exists(history_file)) {
    return NoHistory;
  }
  std::ifstream file(history_file);
  if (file.is_open()) {
    std::string first_line;
    if (!std::getline(file, first_line))
      return NoHistory;
    if (!std::filesystem::exists(first_line))
      return BadVideo;
    return setWallpaper(first_line, std::nullopt);
  }
  return NoHistory;
}
