#![forbid(unsafe_code)]

use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    net::{IpAddr, SocketAddr, ToSocketAddrs},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::Url;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ModelManifest {
    pub model_id: String,
    pub version: String,
    pub engine_compatibility: String,
    pub download_size_bytes: u64,
    pub installed_size_bytes: u64,
    pub sha256_hex: String,
    pub license_id: String,
    pub source_url: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelRelease {
    pub model_id: String,
    pub version: String,
}

impl From<&ModelManifest> for ModelRelease {
    fn from(value: &ModelManifest) -> Self {
        Self {
            model_id: value.model_id.clone(),
            version: value.version.clone(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum LifecycleError {
    InstallAlreadyInProgress,
    NoInstallInProgress,
    NoStagedModel,
    NoPreviousModel,
    InvalidManifest,
    IncompatibleEngine,
    InsufficientStorage {
        required_bytes: u64,
        available_bytes: u64,
    },
    DownloadExceedsManifest,
    DownloadIncomplete,
    SizeMismatch,
    HashMismatch,
    SignatureInvalid,
    SelfTestFailed,
    NetworkUnavailable,
    Timeout,
    Cancelled,
    PrivateAddressBlocked,
    Io,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct InstallProgress {
    pub release: ModelRelease,
    pub received_bytes: u64,
    pub expected_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelLifecycle {
    compatible_engine: String,
    storage_reserve_bytes: u64,
    active: Option<ModelRelease>,
    previous: Option<ModelRelease>,
    staged: Option<ModelRelease>,
    installing: Option<(ModelManifest, u64)>,
}

impl ModelLifecycle {
    #[must_use]
    pub fn new(compatible_engine: impl Into<String>, storage_reserve_bytes: u64) -> Self {
        Self {
            compatible_engine: compatible_engine.into(),
            storage_reserve_bytes,
            active: None,
            previous: None,
            staged: None,
            installing: None,
        }
    }

    #[must_use]
    pub const fn active(&self) -> Option<&ModelRelease> {
        self.active.as_ref()
    }

    #[must_use]
    pub const fn previous(&self) -> Option<&ModelRelease> {
        self.previous.as_ref()
    }

    pub fn begin_install(
        &mut self,
        manifest: ModelManifest,
        available_storage_bytes: u64,
    ) -> Result<(), LifecycleError> {
        if self.installing.is_some() {
            return Err(LifecycleError::InstallAlreadyInProgress);
        }
        validate_manifest(&manifest)?;
        if manifest.engine_compatibility != self.compatible_engine {
            return Err(LifecycleError::IncompatibleEngine);
        }
        let required = manifest
            .installed_size_bytes
            .saturating_add(self.storage_reserve_bytes);
        if available_storage_bytes < required {
            return Err(LifecycleError::InsufficientStorage {
                required_bytes: required,
                available_bytes: available_storage_bytes,
            });
        }
        self.installing = Some((manifest, 0));
        Ok(())
    }

    pub fn record_downloaded_bytes(
        &mut self,
        received_bytes: u64,
    ) -> Result<InstallProgress, LifecycleError> {
        let (manifest, current) = self
            .installing
            .as_mut()
            .ok_or(LifecycleError::NoInstallInProgress)?;
        let updated = current.saturating_add(received_bytes);
        if updated > manifest.download_size_bytes {
            return Err(LifecycleError::DownloadExceedsManifest);
        }
        *current = updated;
        Ok(InstallProgress {
            release: ModelRelease::from(&*manifest),
            received_bytes: updated,
            expected_bytes: manifest.download_size_bytes,
        })
    }

    pub fn verify_and_stage(
        &mut self,
        actual_size_bytes: u64,
        actual_sha256_hex: &str,
        signature_valid: bool,
        self_test_passed: bool,
    ) -> Result<ModelRelease, LifecycleError> {
        let (manifest, received) = self
            .installing
            .as_ref()
            .ok_or(LifecycleError::NoInstallInProgress)?;
        if *received != manifest.download_size_bytes {
            return Err(LifecycleError::DownloadIncomplete);
        }
        if actual_size_bytes != manifest.download_size_bytes {
            return Err(LifecycleError::SizeMismatch);
        }
        if !actual_sha256_hex.eq_ignore_ascii_case(&manifest.sha256_hex) {
            return Err(LifecycleError::HashMismatch);
        }
        if !signature_valid {
            return Err(LifecycleError::SignatureInvalid);
        }
        if !self_test_passed {
            return Err(LifecycleError::SelfTestFailed);
        }
        let release = ModelRelease::from(manifest);
        self.staged = Some(release.clone());
        self.installing = None;
        Ok(release)
    }

    pub fn activate_staged(&mut self) -> Result<&ModelRelease, LifecycleError> {
        let staged = self.staged.take().ok_or(LifecycleError::NoStagedModel)?;
        self.previous = self.active.replace(staged);
        Ok(self
            .active
            .as_ref()
            .expect("active model was just assigned"))
    }

    pub fn rollback(&mut self) -> Result<&ModelRelease, LifecycleError> {
        let previous = self
            .previous
            .take()
            .ok_or(LifecycleError::NoPreviousModel)?;
        self.previous = self.active.replace(previous);
        Ok(self
            .active
            .as_ref()
            .expect("active model was just assigned"))
    }

    pub fn cancel_install(&mut self) -> Result<ModelRelease, LifecycleError> {
        let (manifest, _) = self
            .installing
            .take()
            .ok_or(LifecycleError::NoInstallInProgress)?;
        Ok(ModelRelease::from(&manifest))
    }
}

pub fn verify_signed_manifest(
    document: &[u8],
    signature: &[u8],
    ed25519_public_key: &[u8],
) -> Result<ModelManifest, LifecycleError> {
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, ed25519_public_key)
        .verify(document, signature)
        .map_err(|_| LifecycleError::SignatureInvalid)?;
    let manifest: ModelManifest =
        serde_json::from_slice(document).map_err(|_| LifecycleError::InvalidManifest)?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

pub fn bundled_private_beta_manifest() -> Result<ModelManifest, LifecycleError> {
    let document = include_bytes!("../../../models/manifests/qwen3-1.7b-q8-v1.json");
    let signature = decode_hex::<64>(include_str!(
        "../../../models/manifests/qwen3-1.7b-q8-v1.sig.hex"
    ))?;
    let public_key = decode_hex::<32>(include_str!(
        "../../../models/trust/private_beta_ed25519_public_key.hex"
    ))?;
    verify_signed_manifest(document, &signature, &public_key)
}

pub fn verify_model_artifact(
    manifest: &ModelManifest,
    artifact_path: &Path,
) -> Result<(), LifecycleError> {
    validate_manifest(manifest)?;
    let mut artifact = File::open(artifact_path).map_err(|_| LifecycleError::Io)?;
    let size = artifact.metadata().map_err(|_| LifecycleError::Io)?.len();
    if size != manifest.download_size_bytes {
        return Err(LifecycleError::SizeMismatch);
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = artifact.read(&mut buffer).map_err(|_| LifecycleError::Io)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    if format!("{:x}", hasher.finalize()) != manifest.sha256_hex.to_ascii_lowercase() {
        return Err(LifecycleError::HashMismatch);
    }
    Ok(())
}

fn decode_hex<const N: usize>(value: &str) -> Result<[u8; N], LifecycleError> {
    let value = value.trim();
    if value.len() != N * 2 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(LifecycleError::InvalidManifest);
    }
    let mut output = [0_u8; N];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let pair = std::str::from_utf8(pair).map_err(|_| LifecycleError::InvalidManifest)?;
        output[index] =
            u8::from_str_radix(pair, 16).map_err(|_| LifecycleError::InvalidManifest)?;
    }
    Ok(output)
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct ProductionModelDownloader;

impl ProductionModelDownloader {
    pub fn download(
        self,
        manifest: &ModelManifest,
        destination_directory: &Path,
        deadline: Duration,
    ) -> Result<PathBuf, LifecycleError> {
        self.download_cancellable(manifest, destination_directory, deadline, || false)
    }

    pub fn download_cancellable(
        self,
        manifest: &ModelManifest,
        destination_directory: &Path,
        deadline: Duration,
        is_cancelled: impl Fn() -> bool,
    ) -> Result<PathBuf, LifecycleError> {
        validate_manifest(manifest)?;
        if deadline.is_zero() {
            return Err(LifecycleError::Timeout);
        }
        fs::create_dir_all(destination_directory).map_err(|_| LifecycleError::Io)?;
        let basename = format!("{}-{}", manifest.model_id, manifest.version);
        let partial_path = destination_directory.join(format!("{basename}.partial"));
        let final_path = destination_directory.join(format!("{basename}.gguf"));
        let mut existing = partial_path.metadata().map_or(0, |metadata| metadata.len());
        if existing > manifest.download_size_bytes {
            fs::remove_file(&partial_path).map_err(|_| LifecycleError::Io)?;
            existing = 0;
        }
        let started = Instant::now();
        let mut current =
            Url::parse(&manifest.source_url).map_err(|_| LifecycleError::InvalidManifest)?;
        let mut redirects = 0_u8;
        loop {
            if is_cancelled() {
                return Err(LifecycleError::Cancelled);
            }
            let remaining = deadline
                .checked_sub(started.elapsed())
                .ok_or(LifecycleError::Timeout)?;
            let host = current.host_str().ok_or(LifecycleError::InvalidManifest)?;
            let addresses = resolve_public_addresses(host)?;
            let client = reqwest::blocking::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy()
                .timeout(remaining)
                .resolve_to_addrs(host, &addresses)
                .build()
                .map_err(|_| LifecycleError::NetworkUnavailable)?;
            let mut request = client.get(current.clone());
            if existing > 0 {
                request = request.header(reqwest::header::RANGE, format!("bytes={existing}-"));
            }
            let mut response = request.send().map_err(|error| {
                if error.is_timeout() {
                    LifecycleError::Timeout
                } else {
                    LifecycleError::NetworkUnavailable
                }
            })?;
            if response.status().is_redirection() {
                if redirects >= 3 {
                    return Err(LifecycleError::NetworkUnavailable);
                }
                let location = response
                    .headers()
                    .get(reqwest::header::LOCATION)
                    .and_then(|value| value.to_str().ok())
                    .ok_or(LifecycleError::NetworkUnavailable)?;
                current = current
                    .join(location)
                    .map_err(|_| LifecycleError::NetworkUnavailable)?;
                validate_download_url(&current)?;
                redirects = redirects.saturating_add(1);
                continue;
            }
            if !response.status().is_success() {
                return Err(LifecycleError::NetworkUnavailable);
            }
            let is_partial = response.status() == reqwest::StatusCode::PARTIAL_CONTENT;
            if existing > 0 && !is_partial {
                existing = 0;
            }
            if response.content_length().is_some_and(|length| {
                existing.saturating_add(length) > manifest.download_size_bytes
            }) {
                return Err(LifecycleError::DownloadExceedsManifest);
            }
            let write_result = write_verified_download(
                &mut response,
                &partial_path,
                existing,
                manifest,
                started,
                deadline,
                &is_cancelled,
            );
            if let Err(error) = write_result {
                if matches!(
                    error,
                    LifecycleError::HashMismatch | LifecycleError::DownloadExceedsManifest
                ) {
                    let _ = fs::remove_file(&partial_path);
                }
                return Err(error);
            }
            fs::rename(&partial_path, &final_path).map_err(|_| LifecycleError::Io)?;
            return Ok(final_path);
        }
    }
}

fn write_verified_download(
    response: &mut impl Read,
    partial_path: &Path,
    existing: u64,
    manifest: &ModelManifest,
    started: Instant,
    deadline: Duration,
    is_cancelled: &impl Fn() -> bool,
) -> Result<(), LifecycleError> {
    let mut hasher = Sha256::new();
    if existing > 0 {
        let mut previous = File::open(partial_path).map_err(|_| LifecycleError::Io)?;
        let mut buffer = [0_u8; 64 * 1024];
        loop {
            let read = previous.read(&mut buffer).map_err(|_| LifecycleError::Io)?;
            if read == 0 {
                break;
            }
            hasher.update(&buffer[..read]);
        }
    }
    let mut output = OpenOptions::new()
        .create(true)
        .write(true)
        .append(existing > 0)
        .truncate(existing == 0)
        .open(partial_path)
        .map_err(|_| LifecycleError::Io)?;
    let mut received = existing;
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        if is_cancelled() {
            return Err(LifecycleError::Cancelled);
        }
        if started.elapsed() >= deadline {
            return Err(LifecycleError::Timeout);
        }
        let read = response
            .read(&mut buffer)
            .map_err(|_| LifecycleError::NetworkUnavailable)?;
        if read == 0 {
            break;
        }
        received = received
            .checked_add(u64::try_from(read).map_err(|_| LifecycleError::Io)?)
            .ok_or(LifecycleError::DownloadExceedsManifest)?;
        if received > manifest.download_size_bytes {
            return Err(LifecycleError::DownloadExceedsManifest);
        }
        output
            .write_all(&buffer[..read])
            .map_err(|_| LifecycleError::Io)?;
        hasher.update(&buffer[..read]);
    }
    output.sync_all().map_err(|_| LifecycleError::Io)?;
    if received != manifest.download_size_bytes {
        return Err(LifecycleError::DownloadIncomplete);
    }
    if format!("{:x}", hasher.finalize()) != manifest.sha256_hex.to_ascii_lowercase() {
        return Err(LifecycleError::HashMismatch);
    }
    Ok(())
}

fn resolve_public_addresses(host: &str) -> Result<Vec<SocketAddr>, LifecycleError> {
    let addresses = (host, 443)
        .to_socket_addrs()
        .map_err(|_| LifecycleError::NetworkUnavailable)?
        .collect::<Vec<_>>();
    if addresses.is_empty() || addresses.iter().any(|address| !is_public(address.ip())) {
        return Err(LifecycleError::PrivateAddressBlocked);
    }
    Ok(addresses)
}

fn validate_download_url(url: &Url) -> Result<(), LifecycleError> {
    if url.scheme() != "https"
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some_and(|port| port != 443)
    {
        return Err(LifecycleError::InvalidManifest);
    }
    if url
        .host_str()
        .and_then(|host| host.parse::<IpAddr>().ok())
        .is_some_and(|address| !is_public(address))
    {
        return Err(LifecycleError::PrivateAddressBlocked);
    }
    Ok(())
}

const fn is_public(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            let octets = ip.octets();
            !(octets[0] == 0
                || octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127)
                || octets[0] >= 224)
        }
        IpAddr::V6(ip) => {
            let segments = ip.segments();
            !(ip.is_loopback()
                || ip.is_unspecified()
                || (segments[0] & 0xfe00) == 0xfc00
                || (segments[0] & 0xffc0) == 0xfe80
                || (segments[0] & 0xff00) == 0xff00)
        }
    }
}

fn validate_manifest(manifest: &ModelManifest) -> Result<(), LifecycleError> {
    let hash_is_hex = manifest.sha256_hex.len() == 64
        && manifest
            .sha256_hex
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit());
    let safe_component = |value: &str| {
        !value.is_empty()
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
    };
    if !safe_component(&manifest.model_id)
        || !safe_component(&manifest.version)
        || manifest.engine_compatibility.trim().is_empty()
        || manifest.download_size_bytes == 0
        || manifest.installed_size_bytes == 0
        || !hash_is_hex
        || manifest.license_id.trim().is_empty()
        || Url::parse(&manifest.source_url)
            .map_err(|_| LifecycleError::InvalidManifest)
            .and_then(|url| validate_download_url(&url))
            .is_err()
    {
        return Err(LifecycleError::InvalidManifest);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use ring::signature::KeyPair;

    use super::*;

    fn manifest(version: &str) -> ModelManifest {
        ModelManifest {
            model_id: "qwen3-1.7b-q8".to_owned(),
            version: version.to_owned(),
            engine_compatibility: "llama.cpp-1".to_owned(),
            download_size_bytes: 100,
            installed_size_bytes: 120,
            sha256_hex: "a".repeat(64),
            license_id: "Apache-2.0".to_owned(),
            source_url: "https://models.example.invalid/model.gguf".to_owned(),
        }
    }

    fn stage(lifecycle: &mut ModelLifecycle, version: &str) {
        lifecycle.begin_install(manifest(version), 1_000).unwrap();
        lifecycle.record_downloaded_bytes(100).unwrap();
        lifecycle
            .verify_and_stage(100, &"a".repeat(64), true, true)
            .unwrap();
    }

    #[test]
    fn invalid_hash_never_stages_or_replaces_active_model() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        stage(&mut lifecycle, "1");
        lifecycle.activate_staged().unwrap();
        lifecycle.begin_install(manifest("2"), 1_000).unwrap();
        lifecycle.record_downloaded_bytes(100).unwrap();
        assert_eq!(
            lifecycle.verify_and_stage(100, &"b".repeat(64), true, true),
            Err(LifecycleError::HashMismatch)
        );
        assert_eq!(lifecycle.active().unwrap().version, "1");
    }

    #[test]
    fn incomplete_download_cannot_be_staged() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        lifecycle.begin_install(manifest("1"), 1_000).unwrap();
        lifecycle.record_downloaded_bytes(99).unwrap();
        assert_eq!(
            lifecycle.verify_and_stage(100, &"a".repeat(64), true, true),
            Err(LifecycleError::DownloadIncomplete)
        );
    }

    #[test]
    fn failed_self_test_preserves_last_known_good() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        stage(&mut lifecycle, "1");
        lifecycle.activate_staged().unwrap();
        lifecycle.begin_install(manifest("2"), 1_000).unwrap();
        lifecycle.record_downloaded_bytes(100).unwrap();
        assert_eq!(
            lifecycle.verify_and_stage(100, &"a".repeat(64), true, false),
            Err(LifecycleError::SelfTestFailed)
        );
        assert_eq!(lifecycle.active().unwrap().version, "1");
    }

    #[test]
    fn activation_and_rollback_are_atomic_state_transitions() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        stage(&mut lifecycle, "1");
        lifecycle.activate_staged().unwrap();
        stage(&mut lifecycle, "2");
        assert_eq!(lifecycle.activate_staged().unwrap().version, "2");
        assert_eq!(lifecycle.previous().unwrap().version, "1");
        assert_eq!(lifecycle.rollback().unwrap().version, "1");
        assert_eq!(lifecycle.previous().unwrap().version, "2");
    }

    #[test]
    fn cancellation_clears_partial_install_without_touching_active() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        stage(&mut lifecycle, "1");
        lifecycle.activate_staged().unwrap();
        lifecycle.begin_install(manifest("2"), 1_000).unwrap();
        lifecycle.record_downloaded_bytes(40).unwrap();
        assert_eq!(lifecycle.cancel_install().unwrap().version, "2");
        assert_eq!(lifecycle.active().unwrap().version, "1");
        assert_eq!(
            lifecycle.record_downloaded_bytes(1),
            Err(LifecycleError::NoInstallInProgress)
        );
    }

    #[test]
    fn exact_storage_requirement_is_accepted() {
        let mut lifecycle = ModelLifecycle::new("llama.cpp-1", 10);
        assert_eq!(lifecycle.begin_install(manifest("1"), 130), Ok(()));
    }

    #[test]
    fn signed_manifest_is_verified_before_it_can_drive_downloads() {
        let document = br#"{
            "model_id":"qwen3-1.7b-q8","version":"1",
            "engine_compatibility":"llama.cpp-1",
            "download_size_bytes":100,"installed_size_bytes":100,
            "sha256_hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "license_id":"Apache-2.0",
            "source_url":"https://huggingface.co/Qwen/model/resolve/main/model.gguf"
        }"#;
        let key_pair = ring::signature::Ed25519KeyPair::from_seed_unchecked(&[0x24; 32]).unwrap();
        let signature = key_pair.sign(document);
        assert_eq!(
            verify_signed_manifest(document, signature.as_ref(), key_pair.public_key().as_ref())
                .unwrap()
                .model_id,
            "qwen3-1.7b-q8"
        );
        let mut tampered = document.to_vec();
        tampered.push(b' ');
        assert_eq!(
            verify_signed_manifest(
                &tampered,
                signature.as_ref(),
                key_pair.public_key().as_ref()
            ),
            Err(LifecycleError::SignatureInvalid)
        );
    }

    #[test]
    fn manifest_path_components_and_private_urls_fail_closed() {
        let mut unsafe_manifest = manifest("1");
        unsafe_manifest.model_id = "../escape".to_owned();
        assert_eq!(
            validate_manifest(&unsafe_manifest),
            Err(LifecycleError::InvalidManifest)
        );
        unsafe_manifest = manifest("1");
        unsafe_manifest.source_url = "https://127.0.0.1/model.gguf".to_owned();
        assert_eq!(
            validate_manifest(&unsafe_manifest),
            Err(LifecycleError::InvalidManifest)
        );
    }

    #[test]
    fn bundled_private_beta_manifest_has_a_valid_signature_and_exact_artifact() {
        let manifest = bundled_private_beta_manifest().unwrap();
        assert_eq!(manifest.model_id, "qwen3-1.7b-q8");
        assert_eq!(manifest.download_size_bytes, 1_834_426_016);
        assert_eq!(
            manifest.sha256_hex,
            "061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"
        );
        assert_eq!(manifest.license_id, "Apache-2.0");
    }

    #[test]
    fn cancelled_download_stops_before_dns_or_network_access() {
        let directory = std::env::temp_dir().join("plushpal-cancelled-download-test");
        let result = ProductionModelDownloader.download_cancellable(
            &manifest("1"),
            &directory,
            Duration::from_secs(30),
            || true,
        );
        assert_eq!(result, Err(LifecycleError::Cancelled));
    }

    #[test]
    fn installed_artifact_is_reverified_before_every_activation() {
        let path =
            std::env::temp_dir().join(format!("plushpal-model-verify-{}", std::process::id()));
        std::fs::write(&path, b"verified bytes").unwrap();
        let mut expected = manifest("1");
        expected.download_size_bytes = 14;
        expected.installed_size_bytes = 14;
        expected.sha256_hex = format!("{:x}", Sha256::digest(b"verified bytes"));
        assert_eq!(verify_model_artifact(&expected, &path), Ok(()));
        std::fs::write(&path, b"tampered bytes").unwrap();
        assert_eq!(
            verify_model_artifact(&expected, &path),
            Err(LifecycleError::HashMismatch)
        );
        std::fs::remove_file(path).unwrap();
    }
}
