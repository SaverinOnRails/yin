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

//thank you Claude
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
