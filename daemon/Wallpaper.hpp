#pragma once
#include "shared/utils.hpp"
#include <chrono>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
}
#include <string_view>

enum WallpaperBindError : u8 { Success, BadVideo, NoHarwareDecoding };

class Wallpaper {
public:
  std::chrono::nanoseconds m_frameDuration = std::chrono::milliseconds(16); //assume 60fps

public:
  WallpaperBindError bind(std::string_view img_path);

  AVFormatContext *m_formatContext = nullptr;
  int m_videoStream = -1;
  const AVCodec *m_codec = nullptr;
  AVCodecContext *m_codecContext = nullptr;
  AVBufferRef *m_hwDeviceContext = nullptr;
  AVHWDeviceType m_hwType = AV_HWDEVICE_TYPE_NONE;
  AVPacket *m_packet = nullptr;
  AVFrame *m_frame = nullptr;
};
