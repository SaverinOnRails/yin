#include "daemon/Daemon.hpp"

int main() {
  auto daemon = Daemon{};
  daemon.run();
}
