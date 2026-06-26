#![forbid(unsafe_code)]

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgeBand {
    FourToFive,
    SixToEight,
    NineToTwelve,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConversationMode {
    Local,
    SearchAssisted,
    ExperimentalCloud,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ConversationTurn {
    pub role: TurnRole,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TurnRole {
    Child,
    Character,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoundedConversationRequest {
    pub policy_version: String,
    pub age_band: AgeBand,
    pub mode: ConversationMode,
    pub character_alias: String,
    pub parent_guidance: Option<String>,
    pub recent_turns: Vec<ConversationTurn>,
    pub current_text: String,
    pub max_response_characters: usize,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct StructuredCharacterResponse {
    pub speech: String,
    pub suggest_trusted_adult: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PolicyViolation {
    EmptyInput,
    InputTooLong,
    OutputTooLong,
    ExternalModeNotAllowed,
    SearchNotAllowed,
    UnsafeContent,
    UnsafeParentGuidance,
}
