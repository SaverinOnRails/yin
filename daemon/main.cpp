#include "daemon/Daemon.hpp"
#include <iostream>

int main() {
  auto daemon = Daemon{};
  daemon.run();
}
