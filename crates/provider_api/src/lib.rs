#![forbid(unsafe_code)]

use std::{future::Future, pin::Pin, sync::Arc, time::Duration};

use plushpal_core_domain::{BoundedConversationRequest, StructuredCharacterResponse};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationCapabilities {
    pub provider_id: String,
    pub local: bool,
    pub supports_structured_output: bool,
    pub maximum_context_characters: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ProviderError {
    NotReady,
    ModelUnavailable,
    IncompatibleDevice,
    MemoryPressure,
    Authentication,
    EligibilityDenied,
    NetworkUnavailable,
    Timeout,
    Cancelled,
    MalformedResponse,
    Internal,
}

pub type ProviderFuture<'a> =
    Pin<Box<dyn Future<Output = Result<StructuredCharacterResponse, ProviderError>> + Send + 'a>>;

pub trait ConversationProvider: Send + Sync {
    fn capabilities(&self) -> ConversationCapabilities;

    fn generate(
        &self,
        request: BoundedConversationRequest,
        deadline: Duration,
    ) -> ProviderFuture<'_>;
}

impl<T: ConversationProvider + ?Sized> ConversationProvider for Arc<T> {
    fn capabilities(&self) -> ConversationCapabilities {
        (**self).capabilities()
    }

    fn generate(
        &self,
        request: BoundedConversationRequest,
        deadline: Duration,
    ) -> ProviderFuture<'_> {
        (**self).generate(request, deadline)
    }
}
