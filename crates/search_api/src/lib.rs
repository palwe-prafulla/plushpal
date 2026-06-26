#![forbid(unsafe_code)]

use std::{future::Future, pin::Pin, time::Duration};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SanitizedSearchQuery {
    pub text: String,
    pub maximum_results: u8,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EvidenceRecord {
    pub source_id: String,
    pub source_url: String,
    pub title: String,
    pub excerpt: String,
    pub untrusted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SearchError {
    QueryRejected,
    NetworkUnavailable,
    PrivateAddressBlocked,
    UnsupportedContent,
    Timeout,
    Cancelled,
    InsufficientEvidence,
    Internal,
}

pub type SearchFuture<'a> =
    Pin<Box<dyn Future<Output = Result<Vec<EvidenceRecord>, SearchError>> + Send + 'a>>;

pub trait SearchProvider: Send + Sync {
    fn search(&self, query: SanitizedSearchQuery, deadline: Duration) -> SearchFuture<'_>;
}
