#include "plushpal_llama.h"

#include "ggml-backend.h"
#include "llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr size_t kMaximumPromptBytes = 1024 * 1024;
constexpr uint32_t kMaximumGeneratedTokens = 2048;

struct JobResult {
  pp_llama_status_t status = PP_LLAMA_OK;
  std::string output;
  pp_llama_metrics_t metrics{};
};

struct SamplerDeleter {
  void operator()(llama_sampler *sampler) const {
    if (sampler != nullptr) {
      llama_sampler_free(sampler);
    }
  }
};

struct ContextDeleter {
  void operator()(llama_context *context) const {
    if (context != nullptr) {
      llama_free(context);
    }
  }
};

bool valid_bytes(pp_llama_bytes_t bytes) {
  return bytes.data != nullptr && bytes.length > 0;
}

std::string token_piece(const llama_vocab *vocab, llama_token token) {
  std::vector<char> buffer(256);
  int32_t size = llama_token_to_piece(vocab, token, buffer.data(),
                                      static_cast<int32_t>(buffer.size()), 0,
                                      true);
  if (size < 0) {
    buffer.resize(static_cast<size_t>(-size));
    size = llama_token_to_piece(vocab, token, buffer.data(),
                                static_cast<int32_t>(buffer.size()), 0, true);
  }
  return size > 0 ? std::string(buffer.data(), static_cast<size_t>(size))
                  : std::string();
}

void log_native_error(enum ggml_log_level level, const char *text, void *) {
  if (level == GGML_LOG_LEVEL_ERROR && text != nullptr) {
    std::fputs("PlushPal llama runtime: ", stderr);
    std::fputs(text, stderr);
  }
}

} // namespace

struct pp_llama_engine {
  std::mutex lifecycle;
  std::mutex results;
  llama_model *model = nullptr;
  std::atomic<bool> cancelled{false};
  std::atomic<pp_llama_job_id_t> active_job{0};
  pp_llama_job_id_t next_job = 1;
  std::thread worker;
  std::unordered_map<pp_llama_job_id_t, JobResult> completed;
};

extern "C" pp_llama_status_t
pp_llama_engine_create(uint32_t abi_version, pp_llama_engine_t **out_engine) {
  if (out_engine == nullptr || abi_version != PP_LLAMA_ABI_VERSION) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  *out_engine = new (std::nothrow) pp_llama_engine();
  return *out_engine == nullptr ? PP_LLAMA_MEMORY_PRESSURE : PP_LLAMA_OK;
}

extern "C" pp_llama_status_t
pp_llama_engine_load(pp_llama_engine_t *engine, pp_llama_bytes_t model_path) {
  if (engine == nullptr || !valid_bytes(model_path) ||
      std::memchr(model_path.data, '\0', model_path.length) != nullptr) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  const std::string path(reinterpret_cast<const char *>(model_path.data),
                         model_path.length);
  std::lock_guard<std::mutex> lock(engine->lifecycle);
  if (engine->active_job.load() != 0) {
    return PP_LLAMA_BUSY;
  }
  if (engine->worker.joinable()) {
    engine->worker.join();
  }
  if (engine->model != nullptr) {
    llama_model_free(engine->model);
    engine->model = nullptr;
  }
  static std::once_flag backend_once;
  std::call_once(backend_once, [] {
    llama_log_set(log_native_error, nullptr);
    ggml_backend_load_all();
  });
  llama_model_params parameters = llama_model_default_params();
#if defined(__APPLE__)
  parameters.n_gpu_layers = 99;
#else
  parameters.n_gpu_layers = 0;
#endif
  engine->model = llama_model_load_from_file(path.c_str(), parameters);
  return engine->model == nullptr ? PP_LLAMA_MODEL_UNAVAILABLE : PP_LLAMA_OK;
}

namespace {

void publish_result(pp_llama_engine_t *engine, pp_llama_job_id_t job,
                    JobResult result) {
  {
    std::lock_guard<std::mutex> lock(engine->results);
    engine->completed.insert_or_assign(job, std::move(result));
  }
  engine->active_job.store(0);
}

void run_generation(pp_llama_engine_t *engine, llama_model *model,
                    std::string prompt_text,
                    pp_llama_generation_options_t options,
                    pp_llama_job_id_t job) {
  JobResult result;
  const char *chat_template = llama_model_chat_template(model, nullptr);
  if (chat_template == nullptr) {
    result.status = PP_LLAMA_INTERNAL;
    publish_result(engine, job, std::move(result));
    return;
  }
  constexpr const char *system_prompt =
      "You are the local PlushPal child-safety response engine. Follow the "
      "immutable policy in the user payload. Never expose internal reasoning. "
      "Return exactly one JSON object and no Markdown.";
  const llama_chat_message messages[] = {
      {"system", system_prompt},
      {"user", prompt_text.c_str()},
  };
  const int32_t formatted_size = llama_chat_apply_template(
      chat_template, messages, 2, true, nullptr, 0);
  if (formatted_size <= 0) {
    result.status = PP_LLAMA_INTERNAL;
    publish_result(engine, job, std::move(result));
    return;
  }
  std::vector<char> formatted_prompt(static_cast<size_t>(formatted_size) + 1);
  if (llama_chat_apply_template(chat_template, messages, 2, true,
                                formatted_prompt.data(),
                                static_cast<int32_t>(formatted_prompt.size())) <
      0) {
    result.status = PP_LLAMA_INTERNAL;
    publish_result(engine, job, std::move(result));
    return;
  }
  prompt_text.assign(formatted_prompt.data(), static_cast<size_t>(formatted_size));
  const llama_vocab *vocab = llama_model_get_vocab(model);
  const int32_t required = llama_tokenize(vocab, prompt_text.data(),
                                          prompt_text.size(), nullptr, 0, true,
                                          true);
  if (required >= 0 || required == std::numeric_limits<int32_t>::min()) {
    result.status = PP_LLAMA_INTERNAL;
    publish_result(engine, job, std::move(result));
    return;
  }
  std::vector<llama_token> prompt_tokens(static_cast<size_t>(-required));
  if (llama_tokenize(vocab, prompt_text.data(), prompt_text.size(),
                     prompt_tokens.data(), prompt_tokens.size(), true, true) <
      0) {
    result.status = PP_LLAMA_INTERNAL;
    publish_result(engine, job, std::move(result));
    return;
  }

  const uint32_t maximum_tokens = std::min(
      kMaximumGeneratedTokens,
      std::max<uint32_t>(1, options.maximum_output_characters * 2));
  llama_context_params context_parameters = llama_context_default_params();
  const uint64_t requested_context = prompt_tokens.size() + maximum_tokens;
  if (requested_context > std::numeric_limits<uint32_t>::max()) {
    result.status = PP_LLAMA_INVALID_ARGUMENT;
    publish_result(engine, job, std::move(result));
    return;
  }
  context_parameters.n_ctx = static_cast<uint32_t>(requested_context);
  context_parameters.n_batch =
      static_cast<uint32_t>(std::max<size_t>(1, prompt_tokens.size()));
  context_parameters.no_perf = false;
  std::unique_ptr<llama_context, ContextDeleter> context(
      llama_init_from_model(model, context_parameters));
  if (!context) {
    result.status = PP_LLAMA_MEMORY_PRESSURE;
    publish_result(engine, job, std::move(result));
    return;
  }

  llama_sampler_chain_params sampler_parameters =
      llama_sampler_chain_default_params();
  std::unique_ptr<llama_sampler, SamplerDeleter> sampler(
      llama_sampler_chain_init(sampler_parameters));
  if (!sampler) {
    result.status = PP_LLAMA_MEMORY_PRESSURE;
    publish_result(engine, job, std::move(result));
    return;
  }
  llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(
                                              options.top_p_milli / 1000.0F, 1));
  llama_sampler_chain_add(
      sampler.get(),
      llama_sampler_init_temp(options.temperature_milli / 1000.0F));
  llama_sampler_chain_add(
      sampler.get(),
      llama_sampler_init_dist(static_cast<uint32_t>(options.seed)));

  llama_batch batch =
      llama_batch_get_one(prompt_tokens.data(), prompt_tokens.size());
  std::string output;
  output.reserve(options.maximum_output_characters * 2);
  const auto started = std::chrono::steady_clock::now();
  const auto deadline = started +
                        std::chrono::milliseconds(options.deadline_milliseconds);
  pp_llama_status_t status = PP_LLAMA_OK;
  for (uint32_t generated = 0; generated < maximum_tokens; ++generated) {
    if (engine->cancelled.load()) {
      status = PP_LLAMA_CANCELLED;
      break;
    }
    if (std::chrono::steady_clock::now() >= deadline) {
      status = PP_LLAMA_TIMEOUT;
      break;
    }
    if (llama_decode(context.get(), batch) != 0) {
      status = PP_LLAMA_INTERNAL;
      break;
    }
    llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
    if (llama_vocab_is_eog(vocab, token)) {
      break;
    }
    const std::string piece = token_piece(vocab, token);
    const size_t maximum_bytes =
        static_cast<size_t>(options.maximum_output_characters) * 4;
    if (piece.empty() || output.size() + piece.size() > maximum_bytes) {
      break;
    }
    output += piece;
    batch = llama_batch_get_one(&token, 1);
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started);
  result.status = status;
  result.output = std::move(output);
  result.metrics.prompt_characters = prompt_text.size();
  result.metrics.output_characters = result.output.size();
  result.metrics.elapsed_milliseconds = static_cast<uint64_t>(elapsed.count());
  result.metrics.peak_memory_bytes = llama_model_size(model);
  publish_result(engine, job, std::move(result));
}

} // namespace

extern "C" pp_llama_status_t pp_llama_engine_generate(
    pp_llama_engine_t *engine, pp_llama_bytes_t prompt,
    pp_llama_generation_options_t options, pp_llama_job_id_t *out_job) {
  if (engine == nullptr || out_job == nullptr || !valid_bytes(prompt) ||
      prompt.length > kMaximumPromptBytes ||
      options.maximum_output_characters == 0 ||
      options.deadline_milliseconds == 0 || options.temperature_milli > 2000 ||
      options.top_p_milli > 1000) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(engine->lifecycle);
  if (engine->model == nullptr) {
    return PP_LLAMA_NOT_LOADED;
  }
  if (engine->active_job.load() != 0) {
    return PP_LLAMA_BUSY;
  }
  if (engine->worker.joinable()) {
    engine->worker.join();
  }
  const pp_llama_job_id_t job = engine->next_job++;
  engine->active_job.store(job);
  engine->cancelled.store(false);
  *out_job = job;
  const std::string prompt_text(reinterpret_cast<const char *>(prompt.data),
                                prompt.length);
  try {
    engine->worker = std::thread(run_generation, engine, engine->model,
                                 prompt_text, options, job);
  } catch (...) {
    engine->active_job.store(0);
    return PP_LLAMA_MEMORY_PRESSURE;
  }
  return PP_LLAMA_OK;
}

extern "C" pp_llama_status_t pp_llama_engine_read_result(
    pp_llama_engine_t *engine, pp_llama_job_id_t job,
    pp_llama_mut_bytes_t output, size_t *out_required,
    pp_llama_metrics_t *out_metrics) {
  if (engine == nullptr || job == 0 || out_required == nullptr ||
      out_metrics == nullptr || (output.data == nullptr && output.length != 0)) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(engine->results);
  const auto found = engine->completed.find(job);
  if (found == engine->completed.end()) {
    if (engine->active_job.load() == job) {
      return PP_LLAMA_BUSY;
    }
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  if (found->second.status != PP_LLAMA_OK) {
    const pp_llama_status_t status = found->second.status;
    engine->completed.erase(found);
    return status;
  }
  *out_required = found->second.output.size();
  *out_metrics = found->second.metrics;
  if (output.data == nullptr || output.length < found->second.output.size()) {
    return PP_LLAMA_BUFFER_TOO_SMALL;
  }
  std::memcpy(output.data, found->second.output.data(),
              found->second.output.size());
  engine->completed.erase(found);
  return PP_LLAMA_OK;
}

extern "C" pp_llama_status_t
pp_llama_engine_cancel(pp_llama_engine_t *engine, pp_llama_job_id_t job) {
  if (engine == nullptr || job == 0) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  if (engine->active_job.load() != job) {
    return PP_LLAMA_NOT_LOADED;
  }
  engine->cancelled.store(true);
  return PP_LLAMA_OK;
}

extern "C" pp_llama_status_t
pp_llama_engine_unload(pp_llama_engine_t *engine) {
  if (engine == nullptr) {
    return PP_LLAMA_INVALID_ARGUMENT;
  }
  engine->cancelled.store(true);
  std::lock_guard<std::mutex> lock(engine->lifecycle);
  if (engine->worker.joinable()) {
    engine->worker.join();
  }
  if (engine->model != nullptr) {
    llama_model_free(engine->model);
    engine->model = nullptr;
  }
  {
    std::lock_guard<std::mutex> results_lock(engine->results);
    engine->completed.clear();
  }
  return PP_LLAMA_OK;
}

extern "C" void pp_llama_engine_destroy(pp_llama_engine_t *engine) {
  if (engine != nullptr) {
    pp_llama_engine_unload(engine);
    delete engine;
  }
}
