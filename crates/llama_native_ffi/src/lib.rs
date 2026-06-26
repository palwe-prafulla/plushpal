#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    ffi::c_void,
    path::Path,
    ptr::NonNull,
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

use plushpal_local_llm_llamacpp::{
    BackendError, BackendMetrics, GenerationOptions, NativeGeneration, NativeLlamaApi,
};

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_NOT_LOADED: i32 = 2;
const STATUS_MODEL_UNAVAILABLE: i32 = 3;
const STATUS_INCOMPATIBLE_DEVICE: i32 = 4;
const STATUS_MEMORY_PRESSURE: i32 = 5;
const STATUS_TIMEOUT: i32 = 6;
const STATUS_CANCELLED: i32 = 7;
const STATUS_BUSY: i32 = 9;
const STATUS_BUFFER_TOO_SMALL: i32 = 10;

#[repr(C)]
struct NativeBytes {
    data: *const u8,
    length: usize,
}

#[repr(C)]
struct NativeMutBytes {
    data: *mut u8,
    length: usize,
}

#[repr(C)]
struct NativeOptions {
    maximum_output_characters: u32,
    temperature_milli: u16,
    top_p_milli: u16,
    seed: u64,
    deadline_milliseconds: u64,
}

#[repr(C)]
#[derive(Default)]
struct NativeMetrics {
    prompt_characters: u64,
    output_characters: u64,
    elapsed_milliseconds: u64,
    peak_memory_bytes: u64,
}

unsafe extern "C" {
    fn pp_llama_engine_create(abi_version: u32, out_engine: *mut *mut c_void) -> i32;
    fn pp_llama_engine_load(engine: *mut c_void, model_path: NativeBytes) -> i32;
    fn pp_llama_engine_generate(
        engine: *mut c_void,
        prompt: NativeBytes,
        options: NativeOptions,
        out_job: *mut u64,
    ) -> i32;
    fn pp_llama_engine_read_result(
        engine: *mut c_void,
        job: u64,
        output: NativeMutBytes,
        out_required: *mut usize,
        out_metrics: *mut NativeMetrics,
    ) -> i32;
    fn pp_llama_engine_cancel(engine: *mut c_void, job: u64) -> i32;
    fn pp_llama_engine_unload(engine: *mut c_void) -> i32;
    fn pp_llama_engine_destroy(engine: *mut c_void);
}

pub struct CAbiEngine {
    pointer: NonNull<c_void>,
    active_job: AtomicU64,
}

impl std::fmt::Debug for CAbiEngine {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CAbiEngine")
            .field("active_job", &self.active_job.load(Ordering::Acquire))
            .finish_non_exhaustive()
    }
}

// The native engine serializes lifecycle operations and uses atomics for cancellation.
unsafe impl Send for CAbiEngine {}
// The C ABI is explicitly thread-safe for generate/read/cancel/unload coordination.
unsafe impl Sync for CAbiEngine {}

impl Drop for CAbiEngine {
    fn drop(&mut self) {
        // SAFETY: pointer is uniquely created by pp_llama_engine_create and destroyed once here.
        unsafe { pp_llama_engine_destroy(self.pointer.as_ptr()) };
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct CAbiLlamaApi;

impl NativeLlamaApi for CAbiLlamaApi {
    type Engine = CAbiEngine;

    fn create(&self, abi_version: u32) -> Result<Self::Engine, BackendError> {
        let mut pointer = std::ptr::null_mut();
        // SAFETY: out pointer is valid for the duration of the call.
        status_result(unsafe { pp_llama_engine_create(abi_version, &mut pointer) })?;
        let pointer = NonNull::new(pointer).ok_or(BackendError::Internal)?;
        Ok(CAbiEngine {
            pointer,
            active_job: AtomicU64::new(0),
        })
    }

    fn load(&self, engine: &Self::Engine, model_path: &Path) -> Result<(), BackendError> {
        let path = model_path.to_str().ok_or(BackendError::ModelUnavailable)?;
        let bytes = path.as_bytes();
        // SAFETY: engine is live and bytes remain valid for the synchronous call.
        status_result(unsafe {
            pp_llama_engine_load(
                engine.pointer.as_ptr(),
                NativeBytes {
                    data: bytes.as_ptr(),
                    length: bytes.len(),
                },
            )
        })
    }

    fn generate(
        &self,
        engine: &Self::Engine,
        prompt: &str,
        options: GenerationOptions,
        deadline: Duration,
    ) -> Result<NativeGeneration, BackendError> {
        let maximum_output_characters =
            u32::try_from(options.maximum_output_characters).map_err(|_| BackendError::Internal)?;
        let deadline_milliseconds =
            u64::try_from(deadline.as_millis()).map_err(|_| BackendError::Timeout)?;
        let native_options = NativeOptions {
            maximum_output_characters,
            temperature_milli: options.temperature_milli,
            top_p_milli: options.top_p_milli,
            seed: options.seed,
            deadline_milliseconds,
        };
        let mut job = 0;
        // SAFETY: engine and prompt bytes remain valid during this non-retaining start call.
        status_result(unsafe {
            pp_llama_engine_generate(
                engine.pointer.as_ptr(),
                NativeBytes {
                    data: prompt.as_ptr(),
                    length: prompt.len(),
                },
                native_options,
                &mut job,
            )
        })?;
        engine.active_job.store(job, Ordering::Release);
        let started = Instant::now();
        let result = poll_result(engine, job, deadline, started);
        engine.active_job.store(0, Ordering::Release);
        result
    }

    fn cancel(&self, engine: &Self::Engine) -> Result<(), BackendError> {
        let job = engine.active_job.load(Ordering::Acquire);
        if job == 0 {
            return Err(BackendError::NotLoaded);
        }
        // SAFETY: engine remains live and job came from this engine.
        status_result(unsafe { pp_llama_engine_cancel(engine.pointer.as_ptr(), job) })
    }

    fn unload(&self, engine: &Self::Engine) -> Result<(), BackendError> {
        // SAFETY: engine remains live; native unload is idempotent.
        status_result(unsafe { pp_llama_engine_unload(engine.pointer.as_ptr()) })
    }
}

fn poll_result(
    engine: &CAbiEngine,
    job: u64,
    deadline: Duration,
    started: Instant,
) -> Result<NativeGeneration, BackendError> {
    loop {
        let mut required = 0;
        let mut metrics = NativeMetrics::default();
        // SAFETY: output pointers are valid; null output requests the required size.
        let status = unsafe {
            pp_llama_engine_read_result(
                engine.pointer.as_ptr(),
                job,
                NativeMutBytes {
                    data: std::ptr::null_mut(),
                    length: 0,
                },
                &mut required,
                &mut metrics,
            )
        };
        if status == STATUS_BUSY {
            if started.elapsed() >= deadline {
                // SAFETY: engine remains live and job belongs to it.
                let _ = unsafe { pp_llama_engine_cancel(engine.pointer.as_ptr(), job) };
                return Err(BackendError::Timeout);
            }
            thread::sleep(Duration::from_millis(2));
            continue;
        }
        if status != STATUS_BUFFER_TOO_SMALL {
            status_result(status)?;
            if required != 0 {
                return Err(BackendError::Internal);
            }
        }
        let mut output = vec![0_u8; required];
        // SAFETY: output and metadata buffers remain valid for the synchronous read.
        status_result(unsafe {
            pp_llama_engine_read_result(
                engine.pointer.as_ptr(),
                job,
                NativeMutBytes {
                    data: output.as_mut_ptr(),
                    length: output.len(),
                },
                &mut required,
                &mut metrics,
            )
        })?;
        let output = String::from_utf8(output).map_err(|_| BackendError::Internal)?;
        return Ok(NativeGeneration {
            output,
            metrics: BackendMetrics {
                prompt_characters: metrics.prompt_characters,
                output_characters: metrics.output_characters,
                elapsed_milliseconds: metrics.elapsed_milliseconds,
                peak_memory_bytes: metrics.peak_memory_bytes,
            },
        });
    }
}

fn status_result(status: i32) -> Result<(), BackendError> {
    match status {
        STATUS_OK => Ok(()),
        STATUS_NOT_LOADED => Err(BackendError::NotLoaded),
        STATUS_MODEL_UNAVAILABLE => Err(BackendError::ModelUnavailable),
        STATUS_INCOMPATIBLE_DEVICE => Err(BackendError::IncompatibleDevice),
        STATUS_MEMORY_PRESSURE => Err(BackendError::MemoryPressure),
        STATUS_TIMEOUT => Err(BackendError::Timeout),
        STATUS_CANCELLED => Err(BackendError::Cancelled),
        STATUS_INVALID_ARGUMENT | STATUS_BUSY | STATUS_BUFFER_TOO_SMALL => {
            Err(BackendError::Internal)
        }
        _ => Err(BackendError::Internal),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_engine_create_missing_model_and_unload_run_end_to_end() {
        let api = CAbiLlamaApi;
        let engine = api
            .create(plushpal_local_llm_llamacpp::LLAMA_ABI_VERSION)
            .unwrap();
        assert_eq!(
            api.load(&engine, Path::new("/definitely/missing/model.gguf")),
            Err(BackendError::ModelUnavailable)
        );
        api.unload(&engine).unwrap();
    }

    #[test]
    fn every_native_status_is_normalized_without_exposing_codes() {
        for (status, expected) in [
            (STATUS_NOT_LOADED, BackendError::NotLoaded),
            (STATUS_MODEL_UNAVAILABLE, BackendError::ModelUnavailable),
            (STATUS_INCOMPATIBLE_DEVICE, BackendError::IncompatibleDevice),
            (STATUS_MEMORY_PRESSURE, BackendError::MemoryPressure),
            (STATUS_TIMEOUT, BackendError::Timeout),
            (STATUS_CANCELLED, BackendError::Cancelled),
            (STATUS_INVALID_ARGUMENT, BackendError::Internal),
            (STATUS_BUSY, BackendError::Internal),
            (STATUS_BUFFER_TOO_SMALL, BackendError::Internal),
        ] {
            assert_eq!(status_result(status), Err(expected));
        }
    }
}
