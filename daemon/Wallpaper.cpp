#include "daemon/Wallpaper.hpp"
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/pixfmt.h>
#include <va/va.h>

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
  // for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
  //   if (*p == AV_PIX_FMT_VAAPI)
  //     return *p;
  // }
  return AV_PIX_FMT_VAAPI;
}

WallpaperBindError Wallpaper::bind(std::string_view path,
                                   VADisplay va_display) {
  if (avformat_open_input(&m_formatContext, path.data(), nullptr, nullptr) < 0)
    return BadVideo;

  if (avformat_find_stream_info(m_formatContext, nullptr) < 0)
    return BadVideo;

  m_videoStream = av_find_best_stream(m_formatContext, AVMEDIA_TYPE_VIDEO, -1,
                                      -1, &m_codec, 0);

  if (m_videoStream < 0)
    return BadVideo;

  m_codecContext = avcodec_alloc_context3(m_codec);
  if (!m_codecContext)
    return BadVideo;

  if (avcodec_parameters_to_context(
          m_codecContext, m_formatContext->streams[m_videoStream]->codecpar) <
      0)
    return BadVideo;

  // Allocate hardware device context
  m_hwDeviceContext = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VAAPI);
  if (!m_hwDeviceContext)
    return NoHarwareDecoding;

  auto *hwctx = reinterpret_cast<AVHWDeviceContext *>(m_hwDeviceContext->data);
  auto *vaapi = reinterpret_cast<AVVAAPIDeviceContext *>(hwctx->hwctx);

  vaapi->display = va_display;

  // Initialize the VAAPI device
  if (av_hwdevice_ctx_init(m_hwDeviceContext) < 0)
    return NoHarwareDecoding;

  // Attach to decoder
  m_codecContext->hw_device_ctx = av_buffer_ref(m_hwDeviceContext);
  if (!m_codecContext->hw_device_ctx)
    return NoHarwareDecoding;

  // Must be set BEFORE opening the codec
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
