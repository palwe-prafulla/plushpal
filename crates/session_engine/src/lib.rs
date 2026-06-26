#![forbid(unsafe_code)]

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionState {
    Idle,
    Capturing,
    Transcribing,
    ScreeningInput,
    Generating,
    ScreeningOutput,
    Synthesizing,
    Playing,
    Cancelled,
    Failed,
}

impl SessionState {
    #[must_use]
    pub const fn is_active(self) -> bool {
        matches!(
            self,
            Self::Capturing
                | Self::Transcribing
                | Self::ScreeningInput
                | Self::Generating
                | Self::ScreeningOutput
                | Self::Synthesizing
                | Self::Playing
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionEvent {
    BeginCapture,
    AudioCaptured,
    TranscriptReady,
    InputApproved,
    GenerationReady,
    OutputApproved,
    SynthesisReady,
    PlaybackFinished,
    Cancel,
    Fail,
    Reset,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TransitionError {
    InvalidTransition {
        state: SessionState,
        event: SessionEvent,
    },
    StaleJob {
        expected: u64,
        actual: u64,
    },
    JobAlreadyActive,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StateChange {
    pub job_id: u64,
    pub sequence: u64,
    pub from: SessionState,
    pub to: SessionState,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionMachine {
    state: SessionState,
    current_job_id: u64,
    next_job_id: u64,
    sequence: u64,
}

impl Default for SessionMachine {
    fn default() -> Self {
        Self {
            state: SessionState::Idle,
            current_job_id: 0,
            next_job_id: 1,
            sequence: 0,
        }
    }
}

impl SessionMachine {
    #[must_use]
    pub const fn state(&self) -> SessionState {
        self.state
    }

    pub fn begin_turn(&mut self) -> Result<StateChange, TransitionError> {
        if self.state.is_active() {
            return Err(TransitionError::JobAlreadyActive);
        }
        if self.state != SessionState::Idle {
            return Err(TransitionError::InvalidTransition {
                state: self.state,
                event: SessionEvent::BeginCapture,
            });
        }
        self.current_job_id = self.next_job_id;
        self.next_job_id = self.next_job_id.saturating_add(1);
        Ok(self.apply_transition(SessionState::Capturing))
    }

    pub fn apply(
        &mut self,
        job_id: u64,
        event: SessionEvent,
    ) -> Result<StateChange, TransitionError> {
        if job_id != self.current_job_id {
            return Err(TransitionError::StaleJob {
                expected: self.current_job_id,
                actual: job_id,
            });
        }
        let next = next_state(self.state, event).ok_or(TransitionError::InvalidTransition {
            state: self.state,
            event,
        })?;
        Ok(self.apply_transition(next))
    }

    fn apply_transition(&mut self, next: SessionState) -> StateChange {
        let from = self.state;
        self.state = next;
        self.sequence = self.sequence.saturating_add(1);
        StateChange {
            job_id: self.current_job_id,
            sequence: self.sequence,
            from,
            to: next,
        }
    }
}

const fn next_state(state: SessionState, event: SessionEvent) -> Option<SessionState> {
    match (state, event) {
        (SessionState::Idle, SessionEvent::BeginCapture) => Some(SessionState::Capturing),
        (SessionState::Capturing, SessionEvent::AudioCaptured) => Some(SessionState::Transcribing),
        (SessionState::Transcribing, SessionEvent::TranscriptReady) => {
            Some(SessionState::ScreeningInput)
        }
        (SessionState::ScreeningInput, SessionEvent::InputApproved) => {
            Some(SessionState::Generating)
        }
        (SessionState::Generating, SessionEvent::GenerationReady) => {
            Some(SessionState::ScreeningOutput)
        }
        (SessionState::ScreeningOutput, SessionEvent::OutputApproved) => {
            Some(SessionState::Synthesizing)
        }
        (SessionState::Synthesizing, SessionEvent::SynthesisReady) => Some(SessionState::Playing),
        (SessionState::Playing, SessionEvent::PlaybackFinished) => Some(SessionState::Idle),
        (active, SessionEvent::Cancel) if active.is_active() => Some(SessionState::Cancelled),
        (active, SessionEvent::Fail) if active.is_active() => Some(SessionState::Failed),
        (SessionState::Cancelled | SessionState::Failed, SessionEvent::Reset) => {
            Some(SessionState::Idle)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn begin(machine: &mut SessionMachine) -> u64 {
        machine.begin_turn().unwrap().job_id
    }

    #[test]
    fn complete_turn_follows_the_only_happy_path() {
        let mut machine = SessionMachine::default();
        let job = begin(&mut machine);
        for (event, expected) in [
            (SessionEvent::AudioCaptured, SessionState::Transcribing),
            (SessionEvent::TranscriptReady, SessionState::ScreeningInput),
            (SessionEvent::InputApproved, SessionState::Generating),
            (SessionEvent::GenerationReady, SessionState::ScreeningOutput),
            (SessionEvent::OutputApproved, SessionState::Synthesizing),
            (SessionEvent::SynthesisReady, SessionState::Playing),
            (SessionEvent::PlaybackFinished, SessionState::Idle),
        ] {
            assert_eq!(machine.apply(job, event).unwrap().to, expected);
        }
    }

    #[test]
    fn every_active_state_can_be_cancelled_and_reset() {
        let paths = [
            vec![],
            vec![SessionEvent::AudioCaptured],
            vec![SessionEvent::AudioCaptured, SessionEvent::TranscriptReady],
            vec![
                SessionEvent::AudioCaptured,
                SessionEvent::TranscriptReady,
                SessionEvent::InputApproved,
            ],
            vec![
                SessionEvent::AudioCaptured,
                SessionEvent::TranscriptReady,
                SessionEvent::InputApproved,
                SessionEvent::GenerationReady,
            ],
            vec![
                SessionEvent::AudioCaptured,
                SessionEvent::TranscriptReady,
                SessionEvent::InputApproved,
                SessionEvent::GenerationReady,
                SessionEvent::OutputApproved,
            ],
            vec![
                SessionEvent::AudioCaptured,
                SessionEvent::TranscriptReady,
                SessionEvent::InputApproved,
                SessionEvent::GenerationReady,
                SessionEvent::OutputApproved,
                SessionEvent::SynthesisReady,
            ],
        ];
        for path in paths {
            let mut machine = SessionMachine::default();
            let job = begin(&mut machine);
            for event in path {
                machine.apply(job, event).unwrap();
            }
            assert_eq!(
                machine.apply(job, SessionEvent::Cancel).unwrap().to,
                SessionState::Cancelled
            );
            assert_eq!(
                machine.apply(job, SessionEvent::Reset).unwrap().to,
                SessionState::Idle
            );
        }
    }

    #[test]
    fn stale_completion_from_prior_job_is_rejected() {
        let mut machine = SessionMachine::default();
        let first = begin(&mut machine);
        machine.apply(first, SessionEvent::Cancel).unwrap();
        machine.apply(first, SessionEvent::Reset).unwrap();
        let second = begin(&mut machine);
        assert_ne!(first, second);
        assert_eq!(
            machine.apply(first, SessionEvent::AudioCaptured),
            Err(TransitionError::StaleJob {
                expected: second,
                actual: first,
            })
        );
        assert_eq!(machine.state(), SessionState::Capturing);
    }

    #[test]
    fn invalid_transition_does_not_mutate_state_or_sequence() {
        let mut machine = SessionMachine::default();
        let job = begin(&mut machine);
        let before = machine.clone();
        assert!(matches!(
            machine.apply(job, SessionEvent::GenerationReady),
            Err(TransitionError::InvalidTransition { .. })
        ));
        assert_eq!(machine, before);
    }

    #[test]
    fn second_active_turn_is_rejected() {
        let mut machine = SessionMachine::default();
        begin(&mut machine);
        assert_eq!(machine.begin_turn(), Err(TransitionError::JobAlreadyActive));
    }
}
