#include "daemon/Wallpaper.hpp"

static enum AVPixelFormat get_hw_format(AVCodecContext *ctx,
                                        const enum AVPixelFormat *pix_fmts) {
  for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
    if (*p == AV_PIX_FMT_VAAPI)
      return *p;
  }
  return AV_PIX_FMT_NONE;
}

WallpaperBindError Wallpaper::bind(std::string_view path) {

  if (avformat_open_input(&m_formatContext, path.data(), nullptr, nullptr) <
      0) {
    return BadVideo;
  }

  if (avformat_find_stream_info(m_formatContext, nullptr) < 0) {
    return BadVideo;
  }

  m_videoStream = av_find_best_stream(m_formatContext, AVMEDIA_TYPE_VIDEO, -1,
                                      -1, &m_codec, 0);

  if (m_videoStream < 0)
    return BadVideo;

  m_codecContext = avcodec_alloc_context3(m_codec);

  if (!m_codecContext)
    return BadVideo;

  m_codecContext->get_format = get_hw_format;
  avcodec_parameters_to_context(
      m_codecContext, m_formatContext->streams[m_videoStream]->codecpar);

  if (avcodec_open2(m_codecContext, m_codec, nullptr) < 0)
    return BadVideo;

  m_packet = av_packet_alloc();
  m_frame = av_frame_alloc();

  m_hwType = AV_HWDEVICE_TYPE_VAAPI;

  if (av_hwdevice_ctx_create(&m_hwDeviceContext, m_hwType, nullptr, nullptr,
                             0) == 0) {
    m_codecContext->hw_device_ctx = av_buffer_ref(m_hwDeviceContext);
  } else {
    return NoHarwareDecoding;
  }
  return Success;
}
