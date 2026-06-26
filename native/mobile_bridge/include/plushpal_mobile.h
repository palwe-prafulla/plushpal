#ifndef PLUSHPAL_MOBILE_H
#define PLUSHPAL_MOBILE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pp_mobile_engine pp_mobile_engine_t;

#define PP_MOBILE_ABI_VERSION 2u

typedef enum pp_mobile_status {
  PP_MOBILE_OK = 0,
  PP_MOBILE_INVALID_ARGUMENT = 1,
  PP_MOBILE_NOT_READY = 2,
  PP_MOBILE_POLICY_BLOCKED = 3,
  PP_MOBILE_GENERATION_FAILED = 4,
  PP_MOBILE_BUFFER_TOO_SMALL = 5,
  PP_MOBILE_CANCELLED = 6
} pp_mobile_status_t;

pp_mobile_status_t pp_mobile_engine_create(uint32_t abi_version,
                                            const uint8_t *model_path,
                                            size_t model_path_length,
                                            pp_mobile_engine_t **out_engine);
pp_mobile_status_t pp_mobile_generate_local(
    pp_mobile_engine_t *engine, uint8_t age_band, const uint8_t *alias,
    size_t alias_length, const uint8_t *text, size_t text_length,
    const uint8_t *guidance, size_t guidance_length,
    uint8_t *output, size_t output_length, size_t *out_required,
    bool *out_suggest_trusted_adult);
pp_mobile_status_t pp_mobile_cancel(pp_mobile_engine_t *engine);
pp_mobile_status_t pp_mobile_clear_session(pp_mobile_engine_t *engine);
pp_mobile_status_t pp_mobile_install_bundled_model(
    const uint8_t *destination_directory, size_t destination_directory_length);
pp_mobile_status_t pp_mobile_verify_bundled_model(
    const uint8_t *model_path, size_t model_path_length);
void pp_mobile_cancel_model_install(void);
void pp_mobile_engine_destroy(pp_mobile_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif
