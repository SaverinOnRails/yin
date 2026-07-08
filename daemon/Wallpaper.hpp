#pragma once
#include "shared/utils.hpp"
#include <chrono>
#include <va/va.h>
#include <cuda.h>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/hwcontext.h>
}
#include <string_view>

enum WallpaperBindError : u8 {
  Success,
  BadVideo,
  NoHarwareDecoding,
  NoHistory
};

class Wallpaper {
public:
  std::chrono::nanoseconds m_frameDuration =
      std::chrono::milliseconds(16); // assume 60fps
  bool decodeNextFrame();
  AVCodecContext *m_codecContext = nullptr;
  bool m_isSingleFrame = false;
  ~Wallpaper();
  void makeCudaContextCurrent();

public:
  WallpaperBindError bind(std::string_view img_path, VADisplay va_display);

  AVFormatContext *m_formatContext = nullptr;
  int m_videoStream = -1;
  const AVCodec *m_codec = nullptr;
  AVBufferRef *m_hwDeviceContext = nullptr;
  AVHWDeviceType m_hwType = AV_HWDEVICE_TYPE_NONE;
  AVPacket *m_packet = nullptr;
  AVFrame *m_frame = nullptr;
  CUcontext m_cudaContext = nullptr;
};
