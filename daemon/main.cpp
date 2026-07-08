#include "daemon/Daemon.hpp"
#include <stdexcept>
#include <string_view>

int main(int argc, char **argv) {
  HardwareAccelerationBackend backend = Vaapi;
  if (argc > 1) {
    if (std::string_view(argv[1]) == "--use-cuda-copy") {
      backend = CudaCopy;
#ifndef ENABLE_CUDA
      throw std::runtime_error("CUDA support has not been compiled in!");
#endif
    }
  }
  auto daemon = Daemon(backend);
  daemon.run();
}
