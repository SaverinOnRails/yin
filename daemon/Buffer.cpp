#include "daemon/Buffer.hpp"
#include "shared/utils.hpp"
#include <cassert>
#include <cstddef>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client-protocol.h>

Buffer::Buffer(u32 height, u32 width, wl_shm *shm)
    : m_height(height), m_width(width) {
  const u32 stride = width * 4;
  const u32 size = stride * height;
  m_size = size;
  auto fd = memfd_create("yin-background-image", 0);
  ftruncate(fd, size);
  m_data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  assert(m_data != MAP_FAILED);
  auto shmPool = wl_shm_create_pool(shm, fd, size);
  m_waylandBuffer = wl_shm_pool_create_buffer(shmPool, 0, width, height, stride,
                                              WL_SHM_FORMAT_ARGB8888);
  auto u32data = static_cast<u32 *>(m_data);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      if ((x + y / 8 * 8) % 16 < 8) {
        u32data[y * width + x] = 0xFF666666;
      } else {
        u32data[y * width + x] = 0xFFEEEEEE;
      }
    }
  }
}

Buffer::~Buffer() {
  wl_buffer_destroy(m_waylandBuffer);
  munmap(m_data, m_size);
}
