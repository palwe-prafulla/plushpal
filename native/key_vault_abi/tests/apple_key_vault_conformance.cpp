#include "plushpal_key_vault.h"

#include <array>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <string>

pp_key_vault_bytes_t bytes(const std::string &value) {
  return {reinterpret_cast<const uint8_t *>(value.data()), value.size()};
}

int main() {
  const std::string record =
      "plushpal-conformance-" +
      std::to_string(std::chrono::steady_clock::now().time_since_epoch().count());
  std::array<uint8_t, 32> secret{};
  secret.fill(0xA7);

  assert(pp_key_vault_store(PP_KEY_VAULT_ABI_VERSION + 1, bytes(record),
                            {secret.data(), secret.size()}) ==
         PP_KEY_VAULT_INVALID_ARGUMENT);
  assert(pp_key_vault_store(PP_KEY_VAULT_ABI_VERSION, bytes(record),
                            {secret.data(), secret.size()}) == PP_KEY_VAULT_OK);
  size_t required = 0;
  assert(pp_key_vault_read(PP_KEY_VAULT_ABI_VERSION, bytes(record), {nullptr, 0},
                           &required) == PP_KEY_VAULT_BUFFER_TOO_SMALL);
  assert(required == secret.size());
  std::array<uint8_t, 32> loaded{};
  assert(pp_key_vault_read(PP_KEY_VAULT_ABI_VERSION, bytes(record),
                           {loaded.data(), loaded.size()}, &required) ==
         PP_KEY_VAULT_OK);
  assert(loaded == secret);
  assert(pp_key_vault_delete(PP_KEY_VAULT_ABI_VERSION, bytes(record)) ==
         PP_KEY_VAULT_OK);
  assert(pp_key_vault_delete(PP_KEY_VAULT_ABI_VERSION, bytes(record)) ==
         PP_KEY_VAULT_NOT_FOUND);
  return 0;
}
