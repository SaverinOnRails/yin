#include "daemon/Wallpaper.hpp"
#include <chrono>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>

#ifdef ENABLE_CUDA
#include <libavutil/hwcontext_cuda.h>
#endif

#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/pixfmt.h>
#include <libavutil/rational.h>
#include <va/va.h>

static AVPixelFormat HWDEC_PIXEL_FORMAT = AV_PIX_FMT_VAAPI;
static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
  // for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
  //   if (*p == AV_PIX_FMT_VAAPI)
  //     return *p;
  // }
  return HWDEC_PIXEL_FORMAT;
}

WallpaperBindError Wallpaper::bind(std::string_view path, VADisplay va_display,
                                   HardwareAccelerationBackend backend) {
  if (backend == Vaapi) {
    HWDEC_PIXEL_FORMAT = AV_PIX_FMT_VAAPI;
  } else if (backend == CudaCopy) {
    HWDEC_PIXEL_FORMAT = AV_PIX_FMT_CUDA;
  } else {
  }
  if (avformat_open_input(&m_formatContext, path.data(), nullptr, nullptr) < 0)
    return BadVideo;

  if (avformat_find_stream_info(m_formatContext, nullptr) < 0)
    return BadVideo;

  m_videoStream = av_find_best_stream(m_formatContext, AVMEDIA_TYPE_VIDEO, -1,
                                      -1, &m_codec, 0);

  // check if this is a static image that won't be decoded on GPU

  if (m_videoStream < 0)
    return BadVideo;

  m_codecContext = avcodec_alloc_context3(m_codec);
  if (!m_codecContext)
    return BadVideo;

  if (avcodec_parameters_to_context(
          m_codecContext, m_formatContext->streams[m_videoStream]->codecpar) <
      0)
    return BadVideo;
  double fps = av_q2d(m_formatContext->streams[m_videoStream]->avg_frame_rate);
  if (fps <= 0.0)
    fps = 30.0;

  m_frameDuration =
      std::chrono::milliseconds(static_cast<int64_t>(1000.0 / fps));
  int64_t frameCount = m_formatContext->streams[m_videoStream]->nb_frames;

  // check if is static image that won't be decoded on GPU
  if (frameCount == 1 || frameCount == 0) {
    m_isSingleFrame = true;
  }

  // Allocate hardware device context
  if (backend == Vaapi) {
    m_hwDeviceContext = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VAAPI);
    if (!m_hwDeviceContext)
      return NoHarwareDecoding;

    auto *hwctx =
        reinterpret_cast<AVHWDeviceContext *>(m_hwDeviceContext->data);
    auto *vaapi = reinterpret_cast<AVVAAPIDeviceContext *>(hwctx->hwctx);

    vaapi->display = va_display;
  } else if (backend == CudaCopy) {

#ifdef ENABLE_CUDA
    AVBufferRef *hw_device_ctx = nullptr;
    int err = av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_CUDA,
                                     nullptr, nullptr, 0);
    if (err < 0)
      return NoHarwareDecoding;
    m_hwDeviceContext = hw_device_ctx;
    m_codecContext->hw_device_ctx = av_buffer_ref(m_hwDeviceContext);
    if (!m_codecContext->hw_device_ctx)
      return NoHarwareDecoding;
    m_codecContext->get_format = get_hw_format;
    auto *hwctx =
        reinterpret_cast<AVHWDeviceContext *>(m_hwDeviceContext->data);
    auto *cuda = reinterpret_cast<AVCUDADeviceContext *>(hwctx->hwctx);
    m_cudaContext = cuda->cuda_ctx;
#endif
  }
  // Initialize the HW device
  if (av_hwdevice_ctx_init(m_hwDeviceContext) < 0)
    return NoHarwareDecoding;

  // Attach to decoder
  m_codecContext->hw_device_ctx = av_buffer_ref(m_hwDeviceContext);
  if (!m_codecContext->hw_device_ctx)
    return NoHarwareDecoding;

  m_codecContext->get_format = get_hw_format;

  if (avcodec_open2(m_codecContext, m_codec, nullptr) < 0)
    return NoHarwareDecoding;

  m_frame = av_frame_alloc();
  if (!m_frame)
    return BadVideo;

  m_packet = av_packet_alloc();
  if (!m_packet)
    return BadVideo;

  return Success;
}
// thanks claude
bool Wallpaper::decodeNextFrame() {
  int ret;

  while (true) {
    ret = avcodec_receive_frame(m_codecContext, m_frame);
    if (ret == 0) {
      return true; // got a frame
    }
    if (ret != AVERROR(EAGAIN)) {
      if (ret == AVERROR_EOF) {
        // loop: seek back to start and flush decoder state
        av_seek_frame(m_formatContext, m_videoStream, 0, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(m_codecContext);
        continue; // try receiving again after flush (will hit EAGAIN, fall
                  // through to read)
      }
      return false; // real decode error
    }

    // EAGAIN: decoder wants more input
    av_packet_unref(m_packet);
    int readRet = av_read_frame(m_formatContext, m_packet);
    if (readRet < 0) {
      // EOF on demuxer side, flush decoder to drain remaining frames, then loop
      avcodec_send_packet(m_codecContext, nullptr);
      continue;
    }

    if (m_packet->stream_index != m_videoStream) {
      av_packet_unref(m_packet);
      continue;
    }

    ret = avcodec_send_packet(m_codecContext, m_packet);
    av_packet_unref(m_packet);
    if (ret < 0 && ret != AVERROR(EAGAIN)) {
      return false;
    }
    // loop back to receive_frame
  }
}

Wallpaper::~Wallpaper() {
  av_packet_free(&m_packet);
  av_frame_free(&m_frame);
  avcodec_free_context(&m_codecContext);
  avformat_close_input(&m_formatContext);
  av_buffer_unref(&m_hwDeviceContext);

#ifdef ENABLE_CUDA
  if (m_cudaContext != nullptr) {
    cuCtxDestroy(m_cudaContext);
  }
#endif
}

#ifdef ENABLE_CUDA
void Wallpaper::makeCudaContextCurrent() { cuCtxSetCurrent(m_cudaContext); }
#endif
