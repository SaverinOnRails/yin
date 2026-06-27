#include "shared/utils.hpp"
#include <string_view>
#include <vector>

VectorWriter::VectorWriter(std::vector<u8> &data) : m_data(data) {}
void VectorWriter::write(u8 data) { m_data.push_back(data); }
void VectorWriter::writeString(std::string_view data) {
  for (auto p : data) {
    write(static_cast<u8>(p));
  }
}
