#pragma once
#include "shared/utils.hpp"
#include <cstddef>
#include <wayland-client-protocol.h>
class Buffer {
public:
  void *m_data;
  Buffer(u32 height, u32 width , wl_shm* shm);
  ~Buffer();
  wl_buffer *m_waylandBuffer;
  size_t m_size;
  u32 m_height;
  u32 m_width;
};
