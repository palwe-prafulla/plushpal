#include "plushpal_llama.h"

#include <cassert>
#include <cstdint>
#include <string>

int main() {
  assert(pp_llama_engine_create(PP_LLAMA_ABI_VERSION, nullptr) ==
         PP_LLAMA_INVALID_ARGUMENT);
  pp_llama_engine_t *engine = nullptr;
  assert(pp_llama_engine_create(PP_LLAMA_ABI_VERSION + 1, &engine) ==
         PP_LLAMA_INVALID_ARGUMENT);
  assert(engine == nullptr);
  assert(pp_llama_engine_create(PP_LLAMA_ABI_VERSION, &engine) == PP_LLAMA_OK);
  assert(engine != nullptr);

  const std::string prompt = "hello";
  pp_llama_generation_options_t options{100, 600, 900, 0, 1000};
  pp_llama_job_id_t job = 0;
  assert(pp_llama_engine_generate(
             engine,
             {reinterpret_cast<const uint8_t *>(prompt.data()), prompt.size()},
             options, &job) == PP_LLAMA_NOT_LOADED);
  assert(pp_llama_engine_cancel(engine, 1) == PP_LLAMA_NOT_LOADED);

  const std::string missing = "/definitely/missing/model.gguf";
  assert(pp_llama_engine_load(
             engine,
             {reinterpret_cast<const uint8_t *>(missing.data()), missing.size()}) ==
         PP_LLAMA_MODEL_UNAVAILABLE);
  assert(pp_llama_engine_unload(engine) == PP_LLAMA_OK);
  assert(pp_llama_engine_unload(engine) == PP_LLAMA_OK);
  pp_llama_engine_destroy(engine);
  pp_llama_engine_destroy(nullptr);
  return 0;
}
