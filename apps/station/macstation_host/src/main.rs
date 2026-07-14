#![forbid(unsafe_code)]

#[cfg(feature = "native-runtime")]
use std::collections::HashSet;
use std::{
    env,
    net::{IpAddr, Ipv4Addr},
    process::Command,
    sync::Arc,
};

#[cfg(feature = "native-runtime")]
use std::path::PathBuf;

use plushpal_desktop_gateway::LoopbackEndpoint;
#[cfg(feature = "native-runtime")]
use plushpal_desktop_host::ParentProfileStore;
use plushpal_desktop_host::{build_router, HostState, OsTokenSource, SystemClock, TokenSource};
#[cfg(feature = "native-runtime")]
use plushpal_desktop_host::{configured_gemini_model, configured_openai_model};
use tokio::net::TcpListener;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum RuntimeMode {
    Custom,
    Mock,
    Demo,
    LocalVoice,
    PrivacyLocalFirst,
    CloudLlm,
    Cloud,
    Full,
}

impl RuntimeMode {
    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn from_env() -> Self {
        Self::parse(env::var("PLUSHPAL_RUNTIME_MODE").ok().as_deref())
    }

    fn parse(value: Option<&str>) -> Self {
        match value {
            Some(value) => match value.trim().to_ascii_lowercase().as_str() {
                "" => Self::Custom,
                "mock" => Self::Mock,
                "demo" => Self::Demo,
                "local_voice" | "local-voice" => Self::LocalVoice,
                "privacy_local_first" | "privacy-local-first" | "local_first" | "local-first" => {
                    Self::PrivacyLocalFirst
                }
                "cloud_llm" | "cloud-llm" => Self::CloudLlm,
                "cloud" => Self::Cloud,
                "full" => Self::Full,
                other => {
                    eprintln!(
                        "Unknown PLUSHPAL_RUNTIME_MODE={other}; falling back to custom environment."
                    );
                    Self::Custom
                }
            },
            None => Self::Custom,
        }
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn default_voice_engine(self) -> Option<&'static str> {
        match self {
            Self::Mock | Self::Demo => Some("demo"),
            Self::LocalVoice
            | Self::PrivacyLocalFirst
            | Self::CloudLlm
            | Self::Cloud
            | Self::Full => Some("luxtts"),
            Self::Custom => None,
        }
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn uses_demo_conversation(self) -> bool {
        matches!(self, Self::Mock | Self::Demo | Self::LocalVoice)
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn suppress_cloud_and_local_model(self) -> bool {
        matches!(self, Self::Mock | Self::Demo | Self::LocalVoice)
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn cloud_allowed(self) -> bool {
        !matches!(
            self,
            Self::PrivacyLocalFirst | Self::Mock | Self::Demo | Self::LocalVoice
        )
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn local_model_allowed(self) -> bool {
        !matches!(
            self,
            Self::CloudLlm | Self::Cloud | Self::Mock | Self::Demo | Self::LocalVoice
        )
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn prefers_cloud(self) -> bool {
        matches!(
            self,
            Self::CloudLlm | Self::Cloud | Self::Custom | Self::Full
        )
    }

    #[cfg_attr(not(feature = "native-runtime"), allow(dead_code))]
    fn as_str(self) -> &'static str {
        match self {
            Self::Custom => "custom",
            Self::Mock => "mock",
            Self::Demo => "demo",
            Self::LocalVoice => "local_voice",
            Self::PrivacyLocalFirst => "privacy_local_first",
            Self::CloudLlm | Self::Cloud => "cloud_llm",
            Self::Full => "full",
        }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let requested_port = match env::var("PLUSHPAL_PORT") {
        Ok(value) => value.parse::<u16>()?,
        Err(_) => 0,
    };
    let lan_host = env::var("PLUSHPAL_LAN_HOST")
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    let lan_enabled = env::var_os("PLUSHPAL_ENABLE_LAN").is_some() && lan_host.is_some();
    let bind_address = if lan_enabled {
        IpAddr::V4(Ipv4Addr::UNSPECIFIED)
    } else {
        IpAddr::V4(Ipv4Addr::LOCALHOST)
    };
    let listener = TcpListener::bind((bind_address, requested_port)).await?;
    let port = listener.local_addr()?.port();
    let endpoint = LoopbackEndpoint { port };
    let token_source = Arc::new(OsTokenSource);
    let bootstrap_random = token_source
        .generate()
        .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
    let bootstrap = hex::encode(bootstrap_random);
    let mut state = HostState::new(
        endpoint,
        bootstrap.as_bytes(),
        token_source.clone(),
        Arc::new(SystemClock),
    );
    let public_host_header = lan_host.map(|host| format!("{host}:{port}"));
    if let Some(host_header) = public_host_header.as_deref() {
        state = state.with_additional_gateway_host(host_header.to_owned());
    }
    #[cfg(feature = "native-runtime")]
    let state = {
        use plushpal_desktop_host::native_runtime::{
            BraveWebSearchProvider, ChatterboxVoiceEngine, DemoConversationEngine, DemoVoiceEngine,
            GeminiConversationEngine, LuxTtsVoiceEngine, MiniLmSearchRouter,
            NativeConversationEngine, NativeModelInstaller, NativeParentProfileStore,
            OpenAiConversationEngine, PocketVoiceEngine, WhisperCliSpeechToTextEngine,
        };
        let runtime_mode = RuntimeMode::from_env();
        eprintln!("ToyTalk Hub runtime mode: {runtime_mode:?}");
        let hub_client_id = env::var("PLUSHPAL_HUB_CLIENT_ID")
            .unwrap_or_else(|_| "hub-00000000-0000-0000-0000-000000000000".to_owned());
        let state = state
            .with_runtime_mode(runtime_mode.as_str())
            .with_hub_client_id(hub_client_id.clone())
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        let data_directory = application_data_directory()?;
        let profile_key = token_source
            .generate()
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        let profile_store = NativeParentProfileStore::open(&data_directory, profile_key)
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        if let Err(error) = profile_store.preflight_keychain_access() {
            eprintln!(
                "ToyTalk Hub voice preflight did not complete; existing voice profiles may need to be re-created: {error:?}"
            );
        }
        let profile_store = Arc::new(profile_store);
        let recommendation = local_model_recommendation_from_env();
        if let Some((model_id, note)) = &recommendation {
            eprintln!("ToyTalk Hub local AI recommendation: {model_id}; {note}");
        }
        let installer = Arc::new(
            NativeModelInstaller::new_with_recommendation(
                model_directory()?,
                recommendation
                    .as_ref()
                    .map(|(model_id, _)| model_id.clone()),
                recommendation.as_ref().map(|(_, note)| note.clone()),
            )
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?,
        );
        let configured = env::var_os("PLUSHPAL_MODEL_PATH").map(PathBuf::from);
        let model_path = if let Some(path) = configured {
            NativeModelInstaller::verify_model_path(&path)
                .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
            Some(path)
        } else {
            installer
                .verified_installed_model_path()
                .map_err(|error| std::io::Error::other(format!("{error:?}")))?
        };
        let mut state = state
            .with_model_installer(installer)
            .with_parent_profile_store(profile_store.clone())
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        let hub_profile_store = profile_store
            .scoped_store(Some(&hub_client_id))
            .ok()
            .flatten();
        let legacy_cloud_provider = saved_provider_from_store(profile_store.as_ref());
        let saved_cloud_provider = if let Some(hub_store) = hub_profile_store.as_deref() {
            saved_provider_from_store(hub_store).or_else(|| {
                let (provider, api_key) = legacy_cloud_provider.clone()?;
                let _ = hub_store.save_provider_api_key(&provider, &api_key);
                let _ = hub_store.select_provider(&provider);
                Some((provider, api_key))
            })
        } else {
            legacy_cloud_provider
        };
        let requested_voice_engine = env::var("PLUSHPAL_VOICE_ENGINE").unwrap_or_else(|_| {
            runtime_mode
                .default_voice_engine()
                .unwrap_or_default()
                .to_owned()
        });
        if requested_voice_engine.eq_ignore_ascii_case("demo") {
            state = state.with_voice_engine(Arc::new(DemoVoiceEngine));
            eprintln!("ToyTalk Hub demo voice engine enabled; this validates flow but does not clone voices.");
        } else if requested_voice_engine.eq_ignore_ascii_case("luxtts") {
            let python_executable = env::var_os("PLUSHPAL_LUXTTS_PYTHON")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("python3"));
            let script_path = env::var_os("PLUSHPAL_LUXTTS_SCRIPT")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    env::current_dir()
                        .unwrap_or_else(|_| PathBuf::from("."))
                        .join("tools/voice/luxtts_tts.py")
                });
            let model =
                env::var("PLUSHPAL_LUXTTS_MODEL").unwrap_or_else(|_| "YatharthS/LuxTTS".to_owned());
            let device = env::var("PLUSHPAL_LUXTTS_DEVICE").unwrap_or_else(|_| "mps".to_owned());
            let threads = env::var("PLUSHPAL_LUXTTS_THREADS").unwrap_or_else(|_| "4".to_owned());
            let ref_duration =
                env::var("PLUSHPAL_LUXTTS_REF_DURATION").unwrap_or_else(|_| "180".to_owned());
            let rms = env::var("PLUSHPAL_LUXTTS_RMS").unwrap_or_else(|_| "0.01".to_owned());
            let num_steps =
                env::var("PLUSHPAL_LUXTTS_NUM_STEPS").unwrap_or_else(|_| "4".to_owned());
            let t_shift = env::var("PLUSHPAL_LUXTTS_T_SHIFT").unwrap_or_else(|_| "0.9".to_owned());
            let speed = env::var("PLUSHPAL_LUXTTS_SPEED").unwrap_or_else(|_| "0.88".to_owned());
            let seed = env::var("PLUSHPAL_LUXTTS_SEED")
                .ok()
                .or_else(|| Some("11".to_owned()));
            let return_smooth = env::var_os("PLUSHPAL_LUXTTS_RETURN_SMOOTH").is_some();
            match LuxTtsVoiceEngine::new(
                python_executable,
                script_path,
                &data_directory,
                model,
                device,
                threads,
                ref_duration,
                rms,
                num_steps,
                t_shift,
                speed,
                seed,
                return_smooth,
            ) {
                Ok(voice_engine) => {
                    state = state.with_voice_engine(Arc::new(voice_engine));
                }
                Err(error) => {
                    eprintln!(
                        "ToyTalk Hub LuxTTS voice runtime is unavailable; starting without voice cloning: {error:?}"
                    );
                }
            }
        } else if requested_voice_engine.eq_ignore_ascii_case("chatterbox") {
            let python_executable = env::var_os("PLUSHPAL_CHATTERBOX_PYTHON")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("python3"));
            let script_path = env::var_os("PLUSHPAL_CHATTERBOX_SCRIPT")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    env::current_dir()
                        .unwrap_or_else(|_| PathBuf::from("."))
                        .join("tools/voice/chatterbox_tts.py")
                });
            let engine_name =
                env::var("PLUSHPAL_CHATTERBOX_ENGINE").unwrap_or_else(|_| "standard".to_owned());
            let device =
                env::var("PLUSHPAL_CHATTERBOX_DEVICE").unwrap_or_else(|_| "auto".to_owned());
            let language =
                env::var("PLUSHPAL_CHATTERBOX_LANGUAGE").unwrap_or_else(|_| "en".to_owned());
            let exaggeration =
                env::var("PLUSHPAL_CHATTERBOX_EXAGGERATION").unwrap_or_else(|_| "0.68".to_owned());
            let cfg_weight =
                env::var("PLUSHPAL_CHATTERBOX_CFG_WEIGHT").unwrap_or_else(|_| "0.45".to_owned());
            let temperature =
                env::var("PLUSHPAL_CHATTERBOX_TEMPERATURE").unwrap_or_else(|_| "0.68".to_owned());
            let min_p = env::var("PLUSHPAL_CHATTERBOX_MIN_P").unwrap_or_else(|_| "0.05".to_owned());
            let top_p = env::var("PLUSHPAL_CHATTERBOX_TOP_P").unwrap_or_else(|_| "0.90".to_owned());
            let repetition_penalty = env::var("PLUSHPAL_CHATTERBOX_REPETITION_PENALTY")
                .unwrap_or_else(|_| "1.2".to_owned());
            match ChatterboxVoiceEngine::new(
                python_executable,
                script_path,
                &data_directory,
                engine_name,
                device,
                language,
                exaggeration,
                cfg_weight,
                temperature,
                min_p,
                top_p,
                repetition_penalty,
            ) {
                Ok(voice_engine) => {
                    state = state.with_voice_engine(Arc::new(voice_engine));
                }
                Err(error) => {
                    eprintln!(
                        "ToyTalk Hub Chatterbox voice runtime is unavailable; starting without voice cloning: {error:?}"
                    );
                }
            }
        } else {
            let voice_model_directory = env::var_os("PLUSHPAL_TTS_MODEL_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| data_directory.join("models/pocket-tts"));
            if voice_model_directory.is_dir() {
                let voice_engine = PocketVoiceEngine::load(&voice_model_directory, &data_directory)
                    .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
                state = state.with_voice_engine(Arc::new(voice_engine));
            }
        }
        if let Some(command_path) = env::var_os("PLUSHPAL_STT_COMMAND").map(PathBuf::from) {
            match WhisperCliSpeechToTextEngine::new(command_path, &data_directory) {
                Ok(engine) => {
                    eprintln!("ToyTalk Hub local listening fallback enabled.");
                    state = state.with_speech_to_text_engine(Arc::new(engine));
                }
                Err(error) => {
                    eprintln!(
                        "ToyTalk Hub local listening fallback is unavailable; native clients must use verified on-device listening: {error:?}"
                    );
                }
            }
        }
        if let (Some(python_executable), Some(script_path)) = (
            env::var_os("PLUSHPAL_SEARCH_ROUTER_PYTHON").map(PathBuf::from),
            env::var_os("PLUSHPAL_SEARCH_ROUTER_SCRIPT").map(PathBuf::from),
        ) {
            let model = env::var("PLUSHPAL_SEARCH_ROUTER_MODEL")
                .unwrap_or_else(|_| "sentence-transformers/all-MiniLM-L6-v2".to_owned());
            match MiniLmSearchRouter::new(python_executable, script_path, &data_directory, model) {
                Ok(router) => {
                    eprintln!("ToyTalk Hub search router enabled.");
                    state = state.with_search_router(Arc::new(router));
                }
                Err(error) => {
                    eprintln!(
                        "ToyTalk Hub search router is unavailable; using conservative keyword fallback: {error:?}"
                    );
                }
            }
        }
        if let Some(api_key) = brave_search_api_key() {
            match BraveWebSearchProvider::new(api_key) {
                Ok(provider) => {
                    eprintln!("ToyTalk Hub-owned web search enabled with Brave Search.");
                    state = state.with_web_search_provider(Arc::new(provider));
                }
                Err(error) => {
                    eprintln!(
                        "ToyTalk Hub-owned web search is unavailable; Local AI current-info questions will fail safe: {error:?}"
                    );
                }
            }
        } else {
            eprintln!(
                "ToyTalk Hub-owned web search is not configured. Set TOYTALK_BRAVE_SEARCH_API_KEY or PLUSHPAL_BRAVE_SEARCH_API_KEY to let Local AI answer current-info questions with search evidence."
            );
        }
        if runtime_mode.uses_demo_conversation() {
            eprintln!(
                "ToyTalk Hub demo conversation engine enabled; no cloud reasoning calls will be made."
            );
            state = state.with_conversation_engine(Arc::new(DemoConversationEngine));
        } else if !runtime_mode.suppress_cloud_and_local_model() {
            let mut loaded_conversation = false;
            if runtime_mode.prefers_cloud() && runtime_mode.cloud_allowed() {
                if let Some((provider, api_key)) =
                    saved_cloud_provider.clone().or_else(cloud_provider_api_key)
                {
                    match provider.as_str() {
                        "openai" => {
                            let model = configured_openai_model();
                            match OpenAiConversationEngine::new(api_key, model.clone()) {
                                Ok(engine) => {
                                    eprintln!(
                                        "ToyTalk Hub OpenAI reasoning enabled with model {model}"
                                    );
                                    state = state.with_conversation_engine(Arc::new(engine));
                                    loaded_conversation = true;
                                }
                                Err(error) => {
                                    eprintln!(
                                        "ToyTalk Hub OpenAI reasoning is unavailable: {error:?}"
                                    );
                                }
                            }
                        }
                        _ => {
                            let model = configured_gemini_model();
                            match GeminiConversationEngine::new(api_key, model.clone()) {
                                Ok(engine) => {
                                    eprintln!(
                                        "ToyTalk Hub Gemini reasoning enabled with model {model}"
                                    );
                                    state = state.with_conversation_engine(Arc::new(engine));
                                    loaded_conversation = true;
                                }
                                Err(error) => {
                                    eprintln!(
                                        "ToyTalk Hub Gemini reasoning is unavailable: {error:?}"
                                    );
                                }
                            }
                        }
                    }
                }
            }
            if !loaded_conversation && runtime_mode.local_model_allowed() {
                if let Some(model_path) = model_path.as_ref() {
                    match NativeConversationEngine::load(model_path) {
                        Ok(engine) => {
                            state = state.with_conversation_engine(Arc::new(engine));
                            loaded_conversation = true;
                        }
                        Err(error) => {
                            eprintln!(
                                "ToyTalk Hub local conversation model is unavailable: {error:?}"
                            );
                        }
                    }
                }
            }
            if !loaded_conversation && !runtime_mode.prefers_cloud() && runtime_mode.cloud_allowed()
            {
                if let Some((provider, api_key)) =
                    saved_cloud_provider.clone().or_else(cloud_provider_api_key)
                {
                    match provider.as_str() {
                        "openai" => {
                            let model = configured_openai_model();
                            match OpenAiConversationEngine::new(api_key, model.clone()) {
                                Ok(engine) => {
                                    eprintln!(
                                        "ToyTalk Hub OpenAI reasoning enabled with model {model}"
                                    );
                                    state = state.with_conversation_engine(Arc::new(engine));
                                }
                                Err(error) => {
                                    eprintln!(
                                        "ToyTalk Hub OpenAI reasoning is unavailable: {error:?}"
                                    );
                                }
                            }
                        }
                        _ => {
                            let model = configured_gemini_model();
                            match GeminiConversationEngine::new(api_key, model.clone()) {
                                Ok(engine) => {
                                    eprintln!(
                                        "ToyTalk Hub Gemini reasoning enabled with model {model}"
                                    );
                                    state = state.with_conversation_engine(Arc::new(engine));
                                }
                                Err(error) => {
                                    eprintln!(
                                        "ToyTalk Hub Gemini reasoning is unavailable: {error:?}"
                                    );
                                }
                            }
                        }
                    }
                }
            }
        }
        state
    };
    let url = format!("{}/#bootstrap={}", endpoint.origin(false), bootstrap);
    println!("ToyTalk Hub listening on {}", endpoint.origin(false));
    if env::var_os("PLUSHPAL_PRINT_BOOTSTRAP_URL").is_some() {
        println!("ToyTalk Hub test bootstrap URL: {url}");
        if let Some(host_header) = public_host_header {
            println!("ToyTalk Hub LAN bootstrap URL: http://{host_header}/#bootstrap={bootstrap}");
        }
    }
    if env::var_os("PLUSHPAL_NO_BROWSER").is_none() {
        launch_browser(&url);
    }
    axum::serve(listener, build_router(state)).await?;
    Ok(())
}

#[cfg(feature = "native-runtime")]
fn cloud_provider_api_key() -> Option<(String, String)> {
    let provider = env::var("PLUSHPAL_CLOUD_LLM_PROVIDER")
        .ok()
        .map(|value| value.trim().to_ascii_lowercase())
        .filter(|value| matches!(value.as_str(), "gemini" | "openai"))
        .unwrap_or_else(|| "gemini".to_owned());
    match provider.as_str() {
        "openai" => {
            provider_api_key("PLUSHPAL_OPENAI_API_KEY").map(|key| ("openai".to_owned(), key))
        }
        _ => provider_api_key("PLUSHPAL_GEMINI_API_KEY").map(|key| ("gemini".to_owned(), key)),
    }
}

#[cfg(feature = "native-runtime")]
fn saved_provider_from_store(store: &dyn ParentProfileStore) -> Option<(String, String)> {
    store
        .reasoning_provider_status()
        .ok()
        .filter(|status| status.configured)
        .and_then(|status| {
            store
                .load_provider_api_key(&status.provider)
                .ok()
                .flatten()
                .map(|api_key| (status.provider, api_key))
        })
}

#[cfg(feature = "native-runtime")]
fn provider_api_key(env_name: &str) -> Option<String> {
    if let Ok(value) = env::var(env_name) {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_owned());
        }
    }
    None
}

#[cfg(feature = "native-runtime")]
fn brave_search_api_key() -> Option<String> {
    [
        "TOYTALK_BRAVE_SEARCH_API_KEY",
        "PLUSHPAL_BRAVE_SEARCH_API_KEY",
        "BRAVE_SEARCH_API_KEY",
    ]
    .into_iter()
    .find_map(provider_api_key)
    .filter(|value| !value.chars().any(char::is_control))
}

#[cfg(feature = "native-runtime")]
fn model_directory() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(configured) = env::var_os("PLUSHPAL_MODEL_DIR") {
        return Ok(PathBuf::from(configured));
    }
    #[cfg(target_os = "macos")]
    let base = env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join("Library/Application Support"));
    #[cfg(target_os = "windows")]
    let base = env::var_os("LOCALAPPDATA").map(PathBuf::from);
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let base = env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    base.map(|path| path.join("ToyTalk/models"))
        .ok_or_else(|| "No local application data directory is available".into())
}

#[cfg(feature = "native-runtime")]
fn application_data_directory() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(configured) = env::var_os("PLUSHPAL_DATA_DIR") {
        return Ok(PathBuf::from(configured));
    }
    model_directory()?
        .parent()
        .map(PathBuf::from)
        .ok_or_else(|| "No local application data directory is available".into())
}

#[cfg(feature = "native-runtime")]
fn local_model_recommendation_from_env() -> Option<(String, String)> {
    let total_memory_mib = parse_env_u64("PLUSHPAL_DEVICE_TOTAL_MEMORY_MIB")?;
    let available_memory_mib =
        parse_env_u64("PLUSHPAL_DEVICE_AVAILABLE_MEMORY_MIB").unwrap_or(total_memory_mib);
    let free_storage_mib = parse_env_u64("PLUSHPAL_DEVICE_FREE_STORAGE_MIB").unwrap_or(0);
    let logical_cores = parse_env_u64("PLUSHPAL_DEVICE_LOGICAL_CORES")
        .and_then(|value| u16::try_from(value).ok())
        .unwrap_or(1);
    let os_major = parse_env_u64("PLUSHPAL_DEVICE_OS_MAJOR")
        .and_then(|value| u16::try_from(value).ok())
        .unwrap_or(13);
    local_model_recommendation_for_profile(
        total_memory_mib,
        available_memory_mib,
        free_storage_mib,
        logical_cores,
        os_major,
        &env::var("PLUSHPAL_DEVICE_ARCH").unwrap_or_default(),
        &env::var("PLUSHPAL_DEVICE_ACCELERATION").unwrap_or_default(),
    )
}

#[cfg(feature = "native-runtime")]
fn local_model_recommendation_for_profile(
    total_memory_mib: u64,
    available_memory_mib: u64,
    free_storage_mib: u64,
    logical_cores: u16,
    os_major: u16,
    architecture_name: &str,
    acceleration_name: &str,
) -> Option<(String, String)> {
    let architecture = match architecture_name.trim().to_ascii_lowercase().as_str() {
        "x86_64" | "amd64" => plushpal_device_capability::Architecture::X86_64,
        _ => plushpal_device_capability::Architecture::Arm64,
    };
    let acceleration = match acceleration_name.trim().to_ascii_lowercase().as_str() {
        "metal" => plushpal_device_capability::Acceleration::Metal,
        "vulkan" => plushpal_device_capability::Acceleration::Vulkan,
        _ => plushpal_device_capability::Acceleration::None,
    };
    let device = plushpal_device_capability::DeviceProfile {
        platform: plushpal_device_capability::Platform::MacOs,
        architecture,
        os_major,
        total_memory_mib,
        // macOS "available" memory is highly transient and includes pressure/reclaim behavior
        // that can make a capable Apple Silicon Mac look temporarily ineligible. Local model
        // tiering is based on stable hardware configuration; loading failures are still handled
        // by the runtime and users can switch to cloud mode if memory pressure is real.
        available_memory_mib: total_memory_mib,
        free_storage_mib,
        logical_cores,
        acceleration,
    };
    let installable_model_ids = plushpal_model_lifecycle::trusted_private_beta_manifests()
        .ok()?
        .into_iter()
        .map(|manifest| manifest.model_id)
        .collect::<HashSet<_>>();
    let installable_candidates = plushpal_device_capability::initial_model_candidates()
        .into_iter()
        .filter(|candidate| installable_model_ids.contains(&candidate.model_id))
        .collect::<Vec<_>>();
    let assessment = plushpal_device_capability::CapabilityAssessor::default()
        .assess(&device, &installable_candidates);
    let recommended = assessment.recommended_model_id?;
    let note = format!(
        "Mac profile: {} MiB total memory, {} MiB available memory, {} MiB free storage, {} cores, {:?} acceleration.",
        total_memory_mib, available_memory_mib, free_storage_mib, logical_cores, acceleration
    );
    Some((recommended, note))
}

#[cfg(feature = "native-runtime")]
fn parse_env_u64(name: &str) -> Option<u64> {
    env::var(name).ok()?.trim().parse().ok()
}

fn launch_browser(url: &str) {
    #[cfg(target_os = "macos")]
    let mut command = Command::new("open");
    #[cfg(target_os = "linux")]
    let mut command = Command::new("xdg-open");
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", ""]);
        command
    };
    let _ = command.arg(url).spawn();
}

#[cfg(test)]
mod tests {
    use super::RuntimeMode;

    #[cfg(feature = "native-runtime")]
    use super::local_model_recommendation_for_profile;

    #[test]
    fn runtime_mode_defaults_to_custom() {
        assert_eq!(RuntimeMode::parse(None), RuntimeMode::Custom);
        assert_eq!(RuntimeMode::parse(Some("")), RuntimeMode::Custom);
        assert_eq!(RuntimeMode::parse(Some("unknown")), RuntimeMode::Custom);
    }

    #[test]
    fn runtime_mode_parses_supported_modes() {
        assert_eq!(RuntimeMode::parse(Some("mock")), RuntimeMode::Mock);
        assert_eq!(RuntimeMode::parse(Some("demo")), RuntimeMode::Demo);
        assert_eq!(
            RuntimeMode::parse(Some("local-voice")),
            RuntimeMode::LocalVoice
        );
        assert_eq!(
            RuntimeMode::parse(Some("local_voice")),
            RuntimeMode::LocalVoice
        );
        assert_eq!(
            RuntimeMode::parse(Some("privacy-local-first")),
            RuntimeMode::PrivacyLocalFirst
        );
        assert_eq!(
            RuntimeMode::parse(Some("local_first")),
            RuntimeMode::PrivacyLocalFirst
        );
        assert_eq!(RuntimeMode::parse(Some("cloud-llm")), RuntimeMode::CloudLlm);
        assert_eq!(RuntimeMode::parse(Some("cloud")), RuntimeMode::Cloud);
        assert_eq!(RuntimeMode::parse(Some("full")), RuntimeMode::Full);
    }

    #[test]
    fn runtime_mode_selects_safe_defaults() {
        assert_eq!(RuntimeMode::Mock.default_voice_engine(), Some("demo"));
        assert_eq!(RuntimeMode::Demo.default_voice_engine(), Some("demo"));
        assert_eq!(RuntimeMode::Cloud.default_voice_engine(), Some("luxtts"));
        assert_eq!(RuntimeMode::CloudLlm.default_voice_engine(), Some("luxtts"));
        assert_eq!(
            RuntimeMode::PrivacyLocalFirst.default_voice_engine(),
            Some("luxtts")
        );
        assert_eq!(
            RuntimeMode::LocalVoice.default_voice_engine(),
            Some("luxtts")
        );
        assert_eq!(RuntimeMode::Full.default_voice_engine(), Some("luxtts"));
        assert_eq!(RuntimeMode::Custom.default_voice_engine(), None);

        assert!(RuntimeMode::Mock.uses_demo_conversation());
        assert!(RuntimeMode::Demo.uses_demo_conversation());
        assert!(RuntimeMode::LocalVoice.uses_demo_conversation());
        assert!(!RuntimeMode::Cloud.uses_demo_conversation());
        assert!(!RuntimeMode::CloudLlm.uses_demo_conversation());
        assert!(!RuntimeMode::PrivacyLocalFirst.uses_demo_conversation());
        assert!(!RuntimeMode::Full.uses_demo_conversation());
        assert!(!RuntimeMode::PrivacyLocalFirst.cloud_allowed());
        assert!(RuntimeMode::PrivacyLocalFirst.local_model_allowed());
        assert!(RuntimeMode::CloudLlm.cloud_allowed());
        assert!(!RuntimeMode::CloudLlm.local_model_allowed());
    }

    #[cfg(feature = "native-runtime")]
    #[test]
    fn mac_profile_recommends_fast_local_model_on_24gb_macs() {
        let recommendation = local_model_recommendation_for_profile(
            24_576, 4_873, 128_000, 10, 15, "arm64", "metal",
        )
        .expect("24GB Apple Silicon Mac should be eligible for responsive local AI");

        assert_eq!(recommendation.0, "gemma-4-e4b-q4");
        assert!(recommendation.1.contains("24576 MiB total memory"));
        assert!(recommendation.1.contains("4873 MiB available memory"));
        assert!(recommendation.1.contains("Metal acceleration"));
    }

    #[cfg(feature = "native-runtime")]
    #[test]
    fn mac_profile_recommends_latency_first_default_even_on_large_macs() {
        let recommendation = local_model_recommendation_for_profile(
            32_768, 16_384, 128_000, 10, 15, "arm64", "metal",
        )
        .expect("strong Mac profile should be eligible for a local model");

        assert_eq!(recommendation.0, "gemma-4-e4b-q4");
        assert!(recommendation.1.contains("32768 MiB total memory"));
        assert!(recommendation.1.contains("Metal acceleration"));
    }

    #[cfg(feature = "native-runtime")]
    #[test]
    fn mac_profile_falls_back_to_smaller_local_model_on_modest_memory() {
        let recommendation =
            local_model_recommendation_for_profile(12_288, 7_373, 64_000, 8, 14, "arm64", "metal")
                .expect("modest Mac profile should still be eligible for local AI");

        assert_eq!(recommendation.0, "gemma-4-e4b-q4");
    }

    #[cfg(feature = "native-runtime")]
    #[test]
    fn mac_profile_without_metal_does_not_recommend_local_model() {
        let recommendation = local_model_recommendation_for_profile(
            32_768, 16_384, 128_000, 10, 15, "arm64", "none",
        );

        assert!(recommendation.is_none());
    }
}
