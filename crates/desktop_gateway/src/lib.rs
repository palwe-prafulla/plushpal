#![forbid(unsafe_code)]

use std::{collections::HashSet, fmt, net::IpAddr};

use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

const MAX_REQUEST_BODY_BYTES: u64 = 1_048_576;
const MAX_VOICE_ENROLLMENT_BODY_BYTES: u64 = 32 * 1_048_576;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LoopbackEndpoint {
    pub port: u16,
}

impl LoopbackEndpoint {
    #[must_use]
    pub fn host_header(self, ipv6: bool) -> String {
        if ipv6 {
            format!("[::1]:{}", self.port)
        } else {
            format!("127.0.0.1:{}", self.port)
        }
    }

    #[must_use]
    pub fn origin(self, ipv6: bool) -> String {
        format!("http://{}", self.host_header(ipv6))
    }
}

pub fn validate_bind_address(address: IpAddr) -> Result<(), GatewayError> {
    if address.is_loopback() {
        Ok(())
    } else {
        Err(GatewayError::NonLoopbackBind)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GatewayError {
    NonLoopbackBind,
    InvalidHost,
    InvalidOrigin,
    MissingOrigin,
    OversizedBody,
    InvalidApiPath,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RequestKind {
    ReadOnly,
    Mutating,
    WebSocketUpgrade,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestMetadata<'a> {
    pub host: &'a str,
    pub origin: Option<&'a str>,
    pub path: &'a str,
    pub content_length: u64,
    pub kind: RequestKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GatewayPolicy {
    endpoint: LoopbackEndpoint,
    additional_host_headers: Vec<String>,
    additional_origins: Vec<String>,
}

impl GatewayPolicy {
    #[must_use]
    pub fn new(endpoint: LoopbackEndpoint) -> Self {
        Self {
            endpoint,
            additional_host_headers: Vec::new(),
            additional_origins: Vec::new(),
        }
    }

    #[must_use]
    pub fn with_additional_http_host(mut self, host_header: impl Into<String>) -> Self {
        let host_header = host_header.into();
        if !host_header.is_empty() {
            self.additional_origins
                .push(format!("http://{host_header}"));
            self.additional_host_headers.push(host_header);
        }
        self
    }

    pub fn validate_request(&self, request: &RequestMetadata<'_>) -> Result<(), GatewayError> {
        let valid_host = request.host == self.endpoint.host_header(false)
            || request.host == self.endpoint.host_header(true)
            || self
                .additional_host_headers
                .iter()
                .any(|allowed| request.host == allowed);
        if !valid_host {
            return Err(GatewayError::InvalidHost);
        }
        let maximum_body_bytes = if request.path == "/api/v1/voice/enroll" {
            MAX_VOICE_ENROLLMENT_BODY_BYTES
        } else {
            MAX_REQUEST_BODY_BYTES
        };
        if request.content_length > maximum_body_bytes {
            return Err(GatewayError::OversizedBody);
        }
        if request.path.starts_with("/api/") {
            validate_api_path(request.path)?;
        } else if request.kind == RequestKind::ReadOnly {
            validate_static_path(request.path)?;
        } else {
            return Err(GatewayError::InvalidApiPath);
        }
        if request.kind != RequestKind::ReadOnly {
            let origin = request.origin.ok_or(GatewayError::MissingOrigin)?;
            let valid_origin = origin == self.endpoint.origin(false)
                || origin == self.endpoint.origin(true)
                || self
                    .additional_origins
                    .iter()
                    .any(|allowed| origin == allowed);
            if !valid_origin {
                return Err(GatewayError::InvalidOrigin);
            }
        }
        Ok(())
    }
}

fn validate_static_path(path: &str) -> Result<(), GatewayError> {
    let lower = path.to_ascii_lowercase();
    let invalid_encoding = ["%00", "%2e", "%2f", "%5c"]
        .iter()
        .any(|sequence| lower.contains(sequence));
    if !path.starts_with('/')
        || path.contains("..")
        || path.contains('\\')
        || path.contains('\0')
        || invalid_encoding
    {
        return Err(GatewayError::InvalidApiPath);
    }
    Ok(())
}

fn validate_api_path(path: &str) -> Result<(), GatewayError> {
    let lower = path.to_ascii_lowercase();
    let invalid_encoding = ["%00", "%2e", "%2f", "%5c"]
        .iter()
        .any(|sequence| lower.contains(sequence));
    if !path.starts_with("/api/v1/")
        || path.contains("..")
        || path.contains('\\')
        || path.contains('\0')
        || invalid_encoding
    {
        return Err(GatewayError::InvalidApiPath);
    }
    Ok(())
}

#[derive(Clone, Eq, Hash, PartialEq)]
struct TokenDigest([u8; 32]);

impl fmt::Debug for TokenDigest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("TokenDigest([REDACTED])")
    }
}

impl TokenDigest {
    fn from_token(token: &[u8]) -> Self {
        Self(Sha256::digest(token).into())
    }

    fn matches(&self, token: &[u8]) -> bool {
        let candidate: [u8; 32] = Sha256::digest(token).into();
        bool::from(self.0.ct_eq(&candidate))
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthenticationError {
    InvalidToken,
    BootstrapAlreadyConsumed,
    RateLimited,
}

pub struct SessionSecurity {
    bootstrap: TokenDigest,
    bootstrap_consumed: bool,
    sessions: HashSet<TokenDigest>,
    failure_window_started_at: i64,
    failures_in_window: u16,
    maximum_failures: u16,
    failure_window_seconds: i64,
}

impl fmt::Debug for SessionSecurity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionSecurity")
            .field("bootstrap_consumed", &self.bootstrap_consumed)
            .field("session_count", &self.sessions.len())
            .field("failures_in_window", &self.failures_in_window)
            .finish()
    }
}

impl SessionSecurity {
    #[must_use]
    pub fn new(bootstrap_token: &[u8], maximum_failures: u16, failure_window_seconds: i64) -> Self {
        Self {
            bootstrap: TokenDigest::from_token(bootstrap_token),
            bootstrap_consumed: false,
            sessions: HashSet::new(),
            failure_window_started_at: 0,
            failures_in_window: 0,
            maximum_failures,
            failure_window_seconds,
        }
    }

    pub fn exchange_bootstrap(
        &mut self,
        presented_bootstrap: &[u8],
        new_session_token: &[u8],
        now: i64,
    ) -> Result<(), AuthenticationError> {
        self.roll_failure_window(now);
        if self.failures_in_window >= self.maximum_failures {
            return Err(AuthenticationError::RateLimited);
        }
        if !self.bootstrap.matches(presented_bootstrap) {
            self.failures_in_window = self.failures_in_window.saturating_add(1);
            return Err(AuthenticationError::InvalidToken);
        }
        self.bootstrap_consumed = true;
        self.sessions
            .insert(TokenDigest::from_token(new_session_token));
        Ok(())
    }

    #[must_use]
    pub fn validate_session(&self, session_token: &[u8]) -> bool {
        self.sessions
            .iter()
            .any(|digest| digest.matches(session_token))
    }

    pub fn revoke_session(&mut self, session_token: &[u8]) -> bool {
        let candidate = TokenDigest::from_token(session_token);
        self.sessions.remove(&candidate)
    }

    fn roll_failure_window(&mut self, now: i64) {
        if now.saturating_sub(self.failure_window_started_at) >= self.failure_window_seconds {
            self.failure_window_started_at = now;
            self.failures_in_window = 0;
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct IdleShutdown {
    timeout_seconds: i64,
    last_session_closed_at: Option<i64>,
}

impl IdleShutdown {
    #[must_use]
    pub const fn new(timeout_seconds: i64) -> Self {
        Self {
            timeout_seconds,
            last_session_closed_at: None,
        }
    }

    pub fn final_session_closed(&mut self, now: i64) {
        self.last_session_closed_at = Some(now);
    }

    pub fn session_opened(&mut self) {
        self.last_session_closed_at = None;
    }

    #[must_use]
    pub fn should_shutdown(self, now: i64) -> bool {
        self.last_session_closed_at
            .is_some_and(|closed| now.saturating_sub(closed) >= self.timeout_seconds)
    }
}

#[must_use]
pub fn security_headers() -> [(&'static str, &'static str); 6] {
    [
        (
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self' data:; connect-src 'self' https://generativelanguage.googleapis.com https://api.openai.com; img-src 'self' data:; media-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'",
        ),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Cross-Origin-Opener-Policy", "same-origin"),
        ("Cross-Origin-Resource-Policy", "same-origin"),
        ("Cache-Control", "no-store"),
    ]
}

#[cfg(test)]
mod tests {
    use std::net::{Ipv4Addr, Ipv6Addr};

    use super::*;

    #[test]
    fn binding_rejects_every_non_loopback_address() {
        assert_eq!(
            validate_bind_address(IpAddr::V4(Ipv4Addr::LOCALHOST)),
            Ok(())
        );
        assert_eq!(
            validate_bind_address(IpAddr::V6(Ipv6Addr::LOCALHOST)),
            Ok(())
        );
        assert_eq!(
            validate_bind_address(IpAddr::V4(Ipv4Addr::UNSPECIFIED)),
            Err(GatewayError::NonLoopbackBind)
        );
        assert_eq!(
            validate_bind_address("192.168.1.4".parse().unwrap()),
            Err(GatewayError::NonLoopbackBind)
        );
    }

    #[test]
    fn host_and_origin_must_be_exact_loopback_literals() {
        let policy = GatewayPolicy::new(LoopbackEndpoint { port: 3210 });
        let base = RequestMetadata {
            host: "127.0.0.1:3210",
            origin: Some("http://127.0.0.1:3210"),
            path: "/api/v1/status",
            content_length: 0,
            kind: RequestKind::Mutating,
        };
        assert_eq!(policy.validate_request(&base), Ok(()));
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                host: "localhost:3210",
                ..base.clone()
            }),
            Err(GatewayError::InvalidHost)
        );
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                origin: Some("https://evil.example"),
                ..base
            }),
            Err(GatewayError::InvalidOrigin)
        );
    }

    #[test]
    fn explicit_lan_host_allows_matching_host_and_origin_only() {
        let policy = GatewayPolicy::new(LoopbackEndpoint { port: 3210 })
            .with_additional_http_host("192.168.1.50:3210");
        let base = RequestMetadata {
            host: "192.168.1.50:3210",
            origin: Some("http://192.168.1.50:3210"),
            path: "/api/v1/status",
            content_length: 0,
            kind: RequestKind::Mutating,
        };
        assert_eq!(policy.validate_request(&base), Ok(()));
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                host: "192.168.1.51:3210",
                ..base.clone()
            }),
            Err(GatewayError::InvalidHost)
        );
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                origin: Some("http://192.168.1.51:3210"),
                ..base
            }),
            Err(GatewayError::InvalidOrigin)
        );
    }

    #[test]
    fn websocket_requires_same_origin() {
        let policy = GatewayPolicy::new(LoopbackEndpoint { port: 3210 });
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                host: "127.0.0.1:3210",
                origin: None,
                path: "/api/v1/events",
                content_length: 0,
                kind: RequestKind::WebSocketUpgrade,
            }),
            Err(GatewayError::MissingOrigin)
        );
    }

    #[test]
    fn oversized_and_traversal_requests_are_rejected() {
        let policy = GatewayPolicy::new(LoopbackEndpoint { port: 3210 });
        let request = |path, content_length| RequestMetadata {
            host: "127.0.0.1:3210",
            origin: None,
            path,
            content_length,
            kind: RequestKind::ReadOnly,
        };
        assert_eq!(
            policy.validate_request(&request("/api/v1/status", MAX_REQUEST_BODY_BYTES + 1)),
            Err(GatewayError::OversizedBody)
        );
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                host: "127.0.0.1:3210",
                origin: Some("http://127.0.0.1:3210"),
                path: "/api/v1/voice/enroll",
                content_length: MAX_REQUEST_BODY_BYTES + 1,
                kind: RequestKind::Mutating,
            }),
            Ok(())
        );
        assert_eq!(
            policy.validate_request(&RequestMetadata {
                host: "127.0.0.1:3210",
                origin: Some("http://127.0.0.1:3210"),
                path: "/api/v1/voice/enroll",
                content_length: MAX_VOICE_ENROLLMENT_BODY_BYTES + 1,
                kind: RequestKind::Mutating,
            }),
            Err(GatewayError::OversizedBody)
        );
        for path in [
            "/api/v1/../secret",
            "/api/v1/%2e%2e/secret",
            "/assets/../secret",
            "/assets/%2e%2e/secret",
        ] {
            assert_eq!(
                policy.validate_request(&request(path, 0)),
                Err(GatewayError::InvalidApiPath)
            );
        }
        assert_eq!(policy.validate_request(&request("/other", 0)), Ok(()));
    }

    #[test]
    fn bootstrap_can_issue_replacement_sessions_and_sessions_can_be_revoked() {
        let mut security = SessionSecurity::new(b"bootstrap", 3, 60);
        security
            .exchange_bootstrap(b"bootstrap", b"session", 1)
            .unwrap();
        assert!(security.validate_session(b"session"));
        security
            .exchange_bootstrap(b"bootstrap", b"other", 2)
            .unwrap();
        assert!(security.validate_session(b"other"));
        assert!(security.revoke_session(b"session"));
        assert!(!security.validate_session(b"session"));
        assert!(security.validate_session(b"other"));
    }

    #[test]
    fn repeated_authentication_failures_are_rate_limited_then_reset() {
        let mut security = SessionSecurity::new(b"bootstrap", 2, 60);
        assert_eq!(
            security.exchange_bootstrap(b"wrong", b"session", 1),
            Err(AuthenticationError::InvalidToken)
        );
        assert_eq!(
            security.exchange_bootstrap(b"wrong", b"session", 2),
            Err(AuthenticationError::InvalidToken)
        );
        assert_eq!(
            security.exchange_bootstrap(b"bootstrap", b"session", 3),
            Err(AuthenticationError::RateLimited)
        );
        assert_eq!(
            security.exchange_bootstrap(b"bootstrap", b"session", 61),
            Ok(())
        );
    }

    #[test]
    fn debug_and_headers_do_not_leak_or_weaken_secrets() {
        let security = SessionSecurity::new(b"do-not-print", 3, 60);
        assert!(!format!("{security:?}").contains("do-not-print"));
        let headers = security_headers();
        let csp = headers
            .iter()
            .find(|(name, _)| *name == "Content-Security-Policy")
            .unwrap()
            .1;
        assert!(csp.contains("script-src 'self' 'wasm-unsafe-eval'"));
        assert!(!csp.contains("script-src 'self' 'unsafe-eval'"));
        assert!(!csp.contains("http:"));
        assert!(csp.contains("https://generativelanguage.googleapis.com"));
        assert!(csp.contains("https://api.openai.com"));
        assert!(!csp.contains("https://*"));
        assert!(csp.contains("object-src 'none'"));
        assert!(csp.contains("base-uri 'self'"));
        assert!(!csp.contains("base-uri 'none'"));
    }

    #[test]
    fn idle_shutdown_starts_only_after_final_session_closes() {
        let mut idle = IdleShutdown::new(30);
        assert!(!idle.should_shutdown(100));
        idle.final_session_closed(100);
        assert!(!idle.should_shutdown(129));
        assert!(idle.should_shutdown(130));
        idle.session_opened();
        assert!(!idle.should_shutdown(1_000));
    }
}
