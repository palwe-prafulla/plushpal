#![forbid(unsafe_code)]

use std::{
    env, fmt,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, RwLock,
    },
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Body,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        DefaultBodyLimit, Query, Request, State,
    },
    http::{header, HeaderMap, HeaderName, HeaderValue, Method, StatusCode, Uri},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use plushpal_character_voice::{inspect_wav, CharacterProfile, ProfileError, VoiceSampleFacts};
use plushpal_core_domain::{AgeBand, StructuredCharacterResponse};
use plushpal_desktop_gateway::{
    security_headers, GatewayError, GatewayPolicy, LoopbackEndpoint, RequestKind, RequestMetadata,
    SessionSecurity,
};
use plushpal_parent_controls::{ParentGate, ParentPinHash};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

include!(concat!(env!("OUT_DIR"), "/flutter_assets.rs"));

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HostError {
    EntropyUnavailable,
    ClockUnavailable,
    PersistenceUnavailable,
    InvalidPersistedProfile,
    InvalidVoiceSample,
    VoiceUnavailable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PersistedParentProfile {
    pub pin_hash: ParentPinHash,
    pub age_band: AgeBand,
    pub character_alias: String,
    pub character_traits: Vec<String>,
    pub parent_guidance: Option<String>,
    pub retention_days: Option<u16>,
}

pub trait ParentProfileStore: fmt::Debug + Send + Sync {
    fn load(&self) -> Result<Option<PersistedParentProfile>, HostError>;
    fn save(&self, profile: &PersistedParentProfile) -> Result<(), HostError>;
    fn delete_all(&self) -> Result<(), HostError>;
    fn list_characters(&self) -> Result<Vec<CharacterConfiguration>, HostError> {
        Ok(self
            .load()?
            .map(|profile| {
                vec![CharacterConfiguration {
                    alias: profile.character_alias,
                    traits: profile.character_traits,
                    parent_guidance: profile.parent_guidance,
                    voice: VoiceProfileStatus::default(),
                }]
            })
            .unwrap_or_default())
    }
    fn save_character(&self, _character: &CharacterConfiguration) -> Result<(), HostError> {
        Err(HostError::PersistenceUnavailable)
    }
    fn delete_character(&self, _alias: &str) -> Result<(), HostError> {
        Err(HostError::PersistenceUnavailable)
    }
    fn record_turn(
        &self,
        _command: &LocalTurnCommand,
        _response: &StructuredCharacterResponse,
        _completed_at: i64,
    ) -> Result<(), HostError> {
        Ok(())
    }
    fn end_session(&self, _ended_at: i64) -> Result<(), HostError> {
        Ok(())
    }
    fn history(&self, _maximum_turns: usize) -> Result<Vec<ConversationHistoryEntry>, HostError> {
        Ok(Vec::new())
    }
    fn delete_history(&self) -> Result<(), HostError> {
        Ok(())
    }
    fn voice_status(&self) -> Result<VoiceProfileStatus, HostError> {
        Ok(VoiceProfileStatus::default())
    }
    fn voice_status_for_character(&self, _alias: &str) -> Result<VoiceProfileStatus, HostError> {
        Ok(VoiceProfileStatus::default())
    }
    fn store_voice_sample(&self, _wav: &[u8], _facts: VoiceSampleFacts) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn store_voice_sample_for_character(
        &self,
        _alias: &str,
        _wav: &[u8],
        _facts: VoiceSampleFacts,
    ) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn load_voice_sample(&self) -> Result<Vec<u8>, HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn load_voice_sample_for_character(&self, _alias: &str) -> Result<Vec<u8>, HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn approve_voice(&self) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn approve_voice_for_character(&self, _alias: &str) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn delete_voice(&self) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
    fn delete_voice_for_character(&self, _alias: &str) -> Result<(), HostError> {
        Err(HostError::VoiceUnavailable)
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CharacterConfiguration {
    alias: String,
    traits: Vec<String>,
    parent_guidance: Option<String>,
    voice: VoiceProfileStatus,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, Serialize)]
pub struct VoiceProfileStatus {
    enrolled: bool,
    approved: bool,
    runtime_ready: bool,
    duration_milliseconds: Option<u32>,
    profile_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ConversationHistoryEntry {
    child_text: String,
    character_text: String,
    completed_at: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConversationEngineError {
    NotReady,
    InvalidRequest,
    GenerationFailed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelInstallError {
    Unsupported,
    AlreadyInstalling,
    InsufficientStorage,
    DownloadFailed,
    ActivationFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LocalTurnCommand {
    pub age_band: AgeBand,
    pub character_alias: String,
    pub text: String,
    pub parent_guidance: Option<String>,
}

pub trait ConversationEngine: fmt::Debug + Send + Sync {
    fn is_ready(&self) -> bool;
    fn generate_local(
        &self,
        command: LocalTurnCommand,
    ) -> Result<StructuredCharacterResponse, ConversationEngineError>;
    fn cancel(&self) -> Result<(), ConversationEngineError>;
    fn clear_session(&self) -> Result<(), ConversationEngineError>;
}

pub trait VoiceEngine: fmt::Debug + Send + Sync {
    fn is_ready(&self) -> bool;
    fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError>;
}

#[derive(Debug)]
struct UnavailableVoiceEngine;

impl VoiceEngine for UnavailableVoiceEngine {
    fn is_ready(&self) -> bool {
        false
    }

    fn synthesize(&self, _reference_wav: &[u8], _text: &str) -> Result<Vec<u8>, HostError> {
        Err(HostError::VoiceUnavailable)
    }
}

#[derive(Debug)]
struct UnavailableConversationEngine;

impl ConversationEngine for UnavailableConversationEngine {
    fn is_ready(&self) -> bool {
        false
    }
    fn generate_local(
        &self,
        _command: LocalTurnCommand,
    ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
        Err(ConversationEngineError::NotReady)
    }

    fn cancel(&self) -> Result<(), ConversationEngineError> {
        Err(ConversationEngineError::NotReady)
    }

    fn clear_session(&self) -> Result<(), ConversationEngineError> {
        Ok(())
    }
}

pub trait ModelInstaller: fmt::Debug + Send + Sync {
    fn supported(&self) -> bool;
    fn installing(&self) -> bool;
    fn install(&self) -> Result<Arc<dyn ConversationEngine>, ModelInstallError>;
    fn cancel(&self);
}

#[derive(Debug)]
struct UnavailableModelInstaller;

impl ModelInstaller for UnavailableModelInstaller {
    fn supported(&self) -> bool {
        false
    }

    fn installing(&self) -> bool {
        false
    }

    fn install(&self) -> Result<Arc<dyn ConversationEngine>, ModelInstallError> {
        Err(ModelInstallError::Unsupported)
    }

    fn cancel(&self) {}
}

pub trait TokenSource: fmt::Debug + Send + Sync {
    fn generate(&self) -> Result<Vec<u8>, HostError>;
}

pub trait Clock: fmt::Debug + Send + Sync {
    fn now_seconds(&self) -> Result<i64, HostError>;
}

#[derive(Debug)]
pub struct OsTokenSource;

impl TokenSource for OsTokenSource {
    fn generate(&self) -> Result<Vec<u8>, HostError> {
        let mut bytes = [0_u8; 32];
        getrandom::fill(&mut bytes).map_err(|_| HostError::EntropyUnavailable)?;
        Ok(bytes.to_vec())
    }
}

#[derive(Debug)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_seconds(&self) -> Result<i64, HostError> {
        let seconds = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| HostError::ClockUnavailable)?
            .as_secs();
        i64::try_from(seconds).map_err(|_| HostError::ClockUnavailable)
    }
}

#[derive(Clone)]
pub struct HostState {
    policy: GatewayPolicy,
    security: Arc<Mutex<SessionSecurity>>,
    token_source: Arc<dyn TokenSource>,
    clock: Arc<dyn Clock>,
    events: broadcast::Sender<String>,
    conversation: Arc<RwLock<Arc<dyn ConversationEngine>>>,
    model_installer: Arc<dyn ModelInstaller>,
    parent_pin: Arc<Mutex<Option<ParentPinState>>>,
    parent_profile_store: Option<Arc<dyn ParentProfileStore>>,
    voice_engine: Arc<dyn VoiceEngine>,
    voice_synthesis_busy: Arc<AtomicBool>,
    runtime_mode: Arc<str>,
}

#[derive(Debug)]
struct ParentPinState {
    hash: ParentPinHash,
    gate: ParentGate,
}

struct VoiceSynthesisGuard {
    busy: Arc<AtomicBool>,
}

impl Drop for VoiceSynthesisGuard {
    fn drop(&mut self) {
        self.busy.store(false, Ordering::Release);
    }
}

impl fmt::Debug for HostState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostState")
            .field("policy", &self.policy)
            .field("security", &"[REDACTED]")
            .field("token_source", &self.token_source)
            .field("clock", &self.clock)
            .field("events", &"broadcast channel")
            .field("conversation", &self.conversation)
            .field("model_installer", &self.model_installer)
            .field("parent_pin", &"[REDACTED]")
            .field("parent_profile_store", &self.parent_profile_store)
            .field("voice_engine", &self.voice_engine)
            .field(
                "voice_synthesis_busy",
                &self.voice_synthesis_busy.load(Ordering::Acquire),
            )
            .finish()
    }
}

impl HostState {
    #[must_use]
    pub fn new(
        endpoint: LoopbackEndpoint,
        bootstrap_token: &[u8],
        token_source: Arc<dyn TokenSource>,
        clock: Arc<dyn Clock>,
    ) -> Self {
        let (events, _) = broadcast::channel(64);
        Self {
            policy: GatewayPolicy::new(endpoint),
            security: Arc::new(Mutex::new(SessionSecurity::new(bootstrap_token, 5, 600))),
            token_source,
            clock,
            events,
            conversation: Arc::new(RwLock::new(Arc::new(UnavailableConversationEngine))),
            model_installer: Arc::new(UnavailableModelInstaller),
            parent_pin: Arc::new(Mutex::new(None)),
            parent_profile_store: None,
            voice_engine: Arc::new(UnavailableVoiceEngine),
            voice_synthesis_busy: Arc::new(AtomicBool::new(false)),
            runtime_mode: Arc::from("custom"),
        }
    }

    #[must_use]
    pub fn with_runtime_mode(mut self, runtime_mode: impl Into<String>) -> Self {
        self.runtime_mode = Arc::from(runtime_mode.into());
        self
    }

    #[must_use]
    pub fn with_conversation_engine(mut self, engine: Arc<dyn ConversationEngine>) -> Self {
        self.conversation = Arc::new(RwLock::new(engine));
        self
    }

    #[must_use]
    pub fn with_additional_gateway_host(mut self, host_header: impl Into<String>) -> Self {
        self.policy = self.policy.with_additional_http_host(host_header);
        self
    }

    #[must_use]
    pub fn with_model_installer(mut self, installer: Arc<dyn ModelInstaller>) -> Self {
        self.model_installer = installer;
        self
    }

    #[must_use]
    pub fn with_voice_engine(mut self, engine: Arc<dyn VoiceEngine>) -> Self {
        self.voice_engine = engine;
        self
    }

    pub fn with_parent_profile_store(
        mut self,
        store: Arc<dyn ParentProfileStore>,
    ) -> Result<Self, HostError> {
        match store.load() {
            Ok(Some(profile)) => {
                self.parent_pin = Arc::new(Mutex::new(Some(ParentPinState {
                    hash: profile.pin_hash,
                    gate: ParentGate::default(),
                })));
            }
            Ok(None) => {}
            Err(HostError::InvalidPersistedProfile) => {
                eprintln!(
                    "PlushPal ignored an invalid persisted parent profile and will start setup again."
                );
                store.delete_all()?;
            }
            Err(error) => return Err(error),
        }
        self.parent_profile_store = Some(store);
        Ok(self)
    }
}

pub fn build_router(state: HostState) -> Router {
    Router::new()
        .route("/api/v1/health", get(health))
        .route("/api/v1/bootstrap", post(exchange_bootstrap))
        .route("/api/v1/status", get(status))
        .route("/api/v1/diagnostics", get(diagnostics))
        .route("/api/v1/parent-pin/configure", post(configure_parent_pin))
        .route("/api/v1/parent-pin/authorize", post(authorize_parent_pin))
        .route("/api/v1/local-data/delete", post(delete_local_data))
        .route("/api/v1/history/list", post(list_history))
        .route("/api/v1/history/delete", post(delete_history))
        .route("/api/v1/characters", get(list_characters))
        .route("/api/v1/characters/save", post(save_character))
        .route("/api/v1/characters/delete", post(delete_character))
        .route("/api/v1/voice/status", get(voice_status))
        .route(
            "/api/v1/voice/enroll",
            post(enroll_voice).layer(DefaultBodyLimit::max(32 * 1_048_576)),
        )
        .route("/api/v1/voice/preview", post(preview_voice))
        .route("/api/v1/voice/approve", post(approve_voice))
        .route("/api/v1/voice/delete", post(delete_voice))
        .route("/api/v1/voice/speak", post(speak_with_voice))
        .route("/api/v1/commands", post(command))
        .route("/api/v1/events", get(websocket_events))
        .fallback(get(static_asset))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            enforce_gateway_policy,
        ))
        .layer(DefaultBodyLimit::max(32 * 1_048_576))
        .with_state(state)
}

#[derive(Serialize)]
struct HealthPayload {
    schema_version: u8,
    status: &'static str,
    local_service_ready: bool,
    voice_engine_ready: bool,
    conversation_engine_ready: bool,
    model_install_supported: bool,
    model_installing: bool,
    browser_ui_ready: bool,
}

async fn health(State(state): State<HostState>) -> Response {
    let conversation_engine_ready = state
        .conversation
        .read()
        .is_ok_and(|engine| engine.is_ready());
    let voice_engine_ready = state.voice_engine.is_ready();
    Json(HealthPayload {
        schema_version: 1,
        status: if voice_engine_ready {
            "ready"
        } else {
            "starting"
        },
        local_service_ready: true,
        voice_engine_ready,
        conversation_engine_ready,
        model_install_supported: state.model_installer.supported(),
        model_installing: state.model_installer.installing(),
        browser_ui_ready: true,
    })
    .into_response()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ParentPinPayload {
    pin: String,
    age_band: Option<String>,
    character_alias: Option<String>,
    character_traits: Option<Vec<String>>,
    parent_guidance: Option<String>,
    retention_days: Option<u16>,
}

async fn configure_parent_pin(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<ParentPinPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(now) = state.clock.now_seconds() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(mut stored) = state.parent_pin.lock() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let profile_fields = match parse_optional_profile(&payload) {
        Ok(profile) => profile,
        Err(()) => return StatusCode::BAD_REQUEST.into_response(),
    };
    if let Some(stored) = stored.as_mut() {
        return match stored.gate.authorize(&stored.hash, &payload.pin, now) {
            Ok(()) => {
                if let (Some(store), Some(profile_fields)) =
                    (&state.parent_profile_store, profile_fields)
                {
                    let profile = PersistedParentProfile {
                        pin_hash: stored.hash.clone(),
                        age_band: profile_fields.age_band,
                        character_alias: profile_fields.character_alias,
                        character_traits: profile_fields.character_traits,
                        parent_guidance: profile_fields.parent_guidance,
                        retention_days: profile_fields.retention_days,
                    };
                    if store.save(&profile).is_err() {
                        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
                    }
                }
                StatusCode::NO_CONTENT.into_response()
            }
            Err(_) => StatusCode::UNAUTHORIZED.into_response(),
        };
    }
    let Ok(random) = state.token_source.generate() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(salt) = <[u8; 16]>::try_from(random.get(..16).unwrap_or_default()) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(hash) = ParentPinHash::derive(&payload.pin, salt) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    if let Some(store) = &state.parent_profile_store {
        let Some(profile_fields) = profile_fields else {
            return StatusCode::BAD_REQUEST.into_response();
        };
        if store
            .save(&PersistedParentProfile {
                pin_hash: hash.clone(),
                age_band: profile_fields.age_band,
                character_alias: profile_fields.character_alias,
                character_traits: profile_fields.character_traits,
                parent_guidance: profile_fields.parent_guidance,
                retention_days: profile_fields.retention_days,
            })
            .is_err()
        {
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    *stored = Some(ParentPinState {
        hash,
        gate: ParentGate::default(),
    });
    StatusCode::NO_CONTENT.into_response()
}

#[derive(Debug)]
struct ProfileFields {
    age_band: AgeBand,
    character_alias: String,
    character_traits: Vec<String>,
    parent_guidance: Option<String>,
    retention_days: Option<u16>,
}

fn parse_optional_profile(payload: &ParentPinPayload) -> Result<Option<ProfileFields>, ()> {
    match (&payload.age_band, &payload.character_alias) {
        (None, None) => Ok(None),
        (Some(age_band), Some(character_alias)) => {
            let age_band = match age_band.as_str() {
                "4-5" => AgeBand::FourToFive,
                "6-8" => AgeBand::SixToEight,
                "9-12" => AgeBand::NineToTwelve,
                _ => return Err(()),
            };
            let profile = CharacterProfile::validated(
                character_alias.clone(),
                payload.character_traits.clone().unwrap_or_default(),
                payload
                    .parent_guidance
                    .clone()
                    .filter(|value| !value.trim().is_empty()),
            )
            .map_err(|_| ())?;
            if !matches!(payload.retention_days, None | Some(1 | 7 | 30)) {
                return Err(());
            }
            if composite_guidance(&profile.traits, profile.parent_guidance.as_deref())
                .is_some_and(|guidance| guidance.chars().count() > 240)
            {
                return Err(());
            }
            Ok(Some(ProfileFields {
                age_band,
                character_alias: profile.alias,
                character_traits: profile.traits,
                parent_guidance: profile.parent_guidance,
                retention_days: payload.retention_days,
            }))
        }
        _ => Err(()),
    }
}

async fn authorize_parent_pin(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<ParentPinPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Ok(now) = state.clock.now_seconds() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(mut stored) = state.parent_pin.lock() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Some(stored) = stored.as_mut() else {
        return StatusCode::PRECONDITION_REQUIRED.into_response();
    };
    match stored.gate.authorize(&stored.hash, &payload.pin, now) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => StatusCode::UNAUTHORIZED.into_response(),
    }
}

async fn delete_local_data(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<ParentPinPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if payload.age_band.is_some()
        || payload.character_alias.is_some()
        || payload.character_traits.is_some()
        || payload.parent_guidance.is_some()
        || payload.retention_days.is_some()
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let Ok(now) = state.clock.now_seconds() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(mut stored) = state.parent_pin.lock() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Some(pin_state) = stored.as_mut() else {
        return StatusCode::PRECONDITION_REQUIRED.into_response();
    };
    if pin_state
        .gate
        .authorize(&pin_state.hash, &payload.pin, now)
        .is_err()
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    if store.delete_all().is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    if let Ok(engine) = state.conversation.read() {
        let _ = engine.clear_session();
    }
    *stored = None;
    StatusCode::NO_CONTENT.into_response()
}

fn authorize_parent_payload(
    state: &HostState,
    payload: &ParentPinPayload,
) -> Result<(), StatusCode> {
    if payload.age_band.is_some()
        || payload.character_alias.is_some()
        || payload.character_traits.is_some()
        || payload.parent_guidance.is_some()
        || payload.retention_days.is_some()
    {
        return Err(StatusCode::BAD_REQUEST);
    }
    let now = state
        .clock
        .now_seconds()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let mut stored = state
        .parent_pin
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    let pin_state = stored.as_mut().ok_or(StatusCode::PRECONDITION_REQUIRED)?;
    pin_state
        .gate
        .authorize(&pin_state.hash, &payload.pin, now)
        .map_err(|_| StatusCode::UNAUTHORIZED)
}

async fn list_history(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<ParentPinPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_parent_payload(&state, &payload) {
        return status.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    match store.history(100) {
        Ok(history) => Json(history).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn delete_history(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<ParentPinPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_parent_payload(&state, &payload) {
        return status.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    match store.delete_history() {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VoiceEnrollPayload {
    pin: String,
    wav_base64: Option<String>,
    source_audio_base64: Option<String>,
    source_filename: Option<String>,
    source_mime: Option<String>,
    adult_authorized: bool,
    character_alias: Option<String>,
}

#[derive(Serialize)]
struct ApiErrorBody {
    message: &'static str,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VoiceTextPayload {
    pin: Option<String>,
    text: String,
    character_alias: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VoiceControlPayload {
    pin: String,
    character_alias: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CharacterPayload {
    pin: String,
    character_alias: String,
    character_traits: Vec<String>,
    parent_guidance: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CharacterDeletePayload {
    pin: String,
    character_alias: String,
}

fn authorize_pin_text(state: &HostState, pin: &str) -> Result<(), StatusCode> {
    authorize_parent_payload(
        state,
        &ParentPinPayload {
            pin: pin.to_owned(),
            age_band: None,
            character_alias: None,
            character_traits: None,
            parent_guidance: None,
            retention_days: None,
        },
    )
}

fn authorize_pin_text_if_configured(state: &HostState, pin: &str) -> Result<(), StatusCode> {
    let configured = state
        .parent_pin
        .lock()
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .is_some();
    if configured {
        authorize_pin_text(state, pin)
    } else {
        Ok(())
    }
}

async fn list_characters(State(state): State<HostState>, headers: HeaderMap) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    match store.list_characters() {
        Ok(mut characters) => {
            for character in &mut characters {
                character.voice.runtime_ready = state.voice_engine.is_ready();
            }
            Json(characters).into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn save_character(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<CharacterPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_pin_text(&state, &payload.pin) {
        return status.into_response();
    }
    let profile = match CharacterProfile::validated(
        payload.character_alias,
        payload.character_traits,
        payload
            .parent_guidance
            .filter(|value| !value.trim().is_empty()),
    ) {
        Ok(profile) => profile,
        Err(_) => return StatusCode::BAD_REQUEST.into_response(),
    };
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let character = CharacterConfiguration {
        alias: profile.alias,
        traits: profile.traits,
        parent_guidance: profile.parent_guidance,
        voice: VoiceProfileStatus::default(),
    };
    match store.save_character(&character) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn delete_character(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<CharacterDeletePayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_pin_text(&state, &payload.pin) {
        return status.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    match store.delete_character(&payload.character_alias) {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(HostError::InvalidPersistedProfile | HostError::VoiceUnavailable) => {
            StatusCode::PRECONDITION_REQUIRED.into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

#[derive(Deserialize)]
struct VoiceStatusQuery {
    character_alias: Option<String>,
}

async fn voice_status(
    State(state): State<HostState>,
    headers: HeaderMap,
    Query(query): Query<VoiceStatusQuery>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let status = query
        .character_alias
        .as_deref()
        .filter(|alias| !alias.trim().is_empty())
        .map_or_else(
            || store.voice_status(),
            |alias| store.voice_status_for_character(alias),
        );
    match status {
        Ok(mut status) => {
            status.runtime_ready = state.voice_engine.is_ready();
            if status.enrolled && status.profile_id.is_none() {
                status.profile_id = Some("primary-voice".to_owned());
            }
            Json(status).into_response()
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn enroll_voice(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<VoiceEnrollPayload>,
) -> Response {
    eprintln!(
        "voice enroll: request received alias={:?} wav_base64_bytes={} source_base64_bytes={} source_filename={:?} source_mime={:?}",
        payload.character_alias,
        payload.wav_base64.as_ref().map_or(0, String::len),
        payload.source_audio_base64.as_ref().map_or(0, String::len),
        payload.source_filename,
        payload.source_mime
    );
    if !is_authenticated(&state, &headers) {
        eprintln!("voice enroll: unauthenticated");
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_pin_text_if_configured(&state, &payload.pin) {
        return status.into_response();
    }
    let wav = match decode_voice_upload(&payload) {
        Ok(wav) => wav,
        Err(VoiceUploadError::DecodeFailed) => {
            eprintln!("voice enroll: base64 decode failed");
            return error_response(
                StatusCode::BAD_REQUEST,
                "The voice sample could not be decoded.",
            );
        }
        Err(VoiceUploadError::UnsupportedAudio) => {
            eprintln!("voice enroll: local audio conversion failed");
            return error_response(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Use an M4A, WAV, MP3, AAC, OGG, or WebM audio recording.",
            );
        }
    };
    eprintln!("voice enroll: decoded wav bytes={}", wav.len());
    let facts = match inspect_wav(&wav, payload.adult_authorized) {
        Ok(facts) => facts,
        Err(error) => {
            eprintln!("voice enroll: inspect failed error={error:?}");
            return error_response(
                StatusCode::UNPROCESSABLE_ENTITY,
                voice_profile_error_message(error),
            );
        }
    };
    eprintln!(
        "voice enroll: inspected duration_ms={} snr_db={:.2}",
        facts.duration_milliseconds, facts.signal_to_noise_db
    );
    let Some(store) = &state.parent_profile_store else {
        eprintln!("voice enroll: no parent profile store");
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let alias = payload.character_alias.as_deref().unwrap_or_default();
    let result = if alias.is_empty() {
        store.store_voice_sample(&wav, facts)
    } else {
        store.store_voice_sample_for_character(alias, &wav, facts)
    };
    match result {
        Ok(()) => {
            eprintln!("voice enroll: stored successfully alias={alias:?}");
            let mut status = if alias.is_empty() {
                store.voice_status()
            } else {
                store.voice_status_for_character(alias)
            }
            .unwrap_or_default();
            status.runtime_ready = state.voice_engine.is_ready();
            status.profile_id = Some(profile_id_for_alias(alias));
            Json(status).into_response()
        }
        Err(error) => {
            eprintln!("voice enroll: store failed error={error:?}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum VoiceUploadError {
    DecodeFailed,
    UnsupportedAudio,
}

fn decode_voice_upload(payload: &VoiceEnrollPayload) -> Result<Vec<u8>, VoiceUploadError> {
    match (
        payload.wav_base64.as_deref(),
        payload.source_audio_base64.as_deref(),
    ) {
        (Some(wav_base64), None) => BASE64
            .decode(wav_base64.as_bytes())
            .map_err(|_| VoiceUploadError::DecodeFailed),
        (None, Some(source_base64)) => {
            let source = BASE64
                .decode(source_base64.as_bytes())
                .map_err(|_| VoiceUploadError::DecodeFailed)?;
            convert_imported_audio_to_wav(
                &source,
                payload.source_filename.as_deref(),
                payload.source_mime.as_deref(),
            )
        }
        _ => Err(VoiceUploadError::DecodeFailed),
    }
}

#[cfg(target_os = "macos")]
fn convert_imported_audio_to_wav(
    source: &[u8],
    filename: Option<&str>,
    mime: Option<&str>,
) -> Result<Vec<u8>, VoiceUploadError> {
    if source.is_empty() || source.len() > 32 * 1_048_576 {
        return Err(VoiceUploadError::UnsupportedAudio);
    }
    let extension = audio_extension(filename, mime);
    let mut random = [0_u8; 16];
    getrandom::fill(&mut random).map_err(|_| VoiceUploadError::UnsupportedAudio)?;
    let token = hex::encode(random);
    let temporary_directory = std::env::temp_dir().join(format!("plushpal-voice-import-{token}"));
    std::fs::create_dir_all(&temporary_directory)
        .map_err(|_| VoiceUploadError::UnsupportedAudio)?;
    let input = temporary_directory.join(format!("sample.{extension}"));
    let output = temporary_directory.join("sample.wav");
    let result = (|| {
        std::fs::write(&input, source).map_err(|_| VoiceUploadError::UnsupportedAudio)?;
        let status = std::process::Command::new("/usr/bin/afconvert")
            .args(["-f", "WAVE", "-d", "LEI16@24000", "-c", "1"])
            .arg(&input)
            .arg(&output)
            .status()
            .map_err(|_| VoiceUploadError::UnsupportedAudio)?;
        if !status.success() {
            return Err(VoiceUploadError::UnsupportedAudio);
        }
        std::fs::read(&output).map_err(|_| VoiceUploadError::UnsupportedAudio)
    })();
    let _ = std::fs::remove_dir_all(&temporary_directory);
    result
}

#[cfg(not(target_os = "macos"))]
fn convert_imported_audio_to_wav(
    _source: &[u8],
    _filename: Option<&str>,
    _mime: Option<&str>,
) -> Result<Vec<u8>, VoiceUploadError> {
    Err(VoiceUploadError::UnsupportedAudio)
}

fn audio_extension(filename: Option<&str>, mime: Option<&str>) -> &'static str {
    let lower_name = filename.unwrap_or_default().to_ascii_lowercase();
    if lower_name.ends_with(".wav") {
        "wav"
    } else if lower_name.ends_with(".mp3") {
        "mp3"
    } else if lower_name.ends_with(".aac") {
        "aac"
    } else if lower_name.ends_with(".ogg") {
        "ogg"
    } else if lower_name.ends_with(".webm") {
        "webm"
    } else if lower_name.ends_with(".mp4") {
        "mp4"
    } else if lower_name.ends_with(".m4a") {
        "m4a"
    } else {
        match mime.unwrap_or_default().to_ascii_lowercase().as_str() {
            "audio/wav" | "audio/x-wav" => "wav",
            "audio/mpeg" | "audio/mp3" => "mp3",
            "audio/aac" => "aac",
            "audio/ogg" => "ogg",
            "audio/webm" => "webm",
            "audio/mp4" | "audio/x-m4a" => "m4a",
            _ => "m4a",
        }
    }
}

fn profile_id_for_alias(alias: &str) -> String {
    let trimmed = alias.trim();
    if trimmed.is_empty() {
        "primary-voice".to_owned()
    } else {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for byte in trimmed.to_lowercase().bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        format!("voice-profile-character-{hash:016x}")
    }
}

fn error_response(status: StatusCode, message: &'static str) -> Response {
    (status, Json(ApiErrorBody { message })).into_response()
}

fn voice_profile_error_message(error: ProfileError) -> &'static str {
    match error {
        ProfileError::VoiceConsentRequired => {
            "Voice enrollment requires parent confirmation that this voice is authorized."
        }
        ProfileError::VoiceTooShort => "Choose a voice recording that is at least 15 seconds long.",
        ProfileError::VoiceTooLong => "Choose a voice recording that is 3 minutes or shorter.",
        ProfileError::VoiceClipped => {
            "The voice recording is clipping. Re-record farther from the microphone."
        }
        ProfileError::VoiceTooNoisy => {
            "The voice recording is too quiet or noisy. Try a clearer recording closer to the speaker."
        }
        ProfileError::UnsupportedAudio => {
            "Use a supported audio recording that can be converted to 16-bit mono WAV."
        }
        _ => "The voice sample did not pass enrollment checks.",
    }
}

fn wav_response(wav: Vec<u8>) -> Response {
    (
        [
            (header::CONTENT_TYPE, "audio/wav"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        wav,
    )
        .into_response()
}

async fn preview_voice(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<VoiceTextPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    synthesize_voice_response(
        &state,
        payload.character_alias.as_deref(),
        &payload.text,
        false,
    )
}

async fn approve_voice(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<VoiceControlPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_pin_text_if_configured(&state, &payload.pin) {
        return status.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let result = payload
        .character_alias
        .as_deref()
        .filter(|alias| !alias.trim().is_empty())
        .map_or_else(
            || store.approve_voice(),
            |alias| store.approve_voice_for_character(alias),
        );
    match result {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => StatusCode::PRECONDITION_REQUIRED.into_response(),
    }
}

async fn delete_voice(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<VoiceControlPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if let Err(status) = authorize_pin_text_if_configured(&state, &payload.pin) {
        return status.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let result = payload
        .character_alias
        .as_deref()
        .filter(|alias| !alias.trim().is_empty())
        .map_or_else(
            || store.delete_voice(),
            |alias| store.delete_voice_for_character(alias),
        );
    match result {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn speak_with_voice(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(payload): Json<VoiceTextPayload>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    if payload.pin.is_some() {
        return StatusCode::BAD_REQUEST.into_response();
    }
    synthesize_voice_response(
        &state,
        payload.character_alias.as_deref(),
        &payload.text,
        true,
    )
}

fn synthesize_voice_response(
    state: &HostState,
    character_alias: Option<&str>,
    text: &str,
    require_approved: bool,
) -> Response {
    if text.trim().is_empty() || text.chars().count() > 450 {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let Some(store) = &state.parent_profile_store else {
        return StatusCode::NOT_IMPLEMENTED.into_response();
    };
    let Ok(status) = character_alias
        .filter(|alias| !alias.trim().is_empty())
        .map_or_else(
            || store.voice_status(),
            |alias| store.voice_status_for_character(alias),
        )
    else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    if !status.enrolled || (require_approved && !status.approved) {
        return StatusCode::PRECONDITION_REQUIRED.into_response();
    }
    if state
        .voice_synthesis_busy
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return StatusCode::CONFLICT.into_response();
    }
    let _guard = VoiceSynthesisGuard {
        busy: Arc::clone(&state.voice_synthesis_busy),
    };
    let Ok(reference) = character_alias
        .filter(|alias| !alias.trim().is_empty())
        .map_or_else(
            || store.load_voice_sample(),
            |alias| store.load_voice_sample_for_character(alias),
        )
    else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    match state.voice_engine.synthesize(&reference, text.trim()) {
        Ok(wav) => wav_response(wav),
        Err(_) => StatusCode::SERVICE_UNAVAILABLE.into_response(),
    }
}

async fn enforce_gateway_policy(
    State(state): State<HostState>,
    request: Request,
    next: Next,
) -> Response {
    let host = request
        .headers()
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    let origin = request
        .headers()
        .get(header::ORIGIN)
        .and_then(|value| value.to_str().ok());
    let content_length = request
        .headers()
        .get(header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);
    let kind = if request
        .headers()
        .get(header::UPGRADE)
        .is_some_and(|value| value.as_bytes().eq_ignore_ascii_case(b"websocket"))
    {
        RequestKind::WebSocketUpgrade
    } else if matches!(*request.method(), Method::GET | Method::HEAD) {
        RequestKind::ReadOnly
    } else {
        RequestKind::Mutating
    };
    let metadata = RequestMetadata {
        host,
        origin,
        path: request.uri().path(),
        content_length,
        kind,
    };
    let websocket_requires_authentication = request.uri().path() == "/api/v1/events"
        && kind == RequestKind::WebSocketUpgrade
        && !is_authenticated(&state, request.headers());
    let mut response = match state.policy.validate_request(&metadata) {
        Ok(()) if websocket_requires_authentication => StatusCode::UNAUTHORIZED.into_response(),
        Ok(()) => next.run(request).await,
        Err(error) => gateway_error_response(error),
    };
    add_security_headers(response.headers_mut());
    response
}

fn gateway_error_response(error: GatewayError) -> Response {
    let status = match error {
        GatewayError::OversizedBody => StatusCode::PAYLOAD_TOO_LARGE,
        GatewayError::InvalidApiPath => StatusCode::NOT_FOUND,
        GatewayError::InvalidHost | GatewayError::InvalidOrigin | GatewayError::MissingOrigin => {
            StatusCode::FORBIDDEN
        }
        GatewayError::NonLoopbackBind => StatusCode::INTERNAL_SERVER_ERROR,
    };
    status.into_response()
}

fn add_security_headers(headers: &mut HeaderMap) {
    for (name, value) in security_headers() {
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            headers.insert(name, value);
        }
    }
}

async fn exchange_bootstrap(State(state): State<HostState>, headers: HeaderMap) -> Response {
    let Some(presented) = headers
        .get("x-plushpal-bootstrap")
        .map(|value| value.as_bytes())
    else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Ok(session_bytes) = state.token_source.generate() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(now) = state.clock.now_seconds() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let Ok(mut security) = state.security.lock() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let token = hex::encode(session_bytes);
    if security
        .exchange_bootstrap(presented, token.as_bytes(), now)
        .is_err()
    {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let cookie = format!("pp_session={token}; HttpOnly; SameSite=Strict; Path=/");
    let mut response = StatusCode::NO_CONTENT.into_response();
    if let Ok(value) = HeaderValue::from_str(&cookie) {
        response.headers_mut().insert(header::SET_COOKIE, value);
    }
    response
}

#[derive(Serialize)]
struct StatusPayload {
    schema_version: u8,
    status: &'static str,
    local_only: bool,
    model_id: &'static str,
    display_name: &'static str,
    runtime_mode: String,
    model_ready: bool,
    model_install_supported: bool,
    model_installing: bool,
    parent_configured: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    age_band: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    character_alias: Option<String>,
    character_traits: Option<Vec<String>>,
    parent_guidance: Option<String>,
    retention_days: Option<u16>,
}

#[derive(Serialize)]
struct DiagnosticsPayload {
    schema_version: u8,
    status: &'static str,
    loopback_origin: String,
    local_service_ready: bool,
    voice_engine_ready: bool,
    conversation_engine_ready: bool,
    model_install_supported: bool,
    model_installing: bool,
    browser_ui_ready: bool,
    parent_profile_store_ready: bool,
    parent_configured: bool,
    voice_synthesis_busy: bool,
    station_mode: String,
}

async fn status(State(state): State<HostState>, headers: HeaderMap) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let model_ready = state
        .conversation
        .read()
        .is_ok_and(|engine| engine.is_ready());
    let persisted_profile = state
        .parent_profile_store
        .as_ref()
        .and_then(|store| store.load().ok().flatten());
    let parent_configured = persisted_profile.is_some();
    Json(StatusPayload {
        schema_version: 1,
        status: "ready",
        local_only: true,
        model_id: "qwen3-local",
        display_name: "Qwen3 local conversation model",
        runtime_mode: state.runtime_mode.to_string(),
        model_ready,
        model_install_supported: state.model_installer.supported(),
        model_installing: state.model_installer.installing(),
        parent_configured,
        age_band: persisted_profile
            .as_ref()
            .map(|profile| match profile.age_band {
                AgeBand::FourToFive => "4-5",
                AgeBand::SixToEight => "6-8",
                AgeBand::NineToTwelve => "9-12",
            }),
        character_alias: persisted_profile
            .as_ref()
            .map(|profile| profile.character_alias.clone()),
        character_traits: persisted_profile
            .as_ref()
            .map(|profile| profile.character_traits.clone()),
        parent_guidance: persisted_profile
            .as_ref()
            .and_then(|profile| profile.parent_guidance.clone()),
        retention_days: persisted_profile
            .as_ref()
            .and_then(|profile| profile.retention_days),
    })
    .into_response()
}

async fn diagnostics(State(state): State<HostState>, headers: HeaderMap) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let conversation_engine_ready = state
        .conversation
        .read()
        .is_ok_and(|engine| engine.is_ready());
    let voice_engine_ready = state.voice_engine.is_ready();
    let parent_configured = state
        .parent_profile_store
        .as_ref()
        .and_then(|store| store.load().ok().flatten())
        .is_some();
    let status = if voice_engine_ready {
        "ready"
    } else {
        "degraded"
    };
    Json(DiagnosticsPayload {
        schema_version: 1,
        status,
        loopback_origin: state.policy.endpoint().origin(false),
        local_service_ready: true,
        voice_engine_ready,
        conversation_engine_ready,
        model_install_supported: state.model_installer.supported(),
        model_installing: state.model_installer.installing(),
        browser_ui_ready: true,
        parent_profile_store_ready: state.parent_profile_store.is_some(),
        parent_configured,
        voice_synthesis_busy: state.voice_synthesis_busy.load(Ordering::Acquire),
        station_mode: state.runtime_mode.to_string(),
    })
    .into_response()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CommandEnvelope {
    schema_version: u8,
    request_id: String,
    command: String,
    payload: Option<LocalTurnPayload>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct LocalTurnPayload {
    age_band: String,
    character_alias: String,
    text: String,
}

#[derive(Serialize)]
struct EventEnvelope<'a> {
    schema_version: u8,
    event: &'a str,
    request_id: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    speech: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    suggest_trusted_adult: Option<bool>,
}

async fn command(
    State(state): State<HostState>,
    headers: HeaderMap,
    Json(command): Json<CommandEnvelope>,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let allowed = matches!(
        command.command.as_str(),
        "begin_local_turn"
            | "cancel_turn"
            | "exit_child_mode"
            | "install_local_model"
            | "cancel_model_install"
    );
    if command.schema_version != 1
        || command.request_id.is_empty()
        || command.request_id.len() > 128
        || !command
            .request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        || !allowed
    {
        return StatusCode::BAD_REQUEST.into_response();
    }
    let local_turn = if command.command == "begin_local_turn" {
        let Some(payload) = command.payload.clone() else {
            return StatusCode::BAD_REQUEST.into_response();
        };
        match parse_local_turn(payload) {
            Ok(mut turn) => {
                if let Some(store) = &state.parent_profile_store {
                    let profile = match store.load() {
                        Ok(Some(profile)) => profile,
                        Ok(None) => return StatusCode::PRECONDITION_REQUIRED.into_response(),
                        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                    };
                    if turn.age_band != profile.age_band {
                        return StatusCode::BAD_REQUEST.into_response();
                    }
                    let characters = match store.list_characters() {
                        Ok(characters) => characters,
                        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
                    };
                    let character = characters
                        .into_iter()
                        .find(|character| character.alias == turn.character_alias);
                    let Some(character) = character else {
                        return StatusCode::BAD_REQUEST.into_response();
                    };
                    turn.parent_guidance =
                        composite_guidance(&character.traits, character.parent_guidance.as_deref());
                }
                Some(turn)
            }
            Err(()) => return StatusCode::BAD_REQUEST.into_response(),
        }
    } else if command.payload.is_some() {
        return StatusCode::BAD_REQUEST.into_response();
    } else {
        None
    };
    let event = EventEnvelope {
        schema_version: 1,
        event: "command_accepted",
        request_id: &command.request_id,
        speech: None,
        suggest_trusted_adult: None,
    };
    let Ok(serialized) = serde_json::to_string(&event) else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let _ = state.events.send(serialized);
    if let Some(local_turn) = local_turn {
        let conversation = state
            .conversation
            .read()
            .map(|engine| Arc::clone(&engine))
            .ok();
        let events = state.events.clone();
        let request_id = command.request_id.clone();
        let profile_store = state.parent_profile_store.clone();
        let clock = state.clock.clone();
        tokio::task::spawn_blocking(move || {
            let persisted_command = local_turn.clone();
            let generated = conversation
                .ok_or(ConversationEngineError::NotReady)
                .and_then(|engine| engine.generate_local(local_turn));
            if let (Ok(response), Some(store), Ok(completed_at)) =
                (generated.as_ref(), profile_store, clock.now_seconds())
            {
                let _ = store.record_turn(&persisted_command, response, completed_at);
            }
            let (event_name, speech, trusted_adult) = match generated.as_ref() {
                Ok(response) => (
                    "response_ready",
                    Some(response.speech.as_str()),
                    Some(response.suggest_trusted_adult),
                ),
                Err(_) => ("turn_failed", None, None),
            };
            let envelope = EventEnvelope {
                schema_version: 1,
                event: event_name,
                request_id: &request_id,
                speech,
                suggest_trusted_adult: trusted_adult,
            };
            if let Ok(serialized) = serde_json::to_string(&envelope) {
                let _ = events.send(serialized);
            }
        });
    } else if command.command == "cancel_turn" {
        if let Ok(engine) = state.conversation.read() {
            let _ = engine.cancel();
        }
    } else if command.command == "exit_child_mode" {
        if let Ok(engine) = state.conversation.read() {
            let _ = engine.clear_session();
        }
        if let (Some(store), Ok(ended_at)) =
            (&state.parent_profile_store, state.clock.now_seconds())
        {
            let _ = store.end_session(ended_at);
        }
    } else if command.command == "install_local_model" {
        let installer = Arc::clone(&state.model_installer);
        let conversation = Arc::clone(&state.conversation);
        let events = state.events.clone();
        let request_id = command.request_id.clone();
        tokio::task::spawn_blocking(move || {
            let event_name = match installer.install() {
                Ok(engine) => match conversation.write() {
                    Ok(mut active) => {
                        *active = engine;
                        "model_install_ready"
                    }
                    Err(_) => "model_install_failed",
                },
                Err(_) => "model_install_failed",
            };
            let envelope = EventEnvelope {
                schema_version: 1,
                event: event_name,
                request_id: &request_id,
                speech: None,
                suggest_trusted_adult: None,
            };
            if let Ok(serialized) = serde_json::to_string(&envelope) {
                let _ = events.send(serialized);
            }
        });
    } else if command.command == "cancel_model_install" {
        state.model_installer.cancel();
    }
    (StatusCode::ACCEPTED, Json(event)).into_response()
}

fn parse_local_turn(payload: LocalTurnPayload) -> Result<LocalTurnCommand, ()> {
    let age_band = match payload.age_band.as_str() {
        "4-5" => AgeBand::FourToFive,
        "6-8" => AgeBand::SixToEight,
        "9-12" => AgeBand::NineToTwelve,
        _ => return Err(()),
    };
    if payload.character_alias.trim().is_empty()
        || payload.character_alias.chars().count() > 80
        || payload.text.trim().is_empty()
        || payload.text.chars().count() > 600
    {
        return Err(());
    }
    Ok(LocalTurnCommand {
        age_band,
        character_alias: payload.character_alias,
        text: payload.text,
        parent_guidance: None,
    })
}

fn composite_guidance(traits: &[String], parent_guidance: Option<&str>) -> Option<String> {
    let mut parts = Vec::new();
    if !traits.is_empty() {
        parts.push(format!("Character traits: {}.", traits.join(", ")));
    }
    if let Some(guidance) = parent_guidance {
        parts.push(guidance.to_owned());
    }
    let guidance = parts.join(" ");
    (!guidance.is_empty()).then_some(guidance)
}

async fn websocket_events(
    websocket: WebSocketUpgrade,
    State(state): State<HostState>,
    headers: HeaderMap,
) -> Response {
    if !is_authenticated(&state, &headers) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let receiver = state.events.subscribe();
    websocket.on_upgrade(move |socket| event_socket(socket, receiver))
}

async fn event_socket(mut socket: WebSocket, mut receiver: broadcast::Receiver<String>) {
    loop {
        tokio::select! {
            event = receiver.recv() => match event {
                Ok(event) => {
                    if socket.send(Message::Text(event.into())).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                _ => {}
            }
        }
    }
}

fn is_authenticated(state: &HostState, headers: &HeaderMap) -> bool {
    session_cookie(headers).as_deref().is_some_and(|token| {
        state
            .security
            .lock()
            .is_ok_and(|security| security.validate_session(token.as_bytes()))
    })
}

fn session_cookie(headers: &HeaderMap) -> Option<String> {
    headers
        .get(header::COOKIE)?
        .to_str()
        .ok()?
        .split(';')
        .map(str::trim)
        .find_map(|pair| pair.strip_prefix("pp_session=").map(ToOwned::to_owned))
}

async fn static_asset(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    let asset_path = if path.is_empty() { "index.html" } else { path };
    let Some(asset) = embedded_flutter_asset(asset_path) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let content_type = asset_content_type(asset_path);
    ([(header::CONTENT_TYPE, content_type)], Body::from(asset)).into_response()
}

fn asset_content_type(path: &str) -> &'static str {
    match path.rsplit('.').next() {
        Some("html") => "text/html; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("wasm") => "application/wasm",
        Some("png") => "image/png",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("ttf") => "font/ttf",
        Some("otf") => "font/otf",
        Some("frag") => "application/octet-stream",
        _ => "application/octet-stream",
    }
}

#[cfg(feature = "native-runtime")]
pub mod native_runtime {
    use std::{
        collections::HashMap,
        env, fs,
        io::{BufRead, BufReader, Cursor, Write},
        path::{Path, PathBuf},
        process::{Child, ChildStdin, ChildStdout, Command, Stdio},
        sync::{
            atomic::{AtomicBool, Ordering},
            Arc, Mutex,
        },
        time::{Duration, SystemTime, UNIX_EPOCH},
    };

    use aes_gcm::{
        aead::{Aead, KeyInit},
        Aes256Gcm, Nonce,
    };
    use plushpal_application::LocalConversationSession;
    use plushpal_encrypted_storage::{
        migrate_database, CharacterId, CharacterRecord, EncryptedDatabaseFactory, HistoryPolicy,
        SecretRef, SessionId, SessionRecord, SqlCipherDatabase, SqlCipherFactory, TurnRecord,
        VoiceAssetId, VoiceAssetRecord, APPLICATION_MIGRATIONS,
    };
    use plushpal_llama_native_ffi::CAbiLlamaApi;
    use plushpal_local_llm_llamacpp::{LlamaCppProvider, NativeLlamaBackend};
    use plushpal_model_lifecycle::{
        bundled_private_beta_manifest, verify_model_artifact, ProductionModelDownloader,
    };
    use serde::Deserialize;
    use sha2::{Digest, Sha256};
    use sherpa_onnx::{
        GenerationConfig, OfflineTts, OfflineTtsConfig, OfflineTtsModelConfig,
        OfflineTtsPocketModelConfig, Wave,
    };

    use super::*;

    type NativeProvider = LlamaCppProvider<NativeLlamaBackend<CAbiLlamaApi>>;

    const DATABASE_KEY_FILENAME: &str = "plushpal-database.key";
    const PIN_HASH_SETTING: &str = "parent_pin_hash";
    const AGE_BAND_SETTING: &str = "child_age_band";
    const CHARACTER_ALIAS_SETTING: &str = "character_alias";
    const CHARACTER_TRAITS_SETTING: &str = "character_traits";
    const PARENT_GUIDANCE_SETTING: &str = "parent_guidance";
    const RETENTION_DAYS_SETTING: &str = "retention_days";
    const VOICE_APPROVED_SETTING: &str = "voice_approved";
    const VOICE_DURATION_SETTING: &str = "voice_duration_ms";
    const PRIMARY_CHARACTER_ID: &str = "primary-character";
    const PRIMARY_VOICE_ID: &str = "primary-voice";
    const PRIMARY_VOICE_KEY_PREFIX: &str = "plushpal-desktop-primary-voice-key-v1";

    pub struct NativeParentProfileStore {
        database: Mutex<SqlCipherDatabase>,
        active_session: Mutex<Option<SessionId>>,
        voice_sample_cache: Mutex<HashMap<CharacterId, Vec<u8>>>,
        data_directory: PathBuf,
    }

    impl fmt::Debug for NativeParentProfileStore {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("NativeParentProfileStore([ENCRYPTED])")
        }
    }

    impl NativeParentProfileStore {
        pub fn open(data_directory: &Path, mut candidate_key: Vec<u8>) -> Result<Self, HostError> {
            fs::create_dir_all(data_directory).map_err(|_| HostError::PersistenceUnavailable)?;
            let key = load_or_create_database_key(data_directory, &mut candidate_key)?;
            let database_path = data_directory.join("plushpal.sqlcipher");
            let database = open_or_recover_database(&database_path, &key)?;
            Ok(Self {
                database: Mutex::new(database),
                active_session: Mutex::new(None),
                voice_sample_cache: Mutex::new(HashMap::new()),
                data_directory: data_directory.to_owned(),
            })
        }

        pub fn preflight_keychain_access(&self) -> Result<(), HostError> {
            let database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let characters = database
                .list_character_profiles()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let voice_records = characters
                .into_iter()
                .filter_map(|character| {
                    database
                        .get_voice_for_character(&character.record.id)
                        .ok()
                        .flatten()
                        .map(|voice| (character.record.id, voice))
                })
                .collect::<Vec<_>>();
            drop(database);
            for (character_id, record) in voice_records {
                if let Ok(sample) = self.decrypt_voice_record(&record) {
                    self.voice_sample_cache
                        .lock()
                        .map_err(|_| HostError::PersistenceUnavailable)?
                        .insert(character_id, sample);
                } else {
                    let _ = self.delete_voice_for_id(&character_id);
                }
            }
            Ok(())
        }

        fn character_id_for_alias(
            database: &SqlCipherDatabase,
            alias: &str,
        ) -> Result<CharacterId, HostError> {
            let normalized = alias.trim();
            let existing = database
                .list_character_profiles()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .into_iter()
                .find(|character| character.record.alias == normalized)
                .map(|character| character.record.id);
            Ok(existing.unwrap_or_else(|| character_id_from_alias(normalized)))
        }

        fn ensure_character_id_for_alias(&self, alias: &str) -> Result<CharacterId, HostError> {
            let validated = CharacterProfile::validated(alias.to_owned(), Vec::new(), None)
                .map_err(|_| HostError::InvalidPersistedProfile)?;
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            if let Some(existing) = database
                .list_character_profiles()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .into_iter()
                .find(|character| character.record.alias == validated.alias)
            {
                return Ok(existing.record.id);
            }
            let character_id = character_id_from_alias(&validated.alias);
            let voice_asset_id = database
                .get_voice_for_character(&character_id)
                .map_err(|_| HostError::PersistenceUnavailable)?
                .map(|voice| voice.id);
            database
                .put_character(
                    &CharacterRecord {
                        id: character_id.clone(),
                        alias: validated.alias,
                        voice_asset_id,
                    },
                    "[]",
                    None,
                    true,
                )
                .map_err(|_| HostError::PersistenceUnavailable)?;
            Ok(character_id)
        }

        fn voice_status_for_id(
            &self,
            character_id: &CharacterId,
        ) -> Result<VoiceProfileStatus, HostError> {
            let database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let enrolled = database
                .get_voice_for_character(character_id)
                .map_err(|_| HostError::PersistenceUnavailable)?
                .is_some();
            let approved = enrolled
                && database
                    .get_setting(&voice_approved_setting(character_id))
                    .map_err(|_| HostError::PersistenceUnavailable)?
                    .as_deref()
                    == Some("true");
            let duration_milliseconds = database
                .get_setting(&voice_duration_setting(character_id))
                .map_err(|_| HostError::PersistenceUnavailable)?
                .and_then(|value| value.parse().ok());
            Ok(VoiceProfileStatus {
                enrolled,
                approved,
                runtime_ready: false,
                duration_milliseconds,
                profile_id: Some(format!("voice-profile-{}", character_id.0)),
            })
        }

        fn store_voice_sample_for_id(
            &self,
            character_id: &CharacterId,
            wav: &[u8],
            facts: VoiceSampleFacts,
        ) -> Result<(), HostError> {
            let mut key = vec![0_u8; 32];
            getrandom::fill(&mut key).map_err(|_| HostError::EntropyUnavailable)?;
            let mut nonce = [0_u8; 12];
            getrandom::fill(&mut nonce).map_err(|_| HostError::EntropyUnavailable)?;
            let mut identifier = [0_u8; 16];
            getrandom::fill(&mut identifier).map_err(|_| HostError::EntropyUnavailable)?;
            let identifier = hex::encode(identifier);
            let cipher =
                Aes256Gcm::new_from_slice(&key).map_err(|_| HostError::PersistenceUnavailable)?;
            let encrypted = cipher
                .encrypt(Nonce::from_slice(&nonce), wav)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let key_label = format!("{}-{identifier}", voice_key_prefix(character_id));
            let secret_reference = SecretRef(key_label.clone());
            let relative_path = format!("voices/{}-voice-{identifier}.wav.enc", character_id.0);
            let path = self.data_directory.join(&relative_path);
            let parent = path.parent().ok_or(HostError::PersistenceUnavailable)?;
            std::fs::create_dir_all(parent).map_err(|_| HostError::PersistenceUnavailable)?;
            let temporary = path.with_extension("enc.tmp");
            let mut encoded = Vec::with_capacity(nonce.len() + encrypted.len());
            encoded.extend_from_slice(&nonce);
            encoded.extend_from_slice(&encrypted);
            if std::fs::write(&temporary, encoded).is_err()
                || std::fs::rename(&temporary, &path).is_err()
            {
                let _ = std::fs::remove_file(&temporary);
                return Err(HostError::PersistenceUnavailable);
            }
            if self.store_voice_secret(&secret_reference, &key).is_err() {
                let _ = std::fs::remove_file(&path);
                return Err(HostError::PersistenceUnavailable);
            }
            let mut database = match self.database.lock() {
                Ok(database) => database,
                Err(_) => {
                    let _ = std::fs::remove_file(&path);
                    let _ = self.delete_voice_secret(&secret_reference);
                    return Err(HostError::PersistenceUnavailable);
                }
            };
            let old_record = match database.get_voice_for_character(character_id) {
                Ok(record) => record,
                Err(_) => {
                    drop(database);
                    let _ = std::fs::remove_file(&path);
                    let _ = self.delete_voice_secret(&secret_reference);
                    return Err(HostError::PersistenceUnavailable);
                }
            };
            let duration = facts.duration_milliseconds.to_string();
            if database
                .put_settings(&[
                    (&voice_approved_setting(character_id), "false"),
                    (&voice_duration_setting(character_id), &duration),
                ])
                .and_then(|()| {
                    database.put_voice(&VoiceAssetRecord {
                        id: voice_asset_id_for_character(character_id),
                        character_id: character_id.clone(),
                        encrypted_path: relative_path,
                        wrapped_key_ref: secret_reference.clone(),
                    })
                })
                .is_err()
            {
                let _ = std::fs::remove_file(&path);
                let _ = self.delete_voice_secret(&secret_reference);
                return Err(HostError::PersistenceUnavailable);
            }
            drop(database);
            if let Some(old_record) = old_record {
                if old_record.wrapped_key_ref != secret_reference {
                    let _ = self.delete_voice_secret(&old_record.wrapped_key_ref);
                }
                let _ = std::fs::remove_file(self.data_directory.join(old_record.encrypted_path));
            }
            if let Ok(mut cache) = self.voice_sample_cache.lock() {
                cache.insert(character_id.clone(), wav.to_vec());
            }
            Ok(())
        }

        fn load_voice_sample_for_id(
            &self,
            character_id: &CharacterId,
        ) -> Result<Vec<u8>, HostError> {
            if let Some(cached) = self
                .voice_sample_cache
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .get(character_id)
                .cloned()
            {
                return Ok(cached);
            }
            let record = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .get_voice_for_character(character_id)
                .map_err(|_| HostError::PersistenceUnavailable)?
                .ok_or(HostError::VoiceUnavailable)?;
            let sample = self.decrypt_voice_record(&record)?;
            self.voice_sample_cache
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .insert(character_id.clone(), sample.clone());
            Ok(sample)
        }

        fn decrypt_voice_record(&self, record: &VoiceAssetRecord) -> Result<Vec<u8>, HostError> {
            if !record.encrypted_path.starts_with("voices/")
                || !record.encrypted_path.ends_with(".wav.enc")
                || record.encrypted_path.contains("..")
            {
                return Err(HostError::InvalidPersistedProfile);
            }
            let encrypted = std::fs::read(self.data_directory.join(&record.encrypted_path))
                .map_err(|_| HostError::PersistenceUnavailable)?;
            if encrypted.len() < 13 {
                return Err(HostError::InvalidPersistedProfile);
            }
            let key = self
                .load_voice_secret(&record.wrapped_key_ref)
                .ok_or(HostError::PersistenceUnavailable)?;
            let cipher =
                Aes256Gcm::new_from_slice(&key).map_err(|_| HostError::PersistenceUnavailable)?;
            cipher
                .decrypt(Nonce::from_slice(&encrypted[..12]), &encrypted[12..])
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_voice_for_id(&self, character_id: &CharacterId) -> Result<(), HostError> {
            let record = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .get_voice_for_character(character_id)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            if let Some(record) = record {
                let _ = self.delete_voice_secret(&record.wrapped_key_ref);
                let _ = std::fs::remove_file(self.data_directory.join(record.encrypted_path));
            }
            if let Ok(mut cache) = self.voice_sample_cache.lock() {
                cache.remove(character_id);
            }
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            database
                .delete_voice_for_character(character_id)
                .and_then(|_| {
                    database.put_settings(&[
                        (&voice_approved_setting(character_id), "false"),
                        (&voice_duration_setting(character_id), ""),
                    ])
                })
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn voice_secret_path(&self, secret_ref: &SecretRef) -> PathBuf {
            let digest = Sha256::digest(secret_ref.0.as_bytes());
            self.data_directory
                .join("voice-secrets")
                .join(format!("{}.key", hex::encode(digest)))
        }

        fn store_voice_secret(
            &self,
            secret_ref: &SecretRef,
            secret: &[u8],
        ) -> Result<(), HostError> {
            if secret.len() < 32 {
                return Err(HostError::PersistenceUnavailable);
            }
            let path = self.voice_secret_path(secret_ref);
            let parent = path.parent().ok_or(HostError::PersistenceUnavailable)?;
            fs::create_dir_all(parent).map_err(|_| HostError::PersistenceUnavailable)?;
            let temporary = path.with_extension("key.tmp");
            fs::write(&temporary, secret).map_err(|_| HostError::PersistenceUnavailable)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let permissions = fs::Permissions::from_mode(0o600);
                fs::set_permissions(&temporary, permissions)
                    .map_err(|_| HostError::PersistenceUnavailable)?;
            }
            fs::rename(&temporary, &path).map_err(|_| {
                let _ = fs::remove_file(&temporary);
                HostError::PersistenceUnavailable
            })
        }

        fn load_voice_secret(&self, secret_ref: &SecretRef) -> Option<Vec<u8>> {
            let secret = fs::read(self.voice_secret_path(secret_ref)).ok()?;
            (secret.len() >= 32).then_some(secret)
        }

        fn delete_voice_secret(&self, secret_ref: &SecretRef) -> bool {
            match fs::remove_file(self.voice_secret_path(secret_ref)) {
                Ok(()) => true,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => true,
                Err(_) => false,
            }
        }
    }

    fn character_id_from_alias(alias: &str) -> CharacterId {
        let mut hash = 0xcbf2_9ce4_8422_2325_u64;
        for byte in alias.trim().to_lowercase().bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
        }
        CharacterId(format!("character-{hash:016x}"))
    }

    fn voice_asset_id_for_character(character_id: &CharacterId) -> VoiceAssetId {
        if character_id.0 == PRIMARY_CHARACTER_ID {
            VoiceAssetId(PRIMARY_VOICE_ID.to_owned())
        } else {
            VoiceAssetId(format!("voice-{}", character_id.0))
        }
    }

    fn voice_key_prefix(character_id: &CharacterId) -> String {
        if character_id.0 == PRIMARY_CHARACTER_ID {
            PRIMARY_VOICE_KEY_PREFIX.to_owned()
        } else {
            format!("plushpal-desktop-{}-key-v1", character_id.0)
        }
    }

    fn voice_approved_setting(character_id: &CharacterId) -> String {
        if character_id.0 == PRIMARY_CHARACTER_ID {
            VOICE_APPROVED_SETTING.to_owned()
        } else {
            format!("voice_approved_{}", character_id.0)
        }
    }

    fn voice_duration_setting(character_id: &CharacterId) -> String {
        if character_id.0 == PRIMARY_CHARACTER_ID {
            VOICE_DURATION_SETTING.to_owned()
        } else {
            format!("voice_duration_ms_{}", character_id.0)
        }
    }

    fn load_or_create_database_key(
        data_directory: &Path,
        candidate_key: &mut [u8],
    ) -> Result<Vec<u8>, HostError> {
        let key_path = data_directory.join(DATABASE_KEY_FILENAME);
        if key_path.is_file() {
            let key = fs::read(&key_path).map_err(|_| HostError::PersistenceUnavailable)?;
            if key.len() >= 32 {
                candidate_key.fill(0);
                return Ok(key);
            }
        }
        if candidate_key.len() < 32 {
            return Err(HostError::PersistenceUnavailable);
        }
        let key = candidate_key.to_vec();
        fs::write(&key_path, &key).map_err(|_| HostError::PersistenceUnavailable)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let permissions = fs::Permissions::from_mode(0o600);
            fs::set_permissions(&key_path, permissions)
                .map_err(|_| HostError::PersistenceUnavailable)?;
        }
        candidate_key.fill(0);
        Ok(key)
    }

    fn open_or_recover_database(
        database_path: &Path,
        key: &[u8],
    ) -> Result<SqlCipherDatabase, HostError> {
        match open_database(database_path, key) {
            Ok(database) => Ok(database),
            Err(error) if database_path.exists() => {
                let timestamp = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|duration| duration.as_secs())
                    .unwrap_or(0);
                let backup_path = database_path.with_extension(format!("unreadable-{timestamp}"));
                fs::rename(database_path, backup_path)
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                open_database(database_path, key).map_err(|_| error)
            }
            Err(error) => Err(error),
        }
    }

    fn open_database(database_path: &Path, key: &[u8]) -> Result<SqlCipherDatabase, HostError> {
        let mut database = SqlCipherFactory
            .open(
                database_path
                    .to_str()
                    .ok_or(HostError::PersistenceUnavailable)?,
                key,
            )
            .map_err(|_| HostError::PersistenceUnavailable)?;
        if !plushpal_encrypted_storage::EncryptedDatabase::encryption_ready(&database)
            .map_err(|_| HostError::PersistenceUnavailable)?
        {
            return Err(HostError::PersistenceUnavailable);
        }
        migrate_database(&mut database, APPLICATION_MIGRATIONS)
            .map_err(|_| HostError::PersistenceUnavailable)?;
        Ok(database)
    }

    impl ParentProfileStore for NativeParentProfileStore {
        fn load(&self) -> Result<Option<PersistedParentProfile>, HostError> {
            let database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let pin_hash = database
                .get_setting(PIN_HASH_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let age_band = database
                .get_setting(AGE_BAND_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let character_alias = database
                .get_setting(CHARACTER_ALIAS_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let character_traits = database
                .get_setting(CHARACTER_TRAITS_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let parent_guidance = database
                .get_setting(PARENT_GUIDANCE_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let retention_days = database
                .get_setting(RETENTION_DAYS_SETTING)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            match (pin_hash, age_band, character_alias) {
                (None, None, None) => Ok(None),
                (Some(pin_hash), Some(age_band), Some(character_alias)) => {
                    let pin_hash = ParentPinHash::decode(&pin_hash)
                        .map_err(|_| HostError::InvalidPersistedProfile)?;
                    let age_band = match age_band.as_str() {
                        "4-5" => AgeBand::FourToFive,
                        "6-8" => AgeBand::SixToEight,
                        "9-12" => AgeBand::NineToTwelve,
                        _ => return Err(HostError::InvalidPersistedProfile),
                    };
                    let character_traits = character_traits
                        .map(|value| serde_json::from_str::<Vec<String>>(&value))
                        .transpose()
                        .map_err(|_| HostError::InvalidPersistedProfile)?
                        .unwrap_or_default();
                    let parent_guidance = parent_guidance.filter(|value| !value.is_empty());
                    let validated = CharacterProfile::validated(
                        character_alias,
                        character_traits,
                        parent_guidance,
                    )
                    .map_err(|_| HostError::InvalidPersistedProfile)?;
                    let retention_days = retention_days
                        .map(|value| value.parse::<u16>())
                        .transpose()
                        .map_err(|_| HostError::InvalidPersistedProfile)?;
                    if !matches!(retention_days, None | Some(1 | 7 | 30)) {
                        return Err(HostError::InvalidPersistedProfile);
                    }
                    Ok(Some(PersistedParentProfile {
                        pin_hash,
                        age_band,
                        character_alias: validated.alias,
                        character_traits: validated.traits,
                        parent_guidance: validated.parent_guidance,
                        retention_days,
                    }))
                }
                _ => Err(HostError::InvalidPersistedProfile),
            }
        }

        fn save(&self, profile: &PersistedParentProfile) -> Result<(), HostError> {
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let encoded_hash = profile.pin_hash.encoded();
            let age_band = match profile.age_band {
                AgeBand::FourToFive => "4-5",
                AgeBand::SixToEight => "6-8",
                AgeBand::NineToTwelve => "9-12",
            };
            let character_traits = serde_json::to_string(&profile.character_traits)
                .map_err(|_| HostError::InvalidPersistedProfile)?;
            let parent_guidance = profile.parent_guidance.as_deref().unwrap_or_default();
            let retention_days = profile
                .retention_days
                .map(|days| days.to_string())
                .unwrap_or_default();
            database
                .put_settings(&[
                    (PIN_HASH_SETTING, &encoded_hash),
                    (AGE_BAND_SETTING, age_band),
                    (CHARACTER_ALIAS_SETTING, &profile.character_alias),
                    (CHARACTER_TRAITS_SETTING, &character_traits),
                    (PARENT_GUIDANCE_SETTING, parent_guidance),
                    (RETENTION_DAYS_SETTING, &retention_days),
                ])
                .and_then(|()| {
                    let character_id = CharacterId(PRIMARY_CHARACTER_ID.to_owned());
                    let voice_asset_id = database
                        .get_voice_for_character(&character_id)?
                        .map(|voice| voice.id);
                    database.put_character(
                        &CharacterRecord {
                            id: character_id,
                            alias: profile.character_alias.clone(),
                            voice_asset_id,
                        },
                        &character_traits,
                        profile.parent_guidance.as_deref(),
                        true,
                    )
                })
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_all(&self) -> Result<(), HostError> {
            let character_ids = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .list_character_profiles()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .into_iter()
                .map(|character| character.record.id)
                .collect::<Vec<_>>();
            if character_ids.is_empty() {
                self.delete_voice()?;
            } else {
                for character_id in character_ids {
                    let _ = self.delete_voice_for_id(&character_id);
                }
            }
            *self
                .active_session
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = None;
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .delete_all()
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn list_characters(&self) -> Result<Vec<CharacterConfiguration>, HostError> {
            let records = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .list_character_profiles()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let mut characters = records
                .into_iter()
                .map(|record| {
                    let traits = serde_json::from_str::<Vec<String>>(&record.traits_json)
                        .map_err(|_| HostError::InvalidPersistedProfile)?;
                    let validated = CharacterProfile::validated(
                        record.record.alias,
                        traits,
                        record.parent_guidance,
                    )
                    .map_err(|_| HostError::InvalidPersistedProfile)?;
                    let mut voice = self.voice_status_for_id(&record.record.id)?;
                    voice.profile_id = Some(profile_id_for_alias(&validated.alias));
                    Ok(CharacterConfiguration {
                        alias: validated.alias,
                        traits: validated.traits,
                        parent_guidance: validated.parent_guidance,
                        voice,
                    })
                })
                .collect::<Result<Vec<_>, HostError>>()?;
            if characters.is_empty() {
                if let Some(profile) = self.load()? {
                    characters.push(CharacterConfiguration {
                        alias: profile.character_alias,
                        traits: profile.character_traits,
                        parent_guidance: profile.parent_guidance,
                        voice: self.voice_status()?,
                    });
                }
            }
            Ok(characters)
        }

        fn save_character(&self, character: &CharacterConfiguration) -> Result<(), HostError> {
            let validated = CharacterProfile::validated(
                character.alias.clone(),
                character.traits.clone(),
                character.parent_guidance.clone(),
            )
            .map_err(|_| HostError::InvalidPersistedProfile)?;
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let character_id = Self::character_id_for_alias(&database, &validated.alias)?;
            let voice_asset_id = database
                .get_voice_for_character(&character_id)
                .map_err(|_| HostError::PersistenceUnavailable)?
                .map(|voice| voice.id);
            let traits_json = serde_json::to_string(&validated.traits)
                .map_err(|_| HostError::InvalidPersistedProfile)?;
            database
                .put_character(
                    &CharacterRecord {
                        id: character_id,
                        alias: validated.alias,
                        voice_asset_id,
                    },
                    &traits_json,
                    validated.parent_guidance.as_deref(),
                    true,
                )
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_character(&self, alias: &str) -> Result<(), HostError> {
            let character_id = {
                let database = self
                    .database
                    .lock()
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                Self::character_id_for_alias(&database, alias)?
            };
            self.delete_voice_for_id(&character_id)?;
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            database
                .delete_character(&character_id)
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn record_turn(
            &self,
            command: &LocalTurnCommand,
            response: &StructuredCharacterResponse,
            completed_at: i64,
        ) -> Result<(), HostError> {
            let profile = self.load()?.ok_or(HostError::InvalidPersistedProfile)?;
            let mut active_session = self
                .active_session
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let mut database = self
                .database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let session_id = if let Some(session_id) = active_session.as_ref() {
                session_id.clone()
            } else {
                let nonce = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| HostError::ClockUnavailable)?
                    .as_nanos();
                let session_id = SessionId(format!("session-{completed_at}-{nonce}"));
                let character_id =
                    Self::character_id_for_alias(&database, &command.character_alias)?;
                database
                    .put_session(&SessionRecord {
                        id: session_id.clone(),
                        character_id,
                        age_band: command.age_band,
                        started_at: completed_at,
                        ended_at: None,
                    })
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                *active_session = Some(session_id.clone());
                session_id
            };
            database
                .put_turn(&TurnRecord {
                    session_id,
                    child_text: command.text.clone(),
                    character_text: response.speech.clone(),
                    completed_at,
                })
                .map_err(|_| HostError::PersistenceUnavailable)?;
            if let Some(days) = profile.retention_days {
                database
                    .cleanup_expired_history(completed_at, days)
                    .map_err(|_| HostError::PersistenceUnavailable)?;
            }
            Ok(())
        }

        fn end_session(&self, ended_at: i64) -> Result<(), HostError> {
            let profile = self.load()?.ok_or(HostError::InvalidPersistedProfile)?;
            let session_id = self
                .active_session
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .take();
            let Some(session_id) = session_id else {
                return Ok(());
            };
            let policy = profile
                .retention_days
                .map_or(HistoryPolicy::SessionOnly, HistoryPolicy::RetainDays);
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .end_session(&session_id, ended_at, policy)
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn history(
            &self,
            maximum_turns: usize,
        ) -> Result<Vec<ConversationHistoryEntry>, HostError> {
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .list_history(maximum_turns)
                .map(|records| {
                    records
                        .into_iter()
                        .map(|record| ConversationHistoryEntry {
                            child_text: record.child_text,
                            character_text: record.character_text,
                            completed_at: record.completed_at,
                        })
                        .collect()
                })
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_history(&self) -> Result<(), HostError> {
            *self
                .active_session
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = None;
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .delete_history()
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn voice_status(&self) -> Result<VoiceProfileStatus, HostError> {
            self.voice_status_for_id(&CharacterId(PRIMARY_CHARACTER_ID.to_owned()))
        }

        fn voice_status_for_character(&self, alias: &str) -> Result<VoiceProfileStatus, HostError> {
            let character_id = {
                let database = self
                    .database
                    .lock()
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                Self::character_id_for_alias(&database, alias)?
            };
            let mut status = self.voice_status_for_id(&character_id)?;
            status.profile_id = Some(profile_id_for_alias(alias));
            Ok(status)
        }

        fn store_voice_sample(&self, wav: &[u8], facts: VoiceSampleFacts) -> Result<(), HostError> {
            self.store_voice_sample_for_id(
                &CharacterId(PRIMARY_CHARACTER_ID.to_owned()),
                wav,
                facts,
            )
        }

        fn store_voice_sample_for_character(
            &self,
            alias: &str,
            wav: &[u8],
            facts: VoiceSampleFacts,
        ) -> Result<(), HostError> {
            let character_id = self.ensure_character_id_for_alias(alias)?;
            self.store_voice_sample_for_id(&character_id, wav, facts)
        }

        fn load_voice_sample(&self) -> Result<Vec<u8>, HostError> {
            self.load_voice_sample_for_id(&CharacterId(PRIMARY_CHARACTER_ID.to_owned()))
        }

        fn load_voice_sample_for_character(&self, alias: &str) -> Result<Vec<u8>, HostError> {
            let character_id = {
                let database = self
                    .database
                    .lock()
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                Self::character_id_for_alias(&database, alias)?
            };
            self.load_voice_sample_for_id(&character_id)
        }

        fn approve_voice(&self) -> Result<(), HostError> {
            if !self.voice_status()?.enrolled {
                return Err(HostError::VoiceUnavailable);
            }
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .put_setting(VOICE_APPROVED_SETTING, "true")
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn approve_voice_for_character(&self, alias: &str) -> Result<(), HostError> {
            let character_id = {
                let database = self
                    .database
                    .lock()
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                Self::character_id_for_alias(&database, alias)?
            };
            if !self.voice_status_for_id(&character_id)?.enrolled {
                return Err(HostError::VoiceUnavailable);
            }
            self.database
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .put_setting(&voice_approved_setting(&character_id), "true")
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_voice(&self) -> Result<(), HostError> {
            self.delete_voice_for_id(&CharacterId(PRIMARY_CHARACTER_ID.to_owned()))
        }

        fn delete_voice_for_character(&self, alias: &str) -> Result<(), HostError> {
            let character_id = {
                let database = self
                    .database
                    .lock()
                    .map_err(|_| HostError::PersistenceUnavailable)?;
                Self::character_id_for_alias(&database, alias)?
            };
            self.delete_voice_for_id(&character_id)
        }
    }

    #[derive(Debug)]
    pub struct DemoVoiceEngine;

    impl VoiceEngine for DemoVoiceEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError> {
            if reference_wav.is_empty() || text.trim().is_empty() {
                return Err(HostError::VoiceUnavailable);
            }
            let digest = Sha256::digest(reference_wav);
            let sample_rate = 16_000_u32;
            let seconds = (text.chars().count() as f32 / 18.0).clamp(0.8, 3.0);
            let samples = (seconds * sample_rate as f32) as usize;
            let frequency = 360.0 + f32::from(digest[0]) * 1.5;
            let mut cursor = Cursor::new(Vec::new());
            let specification = hound::WavSpec {
                channels: 1,
                sample_rate,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            {
                let mut writer = hound::WavWriter::new(&mut cursor, specification)
                    .map_err(|_| HostError::VoiceUnavailable)?;
                for index in 0..samples {
                    let t = index as f32 / sample_rate as f32;
                    let fade_in = (index as f32 / (sample_rate as f32 * 0.04)).clamp(0.0, 1.0);
                    let fade_out =
                        ((samples - index) as f32 / (sample_rate as f32 * 0.08)).clamp(0.0, 1.0);
                    let envelope = fade_in.min(fade_out) * 0.28;
                    let wobble = (t * 2.4 * std::f32::consts::PI).sin() * 18.0;
                    let sample = ((t * (frequency + wobble) * 2.0 * std::f32::consts::PI).sin()
                        * envelope
                        * f32::from(i16::MAX)) as i16;
                    writer
                        .write_sample(sample)
                        .map_err(|_| HostError::VoiceUnavailable)?;
                }
                writer.finalize().map_err(|_| HostError::VoiceUnavailable)?;
            }
            Ok(cursor.into_inner())
        }
    }

    pub struct PocketVoiceEngine {
        engine: Mutex<OfflineTts>,
        temporary_directory: PathBuf,
    }

    impl fmt::Debug for PocketVoiceEngine {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("PocketVoiceEngine([LOCAL MODEL])")
        }
    }

    impl PocketVoiceEngine {
        pub fn load(model_directory: &Path, data_directory: &Path) -> Result<Self, HostError> {
            let required = [
                "lm_flow.int8.onnx",
                "lm_main.int8.onnx",
                "encoder.onnx",
                "decoder.int8.onnx",
                "text_conditioner.onnx",
                "vocab.json",
                "token_scores.json",
            ];
            if required
                .iter()
                .any(|name| !model_directory.join(name).is_file())
            {
                return Err(HostError::VoiceUnavailable);
            }
            let path = |name: &str| model_directory.join(name).to_string_lossy().into_owned();
            let configuration = OfflineTtsConfig {
                model: OfflineTtsModelConfig {
                    pocket: OfflineTtsPocketModelConfig {
                        lm_flow: Some(path("lm_flow.int8.onnx")),
                        lm_main: Some(path("lm_main.int8.onnx")),
                        encoder: Some(path("encoder.onnx")),
                        decoder: Some(path("decoder.int8.onnx")),
                        text_conditioner: Some(path("text_conditioner.onnx")),
                        vocab_json: Some(path("vocab.json")),
                        token_scores_json: Some(path("token_scores.json")),
                        voice_embedding_cache_capacity: 20,
                    },
                    num_threads: 4,
                    debug: false,
                    ..Default::default()
                },
                max_num_sentences: 2,
                ..Default::default()
            };
            let engine = OfflineTts::create(&configuration).ok_or(HostError::VoiceUnavailable)?;
            let temporary_directory = data_directory.join("voice-runtime");
            std::fs::create_dir_all(&temporary_directory)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            Ok(Self {
                engine: Mutex::new(engine),
                temporary_directory,
            })
        }
    }

    impl VoiceEngine for PocketVoiceEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError> {
            let mut random = [0_u8; 16];
            getrandom::fill(&mut random).map_err(|_| HostError::EntropyUnavailable)?;
            let reference_path = self
                .temporary_directory
                .join(format!("reference-{}.wav", hex::encode(random)));
            std::fs::write(&reference_path, reference_wav)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let wave = Wave::read(&reference_path.to_string_lossy());
            let _ = std::fs::remove_file(&reference_path);
            let wave = wave.ok_or(HostError::InvalidVoiceSample)?;
            let mut extra = std::collections::HashMap::new();
            extra.insert(
                "max_reference_audio_len".to_owned(),
                serde_json::json!(30.0),
            );
            extra.insert("seed".to_owned(), serde_json::json!(42));
            let configuration = GenerationConfig {
                speed: 1.0,
                reference_audio: Some(wave.samples().to_vec()),
                reference_sample_rate: wave.sample_rate(),
                extra: Some(extra),
                ..Default::default()
            };
            let engine = self
                .engine
                .lock()
                .map_err(|_| HostError::VoiceUnavailable)?;
            let audio = engine
                .generate_with_config(text, &configuration, None::<fn(&[f32], f32) -> bool>)
                .ok_or(HostError::VoiceUnavailable)?;
            let mut cursor = Cursor::new(Vec::new());
            let specification = hound::WavSpec {
                channels: 1,
                sample_rate: u32::try_from(audio.sample_rate())
                    .map_err(|_| HostError::VoiceUnavailable)?,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            {
                let mut writer = hound::WavWriter::new(&mut cursor, specification)
                    .map_err(|_| HostError::VoiceUnavailable)?;
                for sample in audio.samples() {
                    let pcm = (sample.clamp(-1.0, 1.0) * f32::from(i16::MAX)) as i16;
                    writer
                        .write_sample(pcm)
                        .map_err(|_| HostError::VoiceUnavailable)?;
                }
                writer.finalize().map_err(|_| HostError::VoiceUnavailable)?;
            }
            Ok(cursor.into_inner())
        }
    }

    pub struct ChatterboxVoiceEngine {
        python_executable: PathBuf,
        script_path: PathBuf,
        engine: String,
        device: String,
        language: String,
        exaggeration: String,
        cfg_weight: String,
        temperature: String,
        min_p: String,
        top_p: String,
        repetition_penalty: String,
        temporary_directory: PathBuf,
    }

    impl fmt::Debug for ChatterboxVoiceEngine {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter
                .debug_struct("ChatterboxVoiceEngine")
                .field("python_executable", &self.python_executable)
                .field("script_path", &self.script_path)
                .field("engine", &self.engine)
                .field("device", &self.device)
                .field("language", &self.language)
                .field("exaggeration", &self.exaggeration)
                .field("cfg_weight", &self.cfg_weight)
                .field("temperature", &self.temperature)
                .field("min_p", &self.min_p)
                .field("top_p", &self.top_p)
                .field("repetition_penalty", &self.repetition_penalty)
                .finish_non_exhaustive()
        }
    }

    impl ChatterboxVoiceEngine {
        pub fn new(
            python_executable: PathBuf,
            script_path: PathBuf,
            data_directory: &Path,
            engine: String,
            device: String,
            language: String,
            exaggeration: String,
            cfg_weight: String,
            temperature: String,
            min_p: String,
            top_p: String,
            repetition_penalty: String,
        ) -> Result<Self, HostError> {
            if !script_path.is_file() {
                return Err(HostError::VoiceUnavailable);
            }
            let temporary_directory = data_directory.join("voice-runtime/chatterbox");
            std::fs::create_dir_all(&temporary_directory)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let candidate = Self {
                python_executable,
                script_path,
                engine,
                device,
                language,
                exaggeration,
                cfg_weight,
                temperature,
                min_p,
                top_p,
                repetition_penalty,
                temporary_directory,
            };
            candidate.healthcheck()?;
            Ok(candidate)
        }

        fn healthcheck(&self) -> Result<(), HostError> {
            let _ = std::fs::create_dir_all(self.temporary_directory.join("numba-cache"));
            let status = Command::new(&self.python_executable)
                .arg(&self.script_path)
                .arg("--healthcheck")
                .arg("--engine")
                .arg(&self.engine)
                .arg("--device")
                .arg(&self.device)
                .env("PYTHONDONTWRITEBYTECODE", "1")
                .env("PYTHONNOUSERSITE", "1")
                .env(
                    "NUMBA_CACHE_DIR",
                    self.temporary_directory.join("numba-cache"),
                )
                .status()
                .map_err(|_| HostError::VoiceUnavailable)?;
            if status.success() {
                Ok(())
            } else {
                Err(HostError::VoiceUnavailable)
            }
        }

        fn temporary_wav_paths(&self) -> Result<(PathBuf, PathBuf), HostError> {
            let mut random = [0_u8; 16];
            getrandom::fill(&mut random).map_err(|_| HostError::EntropyUnavailable)?;
            let identifier = hex::encode(random);
            Ok((
                self.temporary_directory
                    .join(format!("reference-{identifier}.wav")),
                self.temporary_directory
                    .join(format!("generated-{identifier}.wav")),
            ))
        }
    }

    impl VoiceEngine for ChatterboxVoiceEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError> {
            if reference_wav.is_empty() || text.trim().is_empty() {
                return Err(HostError::VoiceUnavailable);
            }
            let (reference_path, output_path) = self.temporary_wav_paths()?;
            std::fs::write(&reference_path, reference_wav)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let status = Command::new(&self.python_executable)
                .arg(&self.script_path)
                .arg("--engine")
                .arg(&self.engine)
                .arg("--device")
                .arg(&self.device)
                .arg("--language")
                .arg(&self.language)
                .arg("--exaggeration")
                .arg(&self.exaggeration)
                .arg("--cfg-weight")
                .arg(&self.cfg_weight)
                .arg("--temperature")
                .arg(&self.temperature)
                .arg("--min-p")
                .arg(&self.min_p)
                .arg("--top-p")
                .arg(&self.top_p)
                .arg("--repetition-penalty")
                .arg(&self.repetition_penalty)
                .arg("--reference")
                .arg(&reference_path)
                .arg("--output")
                .arg(&output_path)
                .arg("--text")
                .arg(text.trim())
                .env("PYTHONDONTWRITEBYTECODE", "1")
                .env("PYTHONNOUSERSITE", "1")
                .env(
                    "NUMBA_CACHE_DIR",
                    self.temporary_directory.join("numba-cache"),
                )
                .status()
                .map_err(|_| HostError::VoiceUnavailable);
            let _ = std::fs::remove_file(&reference_path);
            let status = status?;
            if !status.success() {
                let _ = std::fs::remove_file(&output_path);
                return Err(HostError::VoiceUnavailable);
            }
            let output = std::fs::read(&output_path).map_err(|_| HostError::VoiceUnavailable)?;
            let _ = std::fs::remove_file(&output_path);
            hound::WavReader::new(Cursor::new(&output)).map_err(|_| HostError::VoiceUnavailable)?;
            Ok(output)
        }
    }

    pub struct LuxTtsVoiceEngine {
        python_executable: PathBuf,
        script_path: PathBuf,
        worker_script_path: PathBuf,
        model: String,
        device: String,
        threads: String,
        ref_duration: String,
        rms: String,
        num_steps: String,
        t_shift: String,
        speed: String,
        seed: Option<String>,
        return_smooth: bool,
        temporary_directory: PathBuf,
        worker: Mutex<Option<LuxTtsWorker>>,
    }

    struct LuxTtsWorker {
        child: Child,
        stdin: ChildStdin,
        stdout: BufReader<ChildStdout>,
    }

    impl fmt::Debug for LuxTtsWorker {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter
                .debug_struct("LuxTtsWorker")
                .field("child_id", &self.child.id())
                .finish_non_exhaustive()
        }
    }

    impl Drop for LuxTtsWorker {
        fn drop(&mut self) {
            let _ = writeln!(self.stdin, r#"{{"command":"shutdown"}}"#);
            let _ = self.stdin.flush();
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    #[derive(Debug, Deserialize)]
    struct LuxTtsWorkerResponse {
        ok: bool,
        event: Option<String>,
        error: Option<String>,
        #[allow(dead_code)]
        cache_hit: Option<bool>,
    }

    impl LuxTtsWorker {
        fn request(
            &mut self,
            payload: serde_json::Value,
        ) -> Result<LuxTtsWorkerResponse, HostError> {
            writeln!(self.stdin, "{payload}").map_err(|_| HostError::VoiceUnavailable)?;
            self.stdin
                .flush()
                .map_err(|_| HostError::VoiceUnavailable)?;
            let mut line = String::new();
            self.stdout
                .read_line(&mut line)
                .map_err(|_| HostError::VoiceUnavailable)?;
            if line.trim().is_empty() {
                return Err(HostError::VoiceUnavailable);
            }
            serde_json::from_str::<LuxTtsWorkerResponse>(&line)
                .map_err(|_| HostError::VoiceUnavailable)
        }
    }

    impl fmt::Debug for LuxTtsVoiceEngine {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter
                .debug_struct("LuxTtsVoiceEngine")
                .field("python_executable", &self.python_executable)
                .field("script_path", &self.script_path)
                .field("worker_script_path", &self.worker_script_path)
                .field("model", &self.model)
                .field("device", &self.device)
                .field("threads", &self.threads)
                .field("ref_duration", &self.ref_duration)
                .field("rms", &self.rms)
                .field("num_steps", &self.num_steps)
                .field("t_shift", &self.t_shift)
                .field("speed", &self.speed)
                .field("seed", &self.seed)
                .field("return_smooth", &self.return_smooth)
                .finish_non_exhaustive()
        }
    }

    impl LuxTtsVoiceEngine {
        #[allow(clippy::too_many_arguments)]
        pub fn new(
            python_executable: PathBuf,
            script_path: PathBuf,
            data_directory: &Path,
            model: String,
            device: String,
            threads: String,
            ref_duration: String,
            rms: String,
            num_steps: String,
            t_shift: String,
            speed: String,
            seed: Option<String>,
            return_smooth: bool,
        ) -> Result<Self, HostError> {
            if !script_path.is_file() {
                return Err(HostError::VoiceUnavailable);
            }
            let worker_script_path = env::var_os("PLUSHPAL_LUXTTS_WORKER_SCRIPT")
                .map(PathBuf::from)
                .unwrap_or_else(|| script_path.with_file_name("luxtts_worker.py"));
            let worker_script_path = if worker_script_path.is_file() {
                worker_script_path
            } else {
                script_path.clone()
            };
            let temporary_directory = data_directory.join("voice-runtime/luxtts");
            std::fs::create_dir_all(&temporary_directory)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let mut candidate = Self {
                python_executable,
                script_path,
                worker_script_path,
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
                temporary_directory,
                worker: Mutex::new(None),
            };
            let worker = candidate.start_worker()?;
            *candidate
                .worker
                .get_mut()
                .map_err(|_| HostError::VoiceUnavailable)? = Some(worker);
            Ok(candidate)
        }

        fn base_command(&self) -> Command {
            let mut command = Command::new(&self.python_executable);
            let hf_home = env::var_os("HF_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| self.temporary_directory.join("huggingface"));
            let hf_hub_cache = env::var_os("HF_HUB_CACHE")
                .map(PathBuf::from)
                .unwrap_or_else(|| hf_home.join("hub"));
            let transformers_cache = env::var_os("TRANSFORMERS_CACHE")
                .map(PathBuf::from)
                .unwrap_or_else(|| hf_hub_cache.clone());
            command
                .env("PYTHONDONTWRITEBYTECODE", "1")
                .env("PYTHONNOUSERSITE", "1")
                .env("HF_HOME", hf_home)
                .env("HF_HUB_CACHE", hf_hub_cache)
                .env("TRANSFORMERS_CACHE", transformers_cache);
            command
        }

        fn worker_command(&self) -> Command {
            let mut command = self.base_command();
            command.arg(&self.worker_script_path);
            command
        }

        fn start_worker(&self) -> Result<LuxTtsWorker, HostError> {
            let mut command = self.worker_command();
            command
                .arg("--model")
                .arg(&self.model)
                .arg("--device")
                .arg(&self.device)
                .arg("--threads")
                .arg(&self.threads)
                .arg("--ref-duration")
                .arg(&self.ref_duration)
                .arg("--rms")
                .arg(&self.rms)
                .arg("--num-steps")
                .arg(&self.num_steps)
                .arg("--t-shift")
                .arg(&self.t_shift)
                .arg("--speed")
                .arg(&self.speed)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::inherit());
            if let Some(seed) = &self.seed {
                command.arg("--seed").arg(seed);
            }
            if self.return_smooth {
                command.arg("--return-smooth");
            }
            let mut child = command.spawn().map_err(|_| HostError::VoiceUnavailable)?;
            let stdin = child.stdin.take().ok_or(HostError::VoiceUnavailable)?;
            let stdout = child.stdout.take().ok_or(HostError::VoiceUnavailable)?;
            let mut worker = LuxTtsWorker {
                child,
                stdin,
                stdout: BufReader::new(stdout),
            };
            let mut ready_line = String::new();
            worker
                .stdout
                .read_line(&mut ready_line)
                .map_err(|_| HostError::VoiceUnavailable)?;
            let ready = serde_json::from_str::<LuxTtsWorkerResponse>(&ready_line)
                .map_err(|_| HostError::VoiceUnavailable)?;
            if ready.ok && ready.event.as_deref() == Some("ready") {
                Ok(worker)
            } else {
                if let Some(error) = ready.error {
                    eprintln!("LuxTTS worker startup failed: {error}");
                }
                Err(HostError::VoiceUnavailable)
            }
        }

        fn temporary_wav_paths(&self) -> Result<(PathBuf, PathBuf), HostError> {
            let mut random = [0_u8; 16];
            getrandom::fill(&mut random).map_err(|_| HostError::EntropyUnavailable)?;
            let identifier = hex::encode(random);
            Ok((
                self.temporary_directory
                    .join(format!("reference-{identifier}.wav")),
                self.temporary_directory
                    .join(format!("generated-{identifier}.wav")),
            ))
        }

        fn synthesize_with_worker(
            &self,
            reference_path: &Path,
            output_path: &Path,
            cache_key: &str,
            text: &str,
        ) -> Result<(), HostError> {
            let payload = serde_json::json!({
                "command": "synthesize",
                "reference": reference_path,
                "output": output_path,
                "cache_key": cache_key,
                "text": text.trim(),
            });
            let mut guard = self
                .worker
                .lock()
                .map_err(|_| HostError::VoiceUnavailable)?;
            if guard.is_none() {
                *guard = Some(self.start_worker()?);
            }
            let first = guard
                .as_mut()
                .ok_or(HostError::VoiceUnavailable)?
                .request(payload.clone());
            match first {
                Ok(response) if response.ok => Ok(()),
                Ok(response) => {
                    if let Some(error) = response.error {
                        eprintln!("LuxTTS worker synthesis failed: {error}");
                    }
                    Err(HostError::VoiceUnavailable)
                }
                Err(_) => {
                    *guard = Some(self.start_worker()?);
                    let response = guard
                        .as_mut()
                        .ok_or(HostError::VoiceUnavailable)?
                        .request(payload)?;
                    if response.ok {
                        Ok(())
                    } else {
                        if let Some(error) = response.error {
                            eprintln!("LuxTTS worker synthesis failed after restart: {error}");
                        }
                        Err(HostError::VoiceUnavailable)
                    }
                }
            }
        }
    }

    impl VoiceEngine for LuxTtsVoiceEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError> {
            if reference_wav.is_empty() || text.trim().is_empty() {
                return Err(HostError::VoiceUnavailable);
            }
            let (reference_path, output_path) = self.temporary_wav_paths()?;
            std::fs::write(&reference_path, reference_wav)
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let cache_key = format!("{:x}", Sha256::digest(reference_wav));
            let status =
                self.synthesize_with_worker(&reference_path, &output_path, &cache_key, text);
            let _ = std::fs::remove_file(&reference_path);
            if let Err(error) = status {
                let _ = std::fs::remove_file(&output_path);
                return Err(error);
            }
            let output = std::fs::read(&output_path).map_err(|_| HostError::VoiceUnavailable)?;
            let _ = std::fs::remove_file(&output_path);
            hound::WavReader::new(Cursor::new(&output)).map_err(|_| HostError::VoiceUnavailable)?;
            Ok(output)
        }
    }

    #[cfg(all(test, unix))]
    mod voice_engine_tests {
        use std::os::unix::fs::PermissionsExt;

        use super::*;

        fn unique_temp_dir() -> PathBuf {
            let mut random = [0_u8; 8];
            getrandom::fill(&mut random).expect("random temp suffix");
            std::env::temp_dir().join(format!("plushpal-chatterbox-test-{}", hex::encode(random)))
        }

        fn fixture_wav() -> Vec<u8> {
            let mut cursor = Cursor::new(Vec::new());
            let specification = hound::WavSpec {
                channels: 1,
                sample_rate: 24_000,
                bits_per_sample: 16,
                sample_format: hound::SampleFormat::Int,
            };
            {
                let mut writer =
                    hound::WavWriter::new(&mut cursor, specification).expect("create fixture wav");
                for _ in 0..24_000 {
                    writer.write_sample::<i16>(0).expect("write sample");
                }
                writer.finalize().expect("finalize fixture wav");
            }
            cursor.into_inner()
        }

        #[test]
        fn gemini_response_parser_accepts_json_text_part() {
            let response = br#"{
                "candidates": [{
                    "content": {
                        "parts": [{
                            "text": "{\"speech\":\"Woof woof, let's play gently!\",\"suggest_trusted_adult\":false}"
                        }]
                    }
                }]
            }"#;
            let parsed = GeminiConversationEngine::parse_response(response).unwrap();
            assert_eq!(parsed.speech, "Woof woof, let's play gently!");
            assert!(!parsed.suggest_trusted_adult);
        }

        #[test]
        fn demo_voice_engine_generates_valid_wav() {
            let generated = DemoVoiceEngine
                .synthesize(&fixture_wav(), "Hello from demo mode.")
                .expect("demo voice synthesis");
            let reader =
                hound::WavReader::new(Cursor::new(generated)).expect("generated wav is readable");
            assert_eq!(reader.spec().channels, 1);
            assert_eq!(reader.spec().sample_rate, 16_000);
        }

        #[test]
        fn chatterbox_engine_invokes_local_process_and_cleans_temporary_files() {
            let directory = unique_temp_dir();
            std::fs::create_dir_all(&directory).expect("create temp dir");
            let script = directory.join("fake-chatterbox.sh");
            std::fs::write(
                &script,
                r#"#!/bin/sh
if [ "$PYTHONDONTWRITEBYTECODE" != "1" ]; then
  exit 41
fi
if [ -z "$NUMBA_CACHE_DIR" ]; then
  exit 42
fi
if [ "$1" = "--healthcheck" ]; then
  exit 0
fi
reference=""
output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --reference)
      shift
      reference="$1"
      ;;
    --output)
      shift
      output="$1"
      ;;
  esac
  shift
done
cp "$reference" "$output"
"#,
            )
            .expect("write fake script");
            let mut permissions = std::fs::metadata(&script)
                .expect("script metadata")
                .permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(&script, permissions).expect("chmod fake script");

            let engine = ChatterboxVoiceEngine::new(
                PathBuf::from("/bin/sh"),
                script,
                &directory,
                "standard".to_owned(),
                "cpu".to_owned(),
                "en".to_owned(),
                "0.82".to_owned(),
                "0.28".to_owned(),
                "0.72".to_owned(),
                "0.02".to_owned(),
                "0.95".to_owned(),
                "1.1".to_owned(),
            )
            .expect("create chatterbox engine");
            let generated = engine
                .synthesize(&fixture_wav(), "Hello from PlushPal.")
                .expect("synthesize fixture");
            hound::WavReader::new(Cursor::new(generated)).expect("generated wav is readable");
            let runtime_dir = directory.join("voice-runtime/chatterbox");
            let leftover_files = std::fs::read_dir(runtime_dir)
                .expect("runtime dir")
                .filter(|entry| {
                    entry
                        .as_ref()
                        .ok()
                        .and_then(|entry| entry.file_name().into_string().ok())
                        .as_deref()
                        != Some("numba-cache")
                })
                .collect::<Result<Vec<_>, _>>()
                .expect("list runtime dir");
            assert!(leftover_files.is_empty());
            std::fs::remove_dir_all(directory).expect("remove temp dir");
        }

        #[test]
        fn luxtts_engine_invokes_local_process_and_cleans_temporary_files() {
            let directory = unique_temp_dir();
            std::fs::create_dir_all(&directory).expect("create temp dir");
            let script = directory.join("fake-luxtts.sh");
            std::fs::write(
                &script,
                r#"#!/bin/sh
if [ "$PYTHONDONTWRITEBYTECODE" != "1" ]; then
  exit 41
fi
if [ -z "$HF_HOME" ]; then
  exit 42
fi
steps=""
speed=""
seed=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --num-steps)
      shift
      steps="$1"
      ;;
    --speed)
      shift
      speed="$1"
      ;;
    --seed)
      shift
      seed="$1"
      ;;
  esac
  shift
done
if [ "$steps" != "8" ] || [ "$speed" != "0.88" ] || [ "$seed" != "11" ]; then
  exit 43
fi
printf '{"ok":true,"event":"ready"}\n'
while IFS= read -r line; do
  case "$line" in
    *shutdown*)
      printf '{"ok":true,"event":"shutdown"}\n'
      exit 0
      ;;
  esac
  reference=$(printf '%s' "$line" | sed -n 's/.*"reference":"\([^"]*\)".*/\1/p')
  output=$(printf '%s' "$line" | sed -n 's/.*"output":"\([^"]*\)".*/\1/p')
  cache_key=$(printf '%s' "$line" | sed -n 's/.*"cache_key":"\([^"]*\)".*/\1/p')
  if [ -z "$reference" ] || [ -z "$output" ] || [ -z "$cache_key" ]; then
    printf '{"ok":false,"error":"bad request"}\n'
    continue
  fi
  cp "$reference" "$output"
  printf '{"ok":true,"cache_hit":false}\n'
done
"#,
            )
            .expect("write fake script");
            let mut permissions = std::fs::metadata(&script)
                .expect("script metadata")
                .permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(&script, permissions).expect("chmod fake script");

            let engine = LuxTtsVoiceEngine::new(
                PathBuf::from("/bin/sh"),
                script,
                &directory,
                "YatharthS/LuxTTS".to_owned(),
                "cpu".to_owned(),
                "4".to_owned(),
                "180".to_owned(),
                "0.01".to_owned(),
                "8".to_owned(),
                "0.9".to_owned(),
                "0.88".to_owned(),
                Some("11".to_owned()),
                false,
            )
            .expect("create luxtts engine");
            let generated = engine
                .synthesize(&fixture_wav(), "Hello from PlushPal.")
                .expect("synthesize fixture");
            hound::WavReader::new(Cursor::new(generated)).expect("generated wav is readable");
            let runtime_dir = directory.join("voice-runtime/luxtts");
            let leftover_files = std::fs::read_dir(runtime_dir)
                .expect("runtime dir")
                .filter(|entry| {
                    entry
                        .as_ref()
                        .ok()
                        .and_then(|entry| entry.file_name().into_string().ok())
                        .as_deref()
                        != Some("huggingface")
                })
                .collect::<Result<Vec<_>, _>>()
                .expect("list runtime dir");
            assert!(leftover_files.is_empty());
            std::fs::remove_dir_all(directory).expect("remove temp dir");
        }
    }

    #[derive(Debug)]
    pub struct NativeConversationEngine {
        provider: Arc<NativeProvider>,
        session: LocalConversationSession<Arc<NativeProvider>>,
    }

    impl NativeConversationEngine {
        pub fn load(model_path: &Path) -> Result<Self, ConversationEngineError> {
            let backend = NativeLlamaBackend::create(CAbiLlamaApi)
                .map_err(|_| ConversationEngineError::NotReady)?;
            let provider = Arc::new(LlamaCppProvider::new(backend, "local-llama.cpp", 16_000));
            provider
                .load(model_path)
                .map_err(|_| ConversationEngineError::NotReady)?;
            let session =
                LocalConversationSession::new(Arc::clone(&provider), Duration::from_secs(30), 12);
            Ok(Self { provider, session })
        }
    }

    impl ConversationEngine for NativeConversationEngine {
        fn is_ready(&self) -> bool {
            true
        }
        fn generate_local(
            &self,
            command: LocalTurnCommand,
        ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
            tokio::runtime::Handle::current()
                .block_on(self.session.generate_with_guidance(
                    command.age_band,
                    command.character_alias,
                    command.parent_guidance,
                    command.text,
                ))
                .map_err(|_| ConversationEngineError::GenerationFailed)
        }

        fn cancel(&self) -> Result<(), ConversationEngineError> {
            self.provider
                .cancel()
                .map_err(|_| ConversationEngineError::GenerationFailed)
        }

        fn clear_session(&self) -> Result<(), ConversationEngineError> {
            self.session
                .clear()
                .map_err(|_| ConversationEngineError::GenerationFailed)
        }
    }

    #[derive(Debug)]
    pub struct GeminiConversationEngine {
        api_key: String,
        model: String,
        client: reqwest::blocking::Client,
    }

    #[derive(Debug)]
    pub struct DemoConversationEngine;

    impl ConversationEngine for DemoConversationEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn generate_local(
            &self,
            command: LocalTurnCommand,
        ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
            let child_text = command.text.trim();
            let speech = if child_text.is_empty() {
                format!("{} is here and ready to play!", command.character_alias)
            } else {
                format!(
                    "{} heard you say: “{}” Let’s pretend together!",
                    command.character_alias,
                    child_text.chars().take(90).collect::<String>()
                )
            };
            Ok(StructuredCharacterResponse {
                speech,
                suggest_trusted_adult: false,
            })
        }

        fn cancel(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }

        fn clear_session(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }
    }

    #[derive(Deserialize)]
    struct GeminiResponseEnvelope {
        candidates: Vec<GeminiCandidate>,
    }

    #[derive(Deserialize)]
    struct GeminiCandidate {
        content: GeminiContent,
    }

    #[derive(Deserialize)]
    struct GeminiContent {
        parts: Vec<GeminiPart>,
    }

    #[derive(Deserialize)]
    struct GeminiPart {
        text: String,
    }

    #[derive(Deserialize)]
    struct GeminiStructuredResponse {
        speech: String,
        suggest_trusted_adult: bool,
    }

    impl GeminiConversationEngine {
        pub fn new(api_key: String, model: String) -> Result<Self, ConversationEngineError> {
            if api_key.trim().is_empty() || api_key.chars().any(char::is_control) {
                return Err(ConversationEngineError::NotReady);
            }
            let client = reqwest::blocking::Client::builder()
                .timeout(Duration::from_secs(30))
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy()
                .build()
                .map_err(|_| ConversationEngineError::NotReady)?;
            Ok(Self {
                api_key,
                model,
                client,
            })
        }

        fn prompt(command: &LocalTurnCommand) -> String {
            let age_band = match command.age_band {
                AgeBand::FourToFive => "4-5",
                AgeBand::SixToEight => "6-8",
                AgeBand::NineToTwelve => "9-12",
            };
            let guidance = command
                .parent_guidance
                .as_deref()
                .unwrap_or("cheerful, gentle, playful");
            format!(
                "You are a fictional plush toy character named {character}. The child age band is {age_band}. Toy memory and parent guidance: {guidance}. Treat likes, favorite things, personality notes, and pretend-play details here as true for {character}; use them naturally when relevant. \
                 Safety rules: be age-appropriate, do not ask for private identifying information, addresses, school, secrets, photos, purchases, meetings, or unsafe actions. \
                 If the child asks about danger, injury, self-harm, violence, secrets, or anything unsafe, give a very short supportive answer and set suggest_trusted_adult=true. \
                 Keep normal replies warm, playful, concrete, and easy for a young child. Prefer 2-4 tiny sentences, usually 25-45 words total. Short answers are fine for simple prompts, but do not sound clipped or robotic. \
                 Return only JSON with exactly these fields: speech string, suggest_trusted_adult boolean. \
                 Child said: {text}",
                character = command.character_alias,
                age_band = age_band,
                guidance = guidance,
                text = command.text,
            )
        }

        fn parse_response(
            bytes: &[u8],
        ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
            let envelope: GeminiResponseEnvelope = serde_json::from_slice(bytes)
                .map_err(|_| ConversationEngineError::GenerationFailed)?;
            let text = envelope
                .candidates
                .into_iter()
                .flat_map(|candidate| candidate.content.parts)
                .map(|part| part.text)
                .find(|text| !text.trim().is_empty())
                .ok_or(ConversationEngineError::GenerationFailed)?;
            let json =
                extract_json_object(&text).ok_or(ConversationEngineError::GenerationFailed)?;
            let structured: GeminiStructuredResponse = serde_json::from_str(json)
                .map_err(|_| ConversationEngineError::GenerationFailed)?;
            let speech = structured.speech.trim();
            if speech.is_empty() || speech.chars().count() > 500 {
                return Err(ConversationEngineError::GenerationFailed);
            }
            Ok(StructuredCharacterResponse {
                speech: speech.to_owned(),
                suggest_trusted_adult: structured.suggest_trusted_adult,
            })
        }
    }

    fn extract_json_object(text: &str) -> Option<&str> {
        let trimmed = text.trim();
        if trimmed.starts_with('{') && trimmed.ends_with('}') {
            return Some(trimmed);
        }
        let start = trimmed.find('{')?;
        let end = trimmed.rfind('}')?;
        (start < end).then_some(&trimmed[start..=end])
    }

    impl ConversationEngine for GeminiConversationEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn generate_local(
            &self,
            command: LocalTurnCommand,
        ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
            let url = format!(
                "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent",
                self.model
            );
            let body = serde_json::json!({
                "contents": [{
                    "role": "user",
                    "parts": [{"text": Self::prompt(&command)}]
                }],
                "generationConfig": {
                    "temperature": 0.2,
                    "topP": 0.9,
                    "maxOutputTokens": 400,
                    "responseMimeType": "application/json"
                }
            });
            let response = self
                .client
                .post(url)
                .header("x-goog-api-key", &self.api_key)
                .json(&body)
                .send()
                .map_err(|_| ConversationEngineError::GenerationFailed)?;
            if !response.status().is_success() {
                return Err(ConversationEngineError::GenerationFailed);
            }
            let bytes = response
                .bytes()
                .map_err(|_| ConversationEngineError::GenerationFailed)?;
            Self::parse_response(bytes.as_ref())
        }

        fn cancel(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }

        fn clear_session(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }
    }

    #[derive(Debug)]
    pub struct NativeModelInstaller {
        destination_directory: PathBuf,
        installing: AtomicBool,
        cancelled: AtomicBool,
    }

    impl NativeModelInstaller {
        #[must_use]
        pub fn new(destination_directory: PathBuf) -> Self {
            Self {
                destination_directory,
                installing: AtomicBool::new(false),
                cancelled: AtomicBool::new(false),
            }
        }

        pub fn installed_model_path(&self) -> Result<PathBuf, ModelInstallError> {
            let manifest =
                bundled_private_beta_manifest().map_err(|_| ModelInstallError::ActivationFailed)?;
            Ok(self
                .destination_directory
                .join(format!("{}-{}.gguf", manifest.model_id, manifest.version)))
        }

        pub fn verified_installed_model_path(&self) -> Result<Option<PathBuf>, ModelInstallError> {
            let manifest =
                bundled_private_beta_manifest().map_err(|_| ModelInstallError::ActivationFailed)?;
            let path = self.installed_model_path()?;
            if !path.is_file() {
                return Ok(None);
            }
            verify_model_artifact(&manifest, &path)
                .map_err(|_| ModelInstallError::ActivationFailed)?;
            Ok(Some(path))
        }

        pub fn verify_model_path(path: &Path) -> Result<(), ModelInstallError> {
            let manifest =
                bundled_private_beta_manifest().map_err(|_| ModelInstallError::ActivationFailed)?;
            verify_model_artifact(&manifest, path).map_err(|_| ModelInstallError::ActivationFailed)
        }
    }

    struct InstallGuard<'a>(&'a AtomicBool);

    impl Drop for InstallGuard<'_> {
        fn drop(&mut self) {
            self.0.store(false, Ordering::Release);
        }
    }

    impl ModelInstaller for NativeModelInstaller {
        fn supported(&self) -> bool {
            true
        }

        fn installing(&self) -> bool {
            self.installing.load(Ordering::Acquire)
        }

        fn install(&self) -> Result<Arc<dyn ConversationEngine>, ModelInstallError> {
            self.installing
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .map_err(|_| ModelInstallError::AlreadyInstalling)?;
            let _guard = InstallGuard(&self.installing);
            self.cancelled.store(false, Ordering::Release);
            let manifest =
                bundled_private_beta_manifest().map_err(|_| ModelInstallError::ActivationFailed)?;
            std::fs::create_dir_all(&self.destination_directory)
                .map_err(|_| ModelInstallError::ActivationFailed)?;
            let installed_path = self
                .destination_directory
                .join(format!("{}-{}.gguf", manifest.model_id, manifest.version));
            if installed_path.is_file() {
                if verify_model_artifact(&manifest, &installed_path).is_ok() {
                    let engine = NativeConversationEngine::load(&installed_path)
                        .map_err(|_| ModelInstallError::ActivationFailed)?;
                    return Ok(Arc::new(engine));
                }
                std::fs::remove_file(&installed_path)
                    .map_err(|_| ModelInstallError::ActivationFailed)?;
            }
            let partial_path = installed_path.with_extension("partial");
            let partial_bytes = partial_path.metadata().map_or(0, |metadata| metadata.len());
            let remaining = manifest.download_size_bytes.saturating_sub(partial_bytes);
            let required = remaining.saturating_add(512 * 1024 * 1024);
            let available = fs2::available_space(&self.destination_directory)
                .map_err(|_| ModelInstallError::ActivationFailed)?;
            if available < required {
                return Err(ModelInstallError::InsufficientStorage);
            }
            let path = ProductionModelDownloader
                .download_cancellable(
                    &manifest,
                    &self.destination_directory,
                    Duration::from_secs(7_200),
                    || self.cancelled.load(Ordering::Acquire),
                )
                .map_err(|_| ModelInstallError::DownloadFailed)?;
            let engine = NativeConversationEngine::load(&path)
                .map_err(|_| ModelInstallError::ActivationFailed)?;
            Ok(Arc::new(engine))
        }

        fn cancel(&self) {
            self.cancelled.store(true, Ordering::Release);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{
        collections::{HashMap, HashSet},
        io::Cursor,
        sync::atomic::{AtomicBool, Ordering},
    };

    use axum::body::Body;
    use axum::http::Request;
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    use super::*;

    #[derive(Debug)]
    struct FixedToken;
    impl TokenSource for FixedToken {
        fn generate(&self) -> Result<Vec<u8>, HostError> {
            Ok(b"fixed-session-token".to_vec())
        }
    }

    #[derive(Debug)]
    struct FixedClock;
    impl Clock for FixedClock {
        fn now_seconds(&self) -> Result<i64, HostError> {
            Ok(100)
        }
    }

    #[derive(Debug, Default)]
    struct MemoryProfileStore {
        profile: Mutex<Option<PersistedParentProfile>>,
        history: Mutex<Vec<ConversationHistoryEntry>>,
        voice: Mutex<Option<(Vec<u8>, VoiceSampleFacts)>>,
        character_voices: Mutex<HashMap<String, (Vec<u8>, VoiceSampleFacts)>>,
        character_voice_approvals: Mutex<HashSet<String>>,
        voice_approved: AtomicBool,
        deleted: AtomicBool,
    }

    impl ParentProfileStore for MemoryProfileStore {
        fn load(&self) -> Result<Option<PersistedParentProfile>, HostError> {
            self.profile
                .lock()
                .map(|profile| profile.clone())
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn save(&self, profile: &PersistedParentProfile) -> Result<(), HostError> {
            *self
                .profile
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = Some(profile.clone());
            Ok(())
        }

        fn delete_all(&self) -> Result<(), HostError> {
            *self
                .profile
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = None;
            self.deleted.store(true, Ordering::Release);
            self.history
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .clear();
            *self
                .voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = None;
            self.character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .clear();
            self.character_voice_approvals
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .clear();
            self.voice_approved.store(false, Ordering::Release);
            Ok(())
        }

        fn history(
            &self,
            maximum_turns: usize,
        ) -> Result<Vec<ConversationHistoryEntry>, HostError> {
            self.history
                .lock()
                .map(|history| history.iter().take(maximum_turns).cloned().collect())
                .map_err(|_| HostError::PersistenceUnavailable)
        }

        fn delete_history(&self) -> Result<(), HostError> {
            self.history
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .clear();
            Ok(())
        }

        fn voice_status(&self) -> Result<VoiceProfileStatus, HostError> {
            let voice = self
                .voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            Ok(VoiceProfileStatus {
                enrolled: voice.is_some(),
                approved: voice.is_some() && self.voice_approved.load(Ordering::Acquire),
                runtime_ready: false,
                duration_milliseconds: voice.as_ref().map(|(_, facts)| facts.duration_milliseconds),
                profile_id: voice.as_ref().map(|_| "primary-voice".to_owned()),
            })
        }

        fn voice_status_for_character(&self, alias: &str) -> Result<VoiceProfileStatus, HostError> {
            let normalized = alias.trim().to_owned();
            let voices = self
                .character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let approvals = self
                .character_voice_approvals
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?;
            let voice = voices.get(&normalized);
            Ok(VoiceProfileStatus {
                enrolled: voice.is_some(),
                approved: voice.is_some() && approvals.contains(&normalized),
                runtime_ready: false,
                duration_milliseconds: voice.map(|(_, facts)| facts.duration_milliseconds),
                profile_id: voice.map(|_| profile_id_for_alias(&normalized)),
            })
        }

        fn store_voice_sample(&self, wav: &[u8], facts: VoiceSampleFacts) -> Result<(), HostError> {
            *self
                .voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = Some((wav.to_vec(), facts));
            self.voice_approved.store(false, Ordering::Release);
            Ok(())
        }

        fn store_voice_sample_for_character(
            &self,
            alias: &str,
            wav: &[u8],
            facts: VoiceSampleFacts,
        ) -> Result<(), HostError> {
            let normalized = alias.trim().to_owned();
            self.character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .insert(normalized.clone(), (wav.to_vec(), facts));
            self.character_voice_approvals
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .remove(&normalized);
            Ok(())
        }

        fn load_voice_sample(&self) -> Result<Vec<u8>, HostError> {
            self.voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .as_ref()
                .map(|(wav, _)| wav.clone())
                .ok_or(HostError::VoiceUnavailable)
        }

        fn load_voice_sample_for_character(&self, alias: &str) -> Result<Vec<u8>, HostError> {
            self.character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .get(alias.trim())
                .map(|(wav, _)| wav.clone())
                .ok_or(HostError::VoiceUnavailable)
        }

        fn approve_voice(&self) -> Result<(), HostError> {
            if self
                .voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .is_none()
            {
                return Err(HostError::VoiceUnavailable);
            }
            self.voice_approved.store(true, Ordering::Release);
            Ok(())
        }

        fn approve_voice_for_character(&self, alias: &str) -> Result<(), HostError> {
            let normalized = alias.trim().to_owned();
            if !self
                .character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .contains_key(&normalized)
            {
                return Err(HostError::VoiceUnavailable);
            }
            self.character_voice_approvals
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .insert(normalized);
            Ok(())
        }

        fn delete_voice(&self) -> Result<(), HostError> {
            *self
                .voice
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)? = None;
            self.voice_approved.store(false, Ordering::Release);
            Ok(())
        }

        fn delete_voice_for_character(&self, alias: &str) -> Result<(), HostError> {
            let normalized = alias.trim().to_owned();
            self.character_voices
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .remove(&normalized);
            self.character_voice_approvals
                .lock()
                .map_err(|_| HostError::PersistenceUnavailable)?
                .remove(&normalized);
            Ok(())
        }
    }

    #[derive(Debug, Default)]
    struct InvalidProfileStore {
        deleted: AtomicBool,
    }

    impl ParentProfileStore for InvalidProfileStore {
        fn load(&self) -> Result<Option<PersistedParentProfile>, HostError> {
            Err(HostError::InvalidPersistedProfile)
        }

        fn save(&self, _profile: &PersistedParentProfile) -> Result<(), HostError> {
            Ok(())
        }

        fn delete_all(&self) -> Result<(), HostError> {
            self.deleted.store(true, Ordering::Release);
            Ok(())
        }
    }

    #[derive(Debug)]
    struct ReadyEngine;

    impl ConversationEngine for ReadyEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn generate_local(
            &self,
            _command: LocalTurnCommand,
        ) -> Result<StructuredCharacterResponse, ConversationEngineError> {
            Ok(StructuredCharacterResponse {
                speech: "Ready".to_owned(),
                suggest_trusted_adult: false,
            })
        }

        fn cancel(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }

        fn clear_session(&self) -> Result<(), ConversationEngineError> {
            Ok(())
        }
    }

    #[derive(Debug)]
    struct FixtureVoiceEngine;

    impl VoiceEngine for FixtureVoiceEngine {
        fn is_ready(&self) -> bool {
            true
        }

        fn synthesize(&self, reference_wav: &[u8], text: &str) -> Result<Vec<u8>, HostError> {
            if reference_wav.is_empty() || text.trim().is_empty() {
                return Err(HostError::VoiceUnavailable);
            }
            Ok(b"RIFFfixture-voice".to_vec())
        }
    }

    #[derive(Debug)]
    struct FixtureInstaller {
        installed: Arc<AtomicBool>,
    }

    impl ModelInstaller for FixtureInstaller {
        fn supported(&self) -> bool {
            true
        }

        fn installing(&self) -> bool {
            false
        }

        fn install(&self) -> Result<Arc<dyn ConversationEngine>, ModelInstallError> {
            self.installed.store(true, Ordering::Release);
            Ok(Arc::new(ReadyEngine))
        }

        fn cancel(&self) {}
    }

    fn router() -> Router {
        build_router(HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        ))
    }

    fn router_with_installer(installed: Arc<AtomicBool>) -> Router {
        build_router(
            HostState::new(
                LoopbackEndpoint { port: 3210 },
                b"bootstrap",
                Arc::new(FixedToken),
                Arc::new(FixedClock),
            )
            .with_model_installer(Arc::new(FixtureInstaller { installed })),
        )
    }

    #[test]
    fn invalid_persisted_parent_profile_is_cleared_instead_of_blocking_startup() {
        let store = Arc::new(InvalidProfileStore::default());
        let state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store.clone())
        .expect("invalid persisted profile should be cleared");

        assert!(state.parent_profile_store.is_some());
        assert!(state.parent_pin.lock().unwrap().is_none());
        assert!(store.deleted.load(Ordering::Acquire));
    }

    fn bootstrap_request(token: &str) -> Request<Body> {
        Request::post("/api/v1/bootstrap")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header("x-plushpal-bootstrap", token)
            .body(Body::empty())
            .unwrap()
    }

    async fn authenticated_cookie(app: &Router) -> String {
        let bootstrap = app
            .clone()
            .oneshot(bootstrap_request("bootstrap"))
            .await
            .unwrap();
        bootstrap
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_owned()
    }

    fn valid_voice_wav(sample_rate: u32) -> Vec<u8> {
        let mut cursor = Cursor::new(Vec::new());
        let specification = hound::WavSpec {
            channels: 1,
            sample_rate,
            bits_per_sample: 16,
            sample_format: hound::SampleFormat::Int,
        };
        {
            let mut writer = hound::WavWriter::new(&mut cursor, specification).unwrap();
            for index in 0..sample_rate * 20 {
                let within_second = index % sample_rate;
                let sample = if within_second < sample_rate / 10 {
                    0
                } else {
                    let phase = 2.0 * std::f64::consts::PI * 220.0 * f64::from(index)
                        / f64::from(sample_rate);
                    (phase.sin() * 5_000.0) as i16
                };
                writer.write_sample(sample).unwrap();
            }
            writer.finalize().unwrap();
        }
        cursor.into_inner()
    }

    fn authenticated_json_request(path: &'static str, cookie: &str, body: String) -> Request<Body> {
        Request::post(path)
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::COOKIE, cookie)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body))
            .unwrap()
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn imported_audio_is_converted_to_backend_wav_locally() {
        let source = valid_voice_wav(44_100);
        let converted =
            convert_imported_audio_to_wav(&source, Some("sample.wav"), Some("audio/wav")).unwrap();
        let facts = inspect_wav(&converted, true).unwrap();
        assert_eq!(facts.duration_milliseconds, 20_000);
    }

    #[tokio::test]
    async fn bootstrap_then_authenticated_status_runs_through_real_router() {
        let app = router();
        let bootstrap = app
            .clone()
            .oneshot(bootstrap_request("bootstrap"))
            .await
            .unwrap();
        assert_eq!(bootstrap.status(), StatusCode::NO_CONTENT);
        let cookie = bootstrap
            .headers()
            .get(header::SET_COOKIE)
            .unwrap()
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap()
            .to_owned();
        let status = app
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(status.status(), StatusCode::OK);
        let body = status.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8_lossy(&body);
        assert!(body.contains(r#""local_only":true"#));
        assert!(body.contains(r#""model_ready":false"#));
    }

    #[tokio::test]
    async fn diagnostics_requires_authentication_and_redacts_private_data() {
        let store = Arc::new(MemoryProfileStore::default());
        let state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store)
        .unwrap()
        .with_voice_engine(Arc::new(FixtureVoiceEngine));
        let app = build_router(state);
        let unauthenticated = app
            .clone()
            .oneshot(
                Request::get("/api/v1/diagnostics")
                    .header(header::HOST, "127.0.0.1:3210")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);

        let cookie = authenticated_cookie(&app).await;
        let diagnostics = app
            .oneshot(
                Request::get("/api/v1/diagnostics")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(diagnostics.status(), StatusCode::OK);
        let body = diagnostics.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8_lossy(&body);
        assert!(body.contains(r#""schema_version":1"#));
        assert!(body.contains(r#""loopback_origin":"http://127.0.0.1:3210""#));
        assert!(body.contains(r#""voice_engine_ready":true"#));
        assert!(body.contains(r#""parent_profile_store_ready":true"#));
        assert!(!body.contains("pin"));
        assert!(!body.contains("api_key"));
        assert!(!body.contains("prompt"));
        assert!(!body.contains("child_text"));
    }

    #[tokio::test]
    async fn health_is_available_before_parent_session_without_private_data() {
        let app = router();
        let response = app
            .oneshot(
                Request::get("/api/v1/health")
                    .header(header::HOST, "127.0.0.1:3210")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8_lossy(&body);
        assert!(body.contains(r#""local_service_ready":true"#));
        assert!(body.contains(r#""voice_engine_ready":false"#));
        assert!(body.contains(r#""browser_ui_ready":true"#));
        assert!(!body.contains("pin"));
        assert!(!body.contains("character_alias"));
        assert!(!body.contains("parent_guidance"));
    }

    #[tokio::test]
    async fn status_does_not_restore_setup_without_a_valid_parent_profile() {
        let store = Arc::new(MemoryProfileStore::default());
        let mut state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store)
        .unwrap();
        state.parent_pin = Arc::new(Mutex::new(Some(ParentPinState {
            hash: ParentPinHash::derive("4826", [7; 16]).unwrap(),
            gate: ParentGate::default(),
        })));
        let app = build_router(state);
        let cookie = authenticated_cookie(&app).await;
        let status = app
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(status.status(), StatusCode::OK);
        let body = status.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8_lossy(&body);
        assert!(body.contains(r#""parent_configured":false"#));
        assert!(!body.contains(r#""age_band":"#));
    }

    #[tokio::test]
    async fn repeated_bootstrap_pairing_is_allowed_but_unauthenticated_status_is_rejected() {
        let app = router();
        assert_eq!(
            app.clone()
                .oneshot(bootstrap_request("bootstrap"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            app.clone()
                .oneshot(bootstrap_request("bootstrap"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        let response = app
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn parent_pin_is_hashed_authorized_and_rate_limited_by_core() {
        let app = router();
        let cookie = authenticated_cookie(&app).await;
        let request = |path: &'static str, pin: &'static str| {
            Request::post(path)
                .header(header::HOST, "127.0.0.1:3210")
                .header(header::ORIGIN, "http://127.0.0.1:3210")
                .header(header::COOKIE, &cookie)
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap()
        };
        assert_eq!(
            app.clone()
                .oneshot(request("/api/v1/parent-pin/configure", "4826"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            app.clone()
                .oneshot(request("/api/v1/parent-pin/authorize", "1111"))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            app.clone()
                .oneshot(request("/api/v1/parent-pin/authorize", "4826"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            app.oneshot(request("/api/v1/parent-pin/configure", "4826"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
    }

    #[tokio::test]
    async fn parent_profile_survives_host_restart_and_pin_gates_deletion() {
        let store = Arc::new(MemoryProfileStore::default());
        let state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store.clone())
        .unwrap();
        let app = build_router(state);
        let cookie = authenticated_cookie(&app).await;
        let configure = Request::post("/api/v1/parent-pin/configure")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::COOKIE, &cookie)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                r#"{"pin":"4826","age_band":"6-8","character_alias":"Teddy"}"#,
            ))
            .unwrap();
        assert_eq!(
            app.oneshot(configure).await.unwrap().status(),
            StatusCode::NO_CONTENT
        );
        let saved = store.load().unwrap().unwrap();
        assert_eq!(saved.age_band, AgeBand::SixToEight);
        assert_eq!(saved.character_alias, "Teddy");
        assert!(!saved.pin_hash.encoded().contains("4826"));

        let restarted = build_router(
            HostState::new(
                LoopbackEndpoint { port: 3210 },
                b"bootstrap",
                Arc::new(FixedToken),
                Arc::new(FixedClock),
            )
            .with_parent_profile_store(store.clone())
            .unwrap(),
        );
        let restarted_cookie = authenticated_cookie(&restarted).await;
        let deletion = |pin: &'static str| {
            Request::post("/api/v1/local-data/delete")
                .header(header::HOST, "127.0.0.1:3210")
                .header(header::ORIGIN, "http://127.0.0.1:3210")
                .header(header::COOKIE, &restarted_cookie)
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap()
        };
        assert_eq!(
            restarted
                .clone()
                .oneshot(deletion("1111"))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            restarted.oneshot(deletion("4826")).await.unwrap().status(),
            StatusCode::NO_CONTENT
        );
        assert!(store.deleted.load(Ordering::Acquire));
        assert_eq!(store.load().unwrap(), None);
    }

    #[tokio::test]
    async fn voice_enrollment_preview_approval_speech_and_deletion_are_parent_gated() {
        let profile = PersistedParentProfile {
            pin_hash: ParentPinHash::derive("4826", [7; 16]).unwrap(),
            age_band: AgeBand::SixToEight,
            character_alias: "Teddy".to_owned(),
            character_traits: vec!["gentle".to_owned()],
            parent_guidance: None,
            retention_days: None,
        };
        let store = Arc::new(MemoryProfileStore::default());
        store.save(&profile).unwrap();
        let state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store.clone())
        .unwrap()
        .with_voice_engine(Arc::new(FixtureVoiceEngine));
        let voice_synthesis_busy = Arc::clone(&state.voice_synthesis_busy);
        let app = build_router(state);
        let cookie = authenticated_cookie(&app).await;
        let wav = valid_voice_wav(48_000);
        let encoded = BASE64.encode(&wav);
        assert!(encoded.len() > 1_048_576);

        let denied = serde_json::json!({
            "pin": "4826",
            "wav_base64": encoded,
            "adult_authorized": false
        })
        .to_string();
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/enroll",
                    &cookie,
                    denied,
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::UNPROCESSABLE_ENTITY
        );

        let enrollment = serde_json::json!({
            "pin": "4826",
            "wav_base64": BASE64.encode(&wav),
            "adult_authorized": true
        })
        .to_string();
        let enrollment_response = app
            .clone()
            .oneshot(authenticated_json_request(
                "/api/v1/voice/enroll",
                &cookie,
                enrollment,
            ))
            .await
            .unwrap();
        assert_eq!(enrollment_response.status(), StatusCode::OK);
        let enrollment_body = enrollment_response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes();
        let enrollment_body = std::str::from_utf8(&enrollment_body).unwrap();
        assert!(enrollment_body.contains(r#""profile_id":"primary-voice""#));

        let status = app
            .clone()
            .oneshot(
                Request::get("/api/v1/voice/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, &cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let status_body = status.into_body().collect().await.unwrap().to_bytes();
        let status_body = String::from_utf8_lossy(&status_body);
        assert!(status_body.contains(r#""enrolled":true"#));
        assert!(status_body.contains(r#""approved":false"#));
        assert!(status_body.contains(r#""runtime_ready":true"#));

        let preview = app
            .clone()
            .oneshot(authenticated_json_request(
                "/api/v1/voice/preview",
                &cookie,
                r#"{"pin":"4826","text":"Hello from your character."}"#.to_owned(),
            ))
            .await
            .unwrap();
        assert_eq!(preview.status(), StatusCode::OK);
        assert_eq!(
            preview.headers().get(header::CONTENT_TYPE).unwrap(),
            "audio/wav"
        );
        assert_eq!(
            preview.headers().get(header::CACHE_CONTROL).unwrap(),
            "no-store"
        );
        voice_synthesis_busy.store(true, Ordering::Release);
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/preview",
                    &cookie,
                    r#"{"pin":"4826","text":"Already generating."}"#.to_owned(),
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::CONFLICT
        );
        voice_synthesis_busy.store(false, Ordering::Release);

        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/speak",
                    &cookie,
                    r#"{"text":"Not approved yet."}"#.to_owned(),
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::PRECONDITION_REQUIRED
        );
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/approve",
                    &cookie,
                    r#"{"pin":"4826"}"#.to_owned(),
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/speak",
                    &cookie,
                    r#"{"text":"Approved speech."}"#.to_owned(),
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/delete",
                    &cookie,
                    r#"{"pin":"4826"}"#.to_owned(),
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert!(!store.voice_status().unwrap().enrolled);
        let status = app
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, &cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(status.status(), StatusCode::OK);
        let body = status.into_body().collect().await.unwrap().to_bytes();
        let body = String::from_utf8_lossy(&body);
        assert!(body.contains(r#""parent_configured":true"#));
        assert!(body.contains(r#""character_alias":"Teddy""#));
    }

    #[tokio::test]
    async fn paired_voice_station_allows_android_owned_parent_pin() {
        let store = Arc::new(MemoryProfileStore::default());
        let state = HostState::new(
            LoopbackEndpoint { port: 3210 },
            b"bootstrap",
            Arc::new(FixedToken),
            Arc::new(FixedClock),
        )
        .with_parent_profile_store(store.clone())
        .unwrap()
        .with_voice_engine(Arc::new(FixtureVoiceEngine));
        let app = build_router(state);
        let cookie = authenticated_cookie(&app).await;
        let wav = valid_voice_wav(48_000);

        let enrollment = serde_json::json!({
            "pin": "android-owned-pin",
            "wav_base64": BASE64.encode(&wav),
            "adult_authorized": true,
            "character_alias": "Buddy"
        })
        .to_string();
        assert_eq!(
            app.clone()
                .oneshot(authenticated_json_request(
                    "/api/v1/voice/enroll",
                    &cookie,
                    enrollment,
                ))
                .await
                .unwrap()
                .status(),
            StatusCode::OK
        );
        assert_eq!(
            app.oneshot(authenticated_json_request(
                "/api/v1/voice/approve",
                &cookie,
                r#"{"pin":"android-owned-pin","character_alias":"Buddy"}"#.to_owned(),
            ))
            .await
            .unwrap()
            .status(),
            StatusCode::NO_CONTENT
        );
        assert!(store.voice_status_for_character("Buddy").unwrap().approved);
        let new_buddy_status = store.voice_status_for_character("NewBuddy").unwrap();
        assert!(!new_buddy_status.enrolled);
        assert!(!new_buddy_status.approved);
    }

    #[tokio::test]
    async fn retained_history_requires_parent_pin_and_can_be_deleted() {
        let profile = PersistedParentProfile {
            pin_hash: ParentPinHash::derive("4826", [7; 16]).unwrap(),
            age_band: AgeBand::SixToEight,
            character_alias: "Teddy".to_owned(),
            character_traits: vec!["gentle".to_owned()],
            parent_guidance: Some("Likes science.".to_owned()),
            retention_days: Some(7),
        };
        let store = Arc::new(MemoryProfileStore::default());
        store.save(&profile).unwrap();
        store
            .history
            .lock()
            .unwrap()
            .push(ConversationHistoryEntry {
                child_text: "Why is the sky blue?".to_owned(),
                character_text: "Blue light scatters more.".to_owned(),
                completed_at: 100,
            });
        let app = build_router(
            HostState::new(
                LoopbackEndpoint { port: 3210 },
                b"bootstrap",
                Arc::new(FixedToken),
                Arc::new(FixedClock),
            )
            .with_parent_profile_store(store.clone())
            .unwrap(),
        );
        let cookie = authenticated_cookie(&app).await;
        let request = |path: &'static str, pin: &'static str| {
            Request::post(path)
                .header(header::HOST, "127.0.0.1:3210")
                .header(header::ORIGIN, "http://127.0.0.1:3210")
                .header(header::COOKIE, &cookie)
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(format!(r#"{{"pin":"{pin}"}}"#)))
                .unwrap()
        };
        assert_eq!(
            app.clone()
                .oneshot(request("/api/v1/history/list", "1111"))
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let history = app
            .clone()
            .oneshot(request("/api/v1/history/list", "4826"))
            .await
            .unwrap();
        assert_eq!(history.status(), StatusCode::OK);
        let body = history.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&body).contains("Why is the sky blue?"));
        assert_eq!(
            app.oneshot(request("/api/v1/history/delete", "4826"))
                .await
                .unwrap()
                .status(),
            StatusCode::NO_CONTENT
        );
        assert!(store.history.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn middleware_rejects_evil_host_origin_and_oversized_body() {
        let app = router();
        let evil_host = Request::get("/api/v1/status")
            .header(header::HOST, "evil.example")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.clone().oneshot(evil_host).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
        let evil_origin = Request::post("/api/v1/bootstrap")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "https://evil.example")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.clone().oneshot(evil_origin).await.unwrap().status(),
            StatusCode::FORBIDDEN
        );
        let oversized = Request::post("/api/v1/bootstrap")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::CONTENT_LENGTH, "12582913")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.oneshot(oversized).await.unwrap().status(),
            StatusCode::PAYLOAD_TOO_LARGE
        );
    }

    #[tokio::test]
    async fn security_headers_are_present_on_rejected_responses() {
        let response = router()
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "evil.example")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert!(response.headers().contains_key("content-security-policy"));
        assert_eq!(response.headers().get("cache-control").unwrap(), "no-store");
    }

    #[tokio::test]
    async fn embedded_flutter_shell_is_served_with_safe_headers() {
        let response = router()
            .oneshot(
                Request::get("/")
                    .header(header::HOST, "127.0.0.1:3210")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get(header::CONTENT_TYPE).unwrap(),
            "text/html; charset=utf-8"
        );
        assert!(response.headers().contains_key("content-security-policy"));
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&body).contains("PlushPal"));
    }

    #[tokio::test]
    async fn missing_or_traversing_static_assets_are_rejected() {
        let app = router();
        let missing = Request::get("/missing.js")
            .header(header::HOST, "127.0.0.1:3210")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.clone().oneshot(missing).await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
        let traversal = Request::get("/assets/%2e%2e/secret")
            .header(header::HOST, "127.0.0.1:3210")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            app.oneshot(traversal).await.unwrap().status(),
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    async fn authenticated_versioned_commands_are_accepted_and_validated() {
        let app = router();
        let cookie = authenticated_cookie(&app).await;
        let valid = Request::post("/api/v1/commands")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::COOKIE, &cookie)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                r#"{"schema_version":1,"request_id":"request-1","command":"begin_local_turn","payload":{"age_band":"6-8","character_alias":"Teddy","text":"Why is the sky blue?"}}"#,
            ))
            .unwrap();
        let response = app.clone().oneshot(valid).await.unwrap();
        assert_eq!(response.status(), StatusCode::ACCEPTED);
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&body).contains("command_accepted"));

        let invalid = Request::post("/api/v1/commands")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::COOKIE, cookie)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                r#"{"schema_version":1,"request_id":"request-2","command":"read_arbitrary_file"}"#,
            ))
            .unwrap();
        assert_eq!(
            app.oneshot(invalid).await.unwrap().status(),
            StatusCode::BAD_REQUEST
        );
    }

    #[tokio::test]
    async fn signed_model_install_command_activates_ready_engine() {
        let installed = Arc::new(AtomicBool::new(false));
        let app = router_with_installer(Arc::clone(&installed));
        let cookie = authenticated_cookie(&app).await;
        let install = Request::post("/api/v1/commands")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::COOKIE, &cookie)
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(
                r#"{"schema_version":1,"request_id":"install-1","command":"install_local_model"}"#,
            ))
            .unwrap();
        assert_eq!(
            app.clone().oneshot(install).await.unwrap().status(),
            StatusCode::ACCEPTED
        );
        for _ in 0..100 {
            if installed.load(Ordering::Acquire) {
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(installed.load(Ordering::Acquire));
        let response = app
            .oneshot(
                Request::get("/api/v1/status")
                    .header(header::HOST, "127.0.0.1:3210")
                    .header(header::COOKIE, cookie)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert!(String::from_utf8_lossy(&body).contains(r#""model_ready":true"#));
    }

    #[tokio::test]
    async fn websocket_upgrade_requires_an_authenticated_session() {
        let request = Request::get("/api/v1/events")
            .header(header::HOST, "127.0.0.1:3210")
            .header(header::ORIGIN, "http://127.0.0.1:3210")
            .header(header::CONNECTION, "upgrade")
            .header(header::UPGRADE, "websocket")
            .header("sec-websocket-version", "13")
            .header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
            .body(Body::empty())
            .unwrap();
        assert_eq!(
            router().oneshot(request).await.unwrap().status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[test]
    fn local_turn_payload_is_bounded_and_age_typed() {
        let parsed = parse_local_turn(LocalTurnPayload {
            age_band: "6-8".to_owned(),
            character_alias: "Teddy".to_owned(),
            text: "Hello".to_owned(),
        })
        .unwrap();
        assert_eq!(parsed.age_band, AgeBand::SixToEight);
        assert!(parse_local_turn(LocalTurnPayload {
            age_band: "unknown".to_owned(),
            character_alias: "Teddy".to_owned(),
            text: "Hello".to_owned(),
        })
        .is_err());
        assert!(parse_local_turn(LocalTurnPayload {
            age_band: "6-8".to_owned(),
            character_alias: "Teddy".to_owned(),
            text: "x".repeat(601),
        })
        .is_err());
    }
}
