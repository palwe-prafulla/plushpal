#ifndef PLUSHPAL_SPEECH_H
#define PLUSHPAL_SPEECH_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pp_speech_engine pp_speech_engine_t;
typedef uint64_t pp_speech_job_id_t;

typedef enum pp_speech_status {
  PP_SPEECH_OK = 0,
  PP_SPEECH_INVALID_ARGUMENT = 1,
  PP_SPEECH_NOT_READY = 2,
  PP_SPEECH_MODEL_ERROR = 3,
  PP_SPEECH_BUFFER_FULL = 4,
  PP_SPEECH_TIMEOUT = 5,
  PP_SPEECH_CANCELLED = 6,
  PP_SPEECH_INTERNAL = 7
} pp_speech_status_t;

typedef struct pp_speech_config {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t sample_rate_hz;
  uint16_t channels;
  uint16_t reserved;
} pp_speech_config_t;

typedef struct pp_speech_pcm {
  const int16_t *samples;
  size_t sample_count;
} pp_speech_pcm_t;

pp_speech_status_t pp_speech_engine_create(const pp_speech_config_t *config,
                                           pp_speech_engine_t **out_engine);
pp_speech_status_t pp_speech_transcribe(pp_speech_engine_t *engine,
                                        pp_speech_pcm_t pcm,
                                        pp_speech_job_id_t *out_job);
pp_speech_status_t pp_speech_synthesize(pp_speech_engine_t *engine,
                                        const uint8_t *utf8_text,
                                        size_t text_length,
                                        pp_speech_job_id_t *out_job);
pp_speech_status_t pp_speech_cancel(pp_speech_engine_t *engine,
                                    pp_speech_job_id_t job);
void pp_speech_engine_destroy(pp_speech_engine_t *engine);

#ifdef __cplusplus
}
#endif

#endif
