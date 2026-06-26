#ifndef PLUSHPAL_LLAMA_H
#define PLUSHPAL_LLAMA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pp_llama_engine pp_llama_engine_t;
typedef uint64_t pp_llama_job_id_t;

#define PP_LLAMA_ABI_VERSION 1u

typedef enum pp_llama_status {
  PP_LLAMA_OK = 0,
  PP_LLAMA_INVALID_ARGUMENT = 1,
  PP_LLAMA_NOT_LOADED = 2,
  PP_LLAMA_MODEL_UNAVAILABLE = 3,
  PP_LLAMA_INCOMPATIBLE_DEVICE = 4,
  PP_LLAMA_MEMORY_PRESSURE = 5,
  PP_LLAMA_TIMEOUT = 6,
  PP_LLAMA_CANCELLED = 7,
  PP_LLAMA_INTERNAL = 8,
  PP_LLAMA_BUSY = 9,
  PP_LLAMA_BUFFER_TOO_SMALL = 10
} pp_llama_status_t;

typedef struct pp_llama_bytes {
  const uint8_t *data;
  size_t length;
} pp_llama_bytes_t;

typedef struct pp_llama_mut_bytes {
  uint8_t *data;
  size_t length;
} pp_llama_mut_bytes_t;

typedef struct pp_llama_generation_options {
  uint32_t maximum_output_characters;
  uint16_t temperature_milli;
  uint16_t top_p_milli;
  uint64_t seed;
  uint64_t deadline_milliseconds;
} pp_llama_generation_options_t;

typedef struct pp_llama_metrics {
  uint64_t prompt_characters;
  uint64_t output_characters;
  uint64_t elapsed_milliseconds;
  uint64_t peak_memory_bytes;
} pp_llama_metrics_t;

pp_llama_status_t pp_llama_engine_create(uint32_t abi_version,
                                         pp_llama_engine_t **out_engine);
pp_llama_status_t pp_llama_engine_load(pp_llama_engine_t *engine,
                                       pp_llama_bytes_t model_path);
pp_llama_status_t pp_llama_engine_generate(pp_llama_engine_t *engine,
                                           pp_llama_bytes_t prompt,
                                           pp_llama_generation_options_t options,
                                           pp_llama_job_id_t *out_job);
/* Reads a completed job. Passing output.data=NULL reports the required byte
 * count in out_required. The engine retains ownership until this succeeds or
 * the job is cancelled. */
pp_llama_status_t pp_llama_engine_read_result(pp_llama_engine_t *engine,
                                              pp_llama_job_id_t job,
                                              pp_llama_mut_bytes_t output,
                                              size_t *out_required,
                                              pp_llama_metrics_t *out_metrics);
pp_llama_status_t pp_llama_engine_cancel(pp_llama_engine_t *engine,
                                         pp_llama_job_id_t job);
pp_llama_status_t pp_llama_engine_unload(pp_llama_engine_t *engine);
void pp_llama_engine_destroy(pp_llama_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif
