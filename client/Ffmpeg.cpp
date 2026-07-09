#include "shared/utils.hpp"
#include <filesystem>
#include <stdexcept>
#include <string_view>

void cacheVideo(std::string_view file_path, std::string_view write_to,
                u32 width, u32 height) {
  std::filesystem::path full_path = file_path;

  std::ostringstream command;
  auto ext = full_path.extension();
  int result;
  if (ext == ".mp4" || ext == ".mkv") {
    command << "ffmpeg "
            << "-y "
            << "-i \"" << full_path.string() << "\" "
            << "-vf scale=" << width << ":" << height << " "
            << "-pix_fmt yuv420p "
            << "-profile:v main "
            << "-level:v 4.1 "
            << "-an "
            << "-c:v libx264 "
            << "\"" << write_to << "\"";
    result = std::system(command.str().c_str());
  } else {
    command << "ffmpeg "
            << "-y "
            << "-i \"" << full_path.string() << "\" "
            << "-vf scale=" << width << ":" << height << " "
            << "\"" << write_to << "\"";

    result = std::system(command.str().c_str());
  }
  if (result != 0) {
    throw std::runtime_error("ffmpeg failed");
  }
}
