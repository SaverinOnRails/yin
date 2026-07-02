#include "shared/utils.hpp"
#include <stdexcept>
#include <string_view>
#include <vector>

VectorWriter::VectorWriter(std::vector<u8> &data) : m_data(data) {}
void VectorWriter::write(u8 data) { m_data.push_back(data); }
void VectorWriter::writeu32(u32 data) {
  // don't care about endianess
  u8 *bytes = reinterpret_cast<u8 *>(&data);
  for (int i = 0; i < sizeof(u32); i++) {
    write(bytes[i]);
  }
}
void VectorWriter::writeString(std::string_view data) {
  for (auto p : data) {
    write(static_cast<u8>(p));
  }
}

BufReader::BufReader(char *buf, size_t len) : m_buf(buf), m_len(len) {}
u8 BufReader::read() {
  if (m_index >= m_len)
    throw std::runtime_error("Out of bounds of buf reader");
  return m_buf[m_index++];
}

std::string BufReader::readString(size_t len) {
  std::string s = std::string(m_buf + m_index, len);
  m_index += len;
  return s;
}

u32 BufReader::readu32() {
  if (m_index + sizeof(u32) >= m_len)
    throw std::runtime_error("Out of bounds on buf reader");
  u32 out = *reinterpret_cast<const u32 *>(m_buf + m_index);
  m_index += sizeof(u32);
  return out;
};
