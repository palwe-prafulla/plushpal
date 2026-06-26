#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    future::Future,
    sync::Arc,
    task::{Context, Poll, Wake, Waker},
    time::Duration,
};

use plushpal_application::{LocalConversationSession, TurnError};
use plushpal_core_domain::{AgeBand, StructuredCharacterResponse};
use plushpal_provider_api::ConversationProvider;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum MobileBridgeError {
    Policy,
    Provider,
}

#[derive(Debug)]
pub struct MobileConversationCore<P> {
    session: LocalConversationSession<P>,
}

impl<P: ConversationProvider> MobileConversationCore<P> {
    #[must_use]
    pub fn new(provider: P, deadline: Duration) -> Self {
        Self {
            session: LocalConversationSession::new(provider, deadline, 12),
        }
    }

    pub fn generate_local(
        &self,
        age_band: AgeBand,
        character_alias: String,
        text: String,
        parent_guidance: Option<String>,
    ) -> Result<StructuredCharacterResponse, MobileBridgeError> {
        block_on(self.session.generate_with_guidance(
            age_band,
            character_alias,
            parent_guidance,
            text,
        ))
        .map_err(|error| match error {
            TurnError::Policy(_) => MobileBridgeError::Policy,
            TurnError::Provider(_) => MobileBridgeError::Provider,
        })
    }

    pub fn clear_session(&self) -> Result<(), MobileBridgeError> {
        self.session.clear().map_err(|error| match error {
            TurnError::Policy(_) => MobileBridgeError::Policy,
            TurnError::Provider(_) => MobileBridgeError::Provider,
        })
    }
}

#[derive(Debug)]
struct ThreadWake(std::thread::Thread);

impl Wake for ThreadWake {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }
}

fn block_on<F: Future>(future: F) -> F::Output {
    let waker = Waker::from(Arc::new(ThreadWake(std::thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(output) => return output,
            Poll::Pending => std::thread::park_timeout(Duration::from_millis(10)),
        }
    }
}

#[cfg(feature = "native-runtime")]
mod native_ffi {
    use std::{
        ffi::c_void,
        path::Path,
        ptr::NonNull,
        slice, str,
        sync::{
            atomic::{AtomicBool, Ordering},
            Mutex,
        },
    };

    use plushpal_llama_native_ffi::CAbiLlamaApi;
    use plushpal_local_llm_llamacpp::{LlamaCppProvider, NativeLlamaBackend};
    use plushpal_model_lifecycle::{
        bundled_private_beta_manifest, verify_model_artifact, LifecycleError,
        ProductionModelDownloader,
    };

    use super::*;

    const STATUS_OK: i32 = 0;
    const STATUS_INVALID_ARGUMENT: i32 = 1;
    const STATUS_NOT_READY: i32 = 2;
    const STATUS_POLICY_BLOCKED: i32 = 3;
    const STATUS_GENERATION_FAILED: i32 = 4;
    const STATUS_BUFFER_TOO_SMALL: i32 = 5;
    const STATUS_CANCELLED: i32 = 6;
    const ABI_VERSION: u32 = 2;
    const MAX_MODEL_PATH_BYTES: usize = 4_096;
    const MAX_ALIAS_BYTES: usize = 320;
    const MAX_TEXT_BYTES: usize = 2_400;
    const MAX_GUIDANCE_BYTES: usize = 1_024;
    static MODEL_INSTALL_CANCELLED: AtomicBool = AtomicBool::new(false);

    type NativeProvider = LlamaCppProvider<NativeLlamaBackend<CAbiLlamaApi>>;

    struct NativeMobileEngine {
        core: MobileConversationCore<Arc<NativeProvider>>,
        provider: Arc<NativeProvider>,
        pending: Mutex<Option<StructuredCharacterResponse>>,
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_engine_create(
        abi_version: u32,
        model_path: *const u8,
        model_path_length: usize,
        out_engine: *mut *mut c_void,
    ) -> i32 {
        if out_engine.is_null() {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out_engine was validated and is initialized on every path.
        unsafe { *out_engine = std::ptr::null_mut() };
        if abi_version != ABI_VERSION
            || model_path.is_null()
            || model_path_length == 0
            || model_path_length > MAX_MODEL_PATH_BYTES
        {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: caller supplies a readable buffer for the stated length.
        let bytes = unsafe { slice::from_raw_parts(model_path, model_path_length) };
        let Ok(path) = str::from_utf8(bytes) else {
            return STATUS_INVALID_ARGUMENT;
        };
        let Ok(manifest) = bundled_private_beta_manifest() else {
            return STATUS_NOT_READY;
        };
        if verify_model_artifact(&manifest, Path::new(path)).is_err() {
            return STATUS_NOT_READY;
        }
        let Ok(backend) = NativeLlamaBackend::create(CAbiLlamaApi) else {
            return STATUS_NOT_READY;
        };
        let provider = Arc::new(LlamaCppProvider::new(backend, "mobile-llama.cpp", 16_000));
        if provider.load(Path::new(path)).is_err() {
            return STATUS_NOT_READY;
        }
        let engine = Box::new(NativeMobileEngine {
            core: MobileConversationCore::new(Arc::clone(&provider), Duration::from_secs(30)),
            provider,
            pending: Mutex::new(None),
        });
        // SAFETY: out_engine was validated and receives ownership of the boxed engine.
        unsafe { *out_engine = Box::into_raw(engine).cast() };
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_generate_local(
        engine: *mut c_void,
        age_band: u8,
        alias: *const u8,
        alias_length: usize,
        text: *const u8,
        text_length: usize,
        guidance: *const u8,
        guidance_length: usize,
        output: *mut u8,
        output_length: usize,
        out_required: *mut usize,
        out_suggest_trusted_adult: *mut bool,
    ) -> i32 {
        let Some(pointer) = NonNull::new(engine.cast::<NativeMobileEngine>()) else {
            return STATUS_INVALID_ARGUMENT;
        };
        if alias.is_null()
            || alias_length == 0
            || alias_length > MAX_ALIAS_BYTES
            || text.is_null()
            || text_length == 0
            || text_length > MAX_TEXT_BYTES
            || guidance_length > MAX_GUIDANCE_BYTES
            || (guidance_length > 0 && guidance.is_null())
            || out_required.is_null()
        {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: validated engine originated from pp_mobile_engine_create.
        let engine = unsafe { pointer.as_ref() };
        let Ok(mut pending) = engine.pending.lock() else {
            return STATUS_GENERATION_FAILED;
        };
        if pending.is_none() {
            // SAFETY: caller supplies readable UTF-8 buffers for their stated lengths.
            let alias_bytes = unsafe { slice::from_raw_parts(alias, alias_length) };
            // SAFETY: caller supplies readable UTF-8 buffers for their stated lengths.
            let text_bytes = unsafe { slice::from_raw_parts(text, text_length) };
            let guidance_bytes = if guidance_length == 0 {
                &[][..]
            } else {
                // SAFETY: caller supplies a readable UTF-8 buffer for the stated length.
                unsafe { slice::from_raw_parts(guidance, guidance_length) }
            };
            let (Ok(alias), Ok(text), Ok(guidance)) = (
                str::from_utf8(alias_bytes),
                str::from_utf8(text_bytes),
                str::from_utf8(guidance_bytes),
            ) else {
                return STATUS_INVALID_ARGUMENT;
            };
            let age_band = match age_band {
                0 => AgeBand::FourToFive,
                1 => AgeBand::SixToEight,
                2 => AgeBand::NineToTwelve,
                _ => return STATUS_INVALID_ARGUMENT,
            };
            match engine.core.generate_local(
                age_band,
                alias.to_owned(),
                text.to_owned(),
                (!guidance.is_empty()).then(|| guidance.to_owned()),
            ) {
                Ok(response) => *pending = Some(response),
                Err(MobileBridgeError::Policy) => return STATUS_POLICY_BLOCKED,
                Err(MobileBridgeError::Provider) => return STATUS_GENERATION_FAILED,
            }
        }
        let response = pending.as_ref().expect("pending response was populated");
        // SAFETY: out_required was checked non-null.
        unsafe { *out_required = response.speech.len() };
        if output.is_null() || output_length < response.speech.len() {
            return STATUS_BUFFER_TOO_SMALL;
        }
        // SAFETY: caller supplied a writable output buffer of sufficient length.
        unsafe {
            std::ptr::copy_nonoverlapping(response.speech.as_ptr(), output, response.speech.len());
            if !out_suggest_trusted_adult.is_null() {
                *out_suggest_trusted_adult = response.suggest_trusted_adult;
            }
        }
        *pending = None;
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_cancel(engine: *mut c_void) -> i32 {
        let Some(pointer) = NonNull::new(engine.cast::<NativeMobileEngine>()) else {
            return STATUS_INVALID_ARGUMENT;
        };
        // SAFETY: validated engine originated from pp_mobile_engine_create.
        let engine = unsafe { pointer.as_ref() };
        if engine.provider.cancel().is_err() {
            return STATUS_GENERATION_FAILED;
        }
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_clear_session(engine: *mut c_void) -> i32 {
        let Some(pointer) = NonNull::new(engine.cast::<NativeMobileEngine>()) else {
            return STATUS_INVALID_ARGUMENT;
        };
        // SAFETY: validated engine originated from pp_mobile_engine_create.
        let engine = unsafe { pointer.as_ref() };
        if engine.core.clear_session().is_err() {
            return STATUS_GENERATION_FAILED;
        }
        let Ok(mut pending) = engine.pending.lock() else {
            return STATUS_GENERATION_FAILED;
        };
        *pending = None;
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_install_bundled_model(
        destination_directory: *const u8,
        destination_directory_length: usize,
    ) -> i32 {
        if destination_directory.is_null()
            || destination_directory_length == 0
            || destination_directory_length > MAX_MODEL_PATH_BYTES
        {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: caller supplies a readable UTF-8 buffer for the stated length.
        let bytes =
            unsafe { slice::from_raw_parts(destination_directory, destination_directory_length) };
        let Ok(directory) = str::from_utf8(bytes) else {
            return STATUS_INVALID_ARGUMENT;
        };
        let Ok(manifest) = bundled_private_beta_manifest() else {
            return STATUS_GENERATION_FAILED;
        };
        MODEL_INSTALL_CANCELLED.store(false, Ordering::Release);
        match ProductionModelDownloader.download_cancellable(
            &manifest,
            Path::new(directory),
            Duration::from_secs(7_200),
            || MODEL_INSTALL_CANCELLED.load(Ordering::Acquire),
        ) {
            Ok(_) => STATUS_OK,
            Err(LifecycleError::Cancelled) => STATUS_CANCELLED,
            Err(_) => STATUS_GENERATION_FAILED,
        }
    }

    #[no_mangle]
    pub extern "C" fn pp_mobile_cancel_model_install() {
        MODEL_INSTALL_CANCELLED.store(true, Ordering::Release);
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_verify_bundled_model(
        model_path: *const u8,
        model_path_length: usize,
    ) -> i32 {
        if model_path.is_null()
            || model_path_length == 0
            || model_path_length > MAX_MODEL_PATH_BYTES
        {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: caller supplies a readable UTF-8 buffer for the stated length.
        let bytes = unsafe { slice::from_raw_parts(model_path, model_path_length) };
        let Ok(path) = str::from_utf8(bytes) else {
            return STATUS_INVALID_ARGUMENT;
        };
        let Ok(manifest) = bundled_private_beta_manifest() else {
            return STATUS_GENERATION_FAILED;
        };
        if verify_model_artifact(&manifest, Path::new(path)).is_ok() {
            STATUS_OK
        } else {
            STATUS_NOT_READY
        }
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_engine_destroy(engine: *mut c_void) {
        if !engine.is_null() {
            // SAFETY: ownership is returned exactly once by the caller.
            drop(unsafe { Box::from_raw(engine.cast::<NativeMobileEngine>()) });
        }
    }
}

#[cfg(not(feature = "native-runtime"))]
mod native_ffi {
    use std::{ffi::c_void, ptr};

    const STATUS_OK: i32 = 0;
    const STATUS_INVALID_ARGUMENT: i32 = 1;
    const STATUS_NOT_READY: i32 = 2;
    const ABI_VERSION: u32 = 2;

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_engine_create(
        abi_version: u32,
        model_path: *const u8,
        model_path_length: usize,
        out_engine: *mut *mut c_void,
    ) -> i32 {
        if out_engine.is_null() {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out_engine was validated and is initialized before returning.
        unsafe { *out_engine = ptr::null_mut() };
        if abi_version != ABI_VERSION || model_path.is_null() || model_path_length == 0 {
            return STATUS_INVALID_ARGUMENT;
        }
        STATUS_NOT_READY
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_generate_local(
        _engine: *mut c_void,
        _age_band: u8,
        _alias: *const u8,
        _alias_length: usize,
        _text: *const u8,
        _text_length: usize,
        _guidance: *const u8,
        _guidance_length: usize,
        _output: *mut u8,
        _output_length: usize,
        out_required: *mut usize,
        _out_suggest_trusted_adult: *mut bool,
    ) -> i32 {
        if !out_required.is_null() {
            // SAFETY: out_required was checked non-null.
            unsafe { *out_required = 0 };
        }
        STATUS_NOT_READY
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_cancel(_engine: *mut c_void) -> i32 {
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_clear_session(_engine: *mut c_void) -> i32 {
        STATUS_OK
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_install_bundled_model(
        destination_directory: *const u8,
        destination_directory_length: usize,
    ) -> i32 {
        if destination_directory.is_null() || destination_directory_length == 0 {
            return STATUS_INVALID_ARGUMENT;
        }
        STATUS_NOT_READY
    }

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_verify_bundled_model(
        model_path: *const u8,
        model_path_length: usize,
    ) -> i32 {
        if model_path.is_null() || model_path_length == 0 {
            return STATUS_INVALID_ARGUMENT;
        }
        STATUS_NOT_READY
    }

    #[no_mangle]
    pub extern "C" fn pp_mobile_cancel_model_install() {}

    #[no_mangle]
    pub unsafe extern "C" fn pp_mobile_engine_destroy(_engine: *mut c_void) {}
}

#[cfg(test)]
mod tests {
    use plushpal_core_domain::BoundedConversationRequest;
    use plushpal_provider_api::{ConversationCapabilities, ProviderFuture};

    use super::*;

    #[derive(Debug)]
    struct FixtureProvider;

    impl ConversationProvider for FixtureProvider {
        fn capabilities(&self) -> ConversationCapabilities {
            ConversationCapabilities {
                provider_id: "fixture".to_owned(),
                local: true,
                supports_structured_output: true,
                maximum_context_characters: 4_096,
            }
        }

        fn generate(
            &self,
            _request: BoundedConversationRequest,
            _deadline: Duration,
        ) -> ProviderFuture<'_> {
            Box::pin(async {
                Ok(StructuredCharacterResponse {
                    speech: "Hello from the shared core.".to_owned(),
                    suggest_trusted_adult: false,
                })
            })
        }
    }

    #[test]
    fn mobile_core_uses_the_same_local_safety_orchestrator() {
        let core = MobileConversationCore::new(FixtureProvider, Duration::from_secs(1));
        assert_eq!(
            core.generate_local(
                AgeBand::SixToEight,
                "Teddy".to_owned(),
                "Hello".to_owned(),
                Some("Use nature examples.".to_owned()),
            )
            .unwrap()
            .speech,
            "Hello from the shared core."
        );
        assert_eq!(
            core.generate_local(
                AgeBand::SixToEight,
                "Teddy".to_owned(),
                "x".repeat(451),
                None,
            ),
            Err(MobileBridgeError::Policy)
        );
    }
}
