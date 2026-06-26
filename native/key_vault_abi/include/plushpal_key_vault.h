#ifndef PLUSHPAL_KEY_VAULT_H
#define PLUSHPAL_KEY_VAULT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PP_KEY_VAULT_ABI_VERSION 1u

typedef enum pp_key_vault_status {
  PP_KEY_VAULT_OK = 0,
  PP_KEY_VAULT_INVALID_ARGUMENT = 1,
  PP_KEY_VAULT_NOT_FOUND = 2,
  PP_KEY_VAULT_BUFFER_TOO_SMALL = 3,
  PP_KEY_VAULT_ACCESS_DENIED = 4,
  PP_KEY_VAULT_INTERNAL = 5
} pp_key_vault_status_t;

typedef struct pp_key_vault_bytes {
  const uint8_t *data;
  size_t length;
} pp_key_vault_bytes_t;

typedef struct pp_key_vault_mut_bytes {
  uint8_t *data;
  size_t length;
} pp_key_vault_mut_bytes_t;

pp_key_vault_status_t pp_key_vault_store(uint32_t abi_version,
                                         pp_key_vault_bytes_t record_id,
                                         pp_key_vault_bytes_t secret);
pp_key_vault_status_t pp_key_vault_read(uint32_t abi_version,
                                        pp_key_vault_bytes_t record_id,
                                        pp_key_vault_mut_bytes_t output,
                                        size_t *out_required);
pp_key_vault_status_t pp_key_vault_delete(uint32_t abi_version,
                                          pp_key_vault_bytes_t record_id);

#ifdef __cplusplus
}
#endif

#endif
