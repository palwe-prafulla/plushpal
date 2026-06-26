#![forbid(unsafe_code)]

use std::{
    env,
    net::{IpAddr, Ipv4Addr},
    process::Command,
    sync::Arc,
};

#[cfg(feature = "native-runtime")]
use std::path::PathBuf;

use plushpal_desktop_gateway::LoopbackEndpoint;
use plushpal_desktop_host::{build_router, HostState, OsTokenSource, SystemClock, TokenSource};
use tokio::net::TcpListener;

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
            ChatterboxVoiceEngine, DemoVoiceEngine, GeminiConversationEngine, LuxTtsVoiceEngine,
            NativeConversationEngine, NativeModelInstaller, NativeParentProfileStore,
            PocketVoiceEngine,
        };

        let data_directory = application_data_directory()?;
        let profile_key = token_source
            .generate()
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        let profile_store = NativeParentProfileStore::open(&data_directory, profile_key)
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        if let Err(error) = profile_store.preflight_keychain_access() {
            eprintln!(
                "PlushPal voice keychain preflight did not complete; existing voice profiles may need to be re-created: {error:?}"
            );
        }
        let profile_store = Arc::new(profile_store);
        let installer = Arc::new(NativeModelInstaller::new(model_directory()?));
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
            .with_parent_profile_store(profile_store)
            .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
        let requested_voice_engine = env::var("PLUSHPAL_VOICE_ENGINE").unwrap_or_default();
        if requested_voice_engine.eq_ignore_ascii_case("demo") {
            state = state.with_voice_engine(Arc::new(DemoVoiceEngine));
            eprintln!("PlushPal demo voice engine enabled; this validates flow but does not clone voices.");
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
                env::var("PLUSHPAL_LUXTTS_NUM_STEPS").unwrap_or_else(|_| "8".to_owned());
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
                        "PlushPal local LuxTTS voice runtime is unavailable; starting without voice cloning: {error:?}"
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
                        "PlushPal local Chatterbox voice runtime is unavailable; starting without voice cloning: {error:?}"
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
        if let Some(api_key) = gemini_api_key(&data_directory) {
            let model =
                env::var("PLUSHPAL_GEMINI_MODEL").unwrap_or_else(|_| "gemini-2.5-flash".to_owned());
            match GeminiConversationEngine::new(api_key, model.clone()) {
                Ok(engine) => {
                    eprintln!("PlushPal Gemini reasoning enabled with model {model}");
                    state = state.with_conversation_engine(Arc::new(engine));
                }
                Err(error) => {
                    eprintln!("PlushPal Gemini reasoning is unavailable: {error:?}");
                }
            }
        } else if let Some(model_path) = model_path {
            let engine = NativeConversationEngine::load(&model_path)
                .map_err(|error| std::io::Error::other(format!("{error:?}")))?;
            state = state.with_conversation_engine(Arc::new(engine));
        }
        state
    };
    let url = format!("{}/#bootstrap={}", endpoint.origin(false), bootstrap);
    println!(
        "PlushPal local host listening on {}",
        endpoint.origin(false)
    );
    if env::var_os("PLUSHPAL_PRINT_BOOTSTRAP_URL").is_some() {
        println!("PlushPal test bootstrap URL: {url}");
        if let Some(host_header) = public_host_header {
            println!("PlushPal LAN bootstrap URL: http://{host_header}/#bootstrap={bootstrap}");
        }
    }
    if env::var_os("PLUSHPAL_NO_BROWSER").is_none() {
        launch_browser(&url);
    }
    axum::serve(listener, build_router(state)).await?;
    Ok(())
}

#[cfg(feature = "native-runtime")]
fn gemini_api_key(data_directory: &PathBuf) -> Option<String> {
    if let Ok(value) = env::var("PLUSHPAL_GEMINI_API_KEY") {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_owned());
        }
    }
    if !env_flag_enabled("PLUSHPAL_ENABLE_MAC_KEYCHAIN_GEMINI") {
        return None;
    }
    const GEMINI_API_KEY_REF: &str = "plushpal-gemini-api-key-v1";
    use plushpal_encrypted_storage::{KeyVault, SecretRef};
    use plushpal_platform_key_vault::PlatformKeyVault;

    let vault = PlatformKeyVault;
    let secret_ref = SecretRef(GEMINI_API_KEY_REF.to_owned());
    if let Some(secret) = vault.load(&secret_ref) {
        if let Ok(value) = std::str::from_utf8(secret.expose()) {
            let trimmed = value.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_owned());
            }
        }
    }

    migrate_legacy_gemini_api_key(data_directory, GEMINI_API_KEY_REF)
}

#[cfg(feature = "native-runtime")]
fn env_flag_enabled(name: &str) -> bool {
    env::var(name)
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

#[cfg(feature = "native-runtime")]
fn migrate_legacy_gemini_api_key(data_directory: &PathBuf, key_ref: &str) -> Option<String> {
    use plushpal_platform_key_vault::PlatformKeyVault;

    let key_path = data_directory.join("secrets/gemini_api_key");
    let value = std::fs::read_to_string(&key_path).ok()?;
    let trimmed = value.trim();
    if trimmed.is_empty() {
        let _ = std::fs::remove_file(&key_path);
        return None;
    }
    let mut vault = PlatformKeyVault;
    if vault
        .store_secret(key_ref, trimmed.as_bytes().to_vec())
        .is_ok()
    {
        let _ = std::fs::remove_file(&key_path);
        if let Some(parent) = key_path.parent() {
            let _ = std::fs::remove_dir(parent);
        }
        Some(trimmed.to_owned())
    } else {
        None
    }
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
    base.map(|path| path.join("PlushPal/models"))
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
