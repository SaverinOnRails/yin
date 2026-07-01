#include "daemon/Monitor.hpp"
#include "daemon/Wallpaper.hpp"
#include "fractional-scale-v1-client-protocol.h"
#include "wlr-layer-shell-unstable-v1-client-protocol.h"
#include "yinctl.p/viewporter-client-protocol.h"
#include <EGL/egl.h>
#include <GL/gl.h>
#include <cassert>
#include <cstdint>
#include <drm/drm_fourcc.h>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <wayland-client-protocol.h>
#include <wayland-egl-core.h>
#include <wayland-egl.h>

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

static void frame_done(void *data, wl_callback *callback, uint32_t) {
  auto *monitor = static_cast<Monitor *>(data);
  wl_callback_destroy(callback);
  monitor->onFrame();
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
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
  monitor->resizeEGL();
  monitor->setupGlShaders();
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
  if (!m_wallpaper->decodeNextFrame())
    return;
  std::cout << "Attempting to render" << std::endl;
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
  bool texture_size_valid = false;
  if (!texture_size_valid) {
    texcoord_x1 = (float)((double)m_wallpaper->m_codecContext->width /
                          (double)prime.width);
    texcoord_y1 = (float)((double)m_wallpaper->m_codecContext->height /
                          (double)prime.height);
    texture_size_valid = true;
  }
  EGLImage images[2];
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
    images[i] =
        m_daemon.eglCreateImageKHR(m_daemon.m_eglDisplay, EGL_NO_CONTEXT,
                                   EGL_LINUX_DMA_BUF_EXT, NULL, img_attr);
    if (!images[i]) {
      throw std::runtime_error(i ? "chroma eglCreateImageKHR"
                                 : "luma eglCreateImageKHR");
    }
    glActiveTexture(GL_TEXTURE0 + i);
    glBindTexture(GL_TEXTURE_2D, m_textures[i]);
    while (glGetError()) {
    }
    m_daemon.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, images[i]);
    if (glGetError()) {
      throw std::runtime_error("glEGLImageTargetTexture2DOES");
    }
  }

  // draw the frame
  glClear(GL_COLOR_BUFFER_BIT);
  while (glGetError()) {
  }
  glActiveTexture(GL_TEXTURE0);
  glBegin(GL_QUADS);
  glTexCoord2f(0.0f, 0.0f);
  glVertex2i(0, 0);
  glTexCoord2f(texcoord_x1, 0.0f);
  glVertex2i(1, 0);
  glTexCoord2f(texcoord_x1, texcoord_y1);
  glVertex2i(1, 1);
  glTexCoord2f(0.0f, texcoord_y1);
  glVertex2i(0, 1);
  glEnd();
  if (glGetError()) {
    throw std::runtime_error("drawing");
  }
  if (eglSwapBuffers(m_daemon.m_eglDisplay, m_eglSurface) != EGL_TRUE) {
    std::cout << eglGetError() << std::endl;
    throw std::runtime_error("eglSwapBuffers failed");
  }
}

WallpaperBindError Monitor::setWallpaper(std::string img_path) {
  m_wallpaper = std::make_unique<Wallpaper>();
  auto error = m_wallpaper->bind(img_path, m_daemon.m_vaDisplay);
  if (error == Success) {
    m_nextVideoFrame = std::chrono::steady_clock::now();
    // start playback
    nextFrame();
  } else {
    m_wallpaper = nullptr;
  }
  return error;
}

void Monitor::nextFrame() {
  auto *cb = wl_surface_frame(m_waylandSurface);
  wl_callback_add_listener(cb, &frame_listener, this);
  wl_surface_commit(m_waylandSurface);
}

void Monitor::onFrame() {
  auto now = std::chrono::steady_clock::now();
  if (now >= m_nextVideoFrame && m_wallpaper != nullptr) {
    m_nextVideoFrame += m_wallpaper->m_frameDuration;
    render();
  }
  nextFrame();
}

// https://gist.github.com/kajott/d1b29c613be30893c855621edd1f212e

#define DECLARE_YUV2RGB_MATRIX_GLSL                                            \
  "const mat4 yuv2rgb = mat4(\n"                                               \
  "    vec4(  1.1644,  1.1644,  1.1644,  0.0000 ),\n"                          \
  "    vec4(  0.0000, -0.2132,  2.1124,  0.0000 ),\n"                          \
  "    vec4(  1.7927, -0.5329,  0.0000,  0.0000 ),\n"                          \
  "    vec4( -0.9729,  0.3015, -1.1334,  1.0000 ));"

void Monitor::setupGlShaders() {
  std::cout << "Setting up gl shaders" << std::endl;
  if (eglMakeCurrent(m_daemon.m_eglDisplay, m_eglSurface, m_eglSurface,
                     m_daemon.m_eglContext) != EGL_TRUE) {
    throw std::runtime_error("eglMakeCurrent failed during resize");
  }
  // glOrtho(0.0, 1.0, 1.0, 0.0, -1.0, 1.0);
  const char *vs_src = "void main() {"
                       "\n"
                       "    gl_Position = ftransform();"
                       "\n"
                       "    gl_TexCoord[0] = gl_MultiTexCoord0;"
                       "\n"
                       "}";
  const char *fs_src = "uniform sampler2D uTexY, uTexC;"
                       "\n" DECLARE_YUV2RGB_MATRIX_GLSL "\n"
                       "void main() {"
                       "\n"
                       "    gl_FragColor = yuv2rgb * vec4(texture2D(uTexY, "
                       "gl_TexCoord[0].xy).x, "
                       "texture2D(uTexC, gl_TexCoord[0].xy).xy, 1.);"
                       "\n"
                       "}";
  GLuint prog = glCreateProgram();
  GLuint vs = glCreateShader(GL_VERTEX_SHADER);
  GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
  if (!prog) {
    throw std::runtime_error("glCreateProgram failed");
  }
  if (!vs || !fs) {
    throw std::runtime_error("glCreateShader");
  }
  glShaderSource(vs, 1, &vs_src, NULL);
  glShaderSource(fs, 1, &fs_src, NULL);
  GLint ok;
  while (glGetError()) {
  }
  glCompileShader(vs);
  glGetShaderiv(vs, GL_COMPILE_STATUS, &ok);
  if (glGetError() || (ok != GL_TRUE)) {
    throw std::runtime_error("glCompileShader(GL_VERTEX_SHADER)");
  }
  glCompileShader(fs);
  glGetShaderiv(fs, GL_COMPILE_STATUS, &ok);
  if (glGetError() || (ok != GL_TRUE)) {
    throw std::runtime_error("glCompileShader(GL_FRAGMENT_SHADER)");
  }
  glAttachShader(prog, vs);
  glAttachShader(prog, fs);
  glLinkProgram(prog);
  if (glGetError()) {
    throw std::runtime_error("glLinkProgram");
  }
  glUseProgram(prog);
  glUniform1i(glGetUniformLocation(prog, "uTexY"), 0);
  glUniform1i(glGetUniformLocation(prog, "uTexC"), 1);

  // OpenGL texture setup
  glGenTextures(2, m_textures);
  for (int i = 0; i < 2; ++i) {
    glBindTexture(GL_TEXTURE_2D, m_textures[i]);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  }
  glBindTexture(GL_TEXTURE_2D, 0);

  // initial window size setup
  GLint vp[4];
  glGetIntegerv(GL_VIEWPORT, vp);
}
