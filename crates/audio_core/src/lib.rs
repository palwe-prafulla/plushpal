#![forbid(unsafe_code)]

use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AudioFormat {
    pub sample_rate_hz: u32,
    pub channels: u8,
}

impl AudioFormat {
    pub fn validate(self) -> Result<(), AudioError> {
        if self.sample_rate_hz == 0 || self.channels == 0 || self.channels > 2 {
            return Err(AudioError::UnsupportedFormat);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AudioError {
    UnsupportedFormat,
    UnalignedFrame,
    BufferOverflow { capacity: usize, attempted: usize },
    PermissionDenied,
    Interrupted,
    StaleCallback,
    NotCapturing,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BoundedPcmBuffer {
    samples: VecDeque<i16>,
    capacity: usize,
}

impl BoundedPcmBuffer {
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        Self {
            samples: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    pub fn push(&mut self, samples: &[i16]) -> Result<(), AudioError> {
        let attempted = self.samples.len().saturating_add(samples.len());
        if attempted > self.capacity {
            return Err(AudioError::BufferOverflow {
                capacity: self.capacity,
                attempted,
            });
        }
        self.samples.extend(samples);
        Ok(())
    }

    #[must_use]
    pub fn pop(&mut self, maximum_samples: usize) -> Vec<i16> {
        let count = maximum_samples.min(self.samples.len());
        self.samples.drain(..count).collect()
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }
}

pub fn convert_to_mono_16khz(input: &[i16], format: AudioFormat) -> Result<Vec<i16>, AudioError> {
    format.validate()?;
    if input.len() % usize::from(format.channels) != 0 {
        return Err(AudioError::UnalignedFrame);
    }
    if format.sample_rate_hz % 16_000 != 0 {
        return Err(AudioError::UnsupportedFormat);
    }
    let downsample_factor = usize::try_from(format.sample_rate_hz / 16_000)
        .map_err(|_| AudioError::UnsupportedFormat)?;
    let mono: Vec<i16> = input
        .chunks_exact(usize::from(format.channels))
        .map(|frame| {
            let sum: i32 = frame.iter().map(|sample| i32::from(*sample)).sum();
            let average = sum / i32::try_from(frame.len()).unwrap_or(1);
            i16::try_from(average).unwrap_or(if average < 0 { i16::MIN } else { i16::MAX })
        })
        .collect();
    Ok(mono.into_iter().step_by(downsample_factor).collect())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CaptureState {
    Idle,
    Capturing,
    Interrupted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CaptureController {
    state: CaptureState,
    generation: u64,
}

impl Default for CaptureController {
    fn default() -> Self {
        Self {
            state: CaptureState::Idle,
            generation: 0,
        }
    }
}

impl CaptureController {
    pub fn start(&mut self, permission_granted: bool) -> Result<u64, AudioError> {
        if !permission_granted {
            return Err(AudioError::PermissionDenied);
        }
        self.generation = self.generation.saturating_add(1);
        self.state = CaptureState::Capturing;
        Ok(self.generation)
    }

    pub fn accept_callback(&self, generation: u64) -> Result<(), AudioError> {
        if generation != self.generation {
            return Err(AudioError::StaleCallback);
        }
        if self.state != CaptureState::Capturing {
            return Err(AudioError::NotCapturing);
        }
        Ok(())
    }

    pub fn interrupt(&mut self, generation: u64) -> Result<(), AudioError> {
        self.accept_callback(generation)?;
        self.state = CaptureState::Interrupted;
        Ok(())
    }

    pub fn resume(&mut self, permission_granted: bool) -> Result<u64, AudioError> {
        if self.state != CaptureState::Interrupted {
            return Err(AudioError::Interrupted);
        }
        self.start(permission_granted)
    }

    pub fn stop(&mut self, generation: u64) -> Result<(), AudioError> {
        self.accept_callback(generation)?;
        self.state = CaptureState::Idle;
        Ok(())
    }

    #[must_use]
    pub const fn state(&self) -> CaptureState {
        self.state
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffer_overflow_is_atomic() {
        let mut buffer = BoundedPcmBuffer::new(4);
        buffer.push(&[1, 2, 3]).unwrap();
        assert_eq!(
            buffer.push(&[4, 5]),
            Err(AudioError::BufferOverflow {
                capacity: 4,
                attempted: 5
            })
        );
        assert_eq!(buffer.pop(10), vec![1, 2, 3]);
    }

    #[test]
    fn stereo_48khz_is_mixed_and_downsampled() {
        let input = [3_000, 1_000, 6_000, 2_000, 9_000, 3_000, 12_000, 4_000];
        let converted = convert_to_mono_16khz(
            &input,
            AudioFormat {
                sample_rate_hz: 48_000,
                channels: 2,
            },
        )
        .unwrap();
        assert_eq!(converted, vec![2_000, 8_000]);
    }

    #[test]
    fn invalid_rate_and_unaligned_frames_fail_closed() {
        assert_eq!(
            convert_to_mono_16khz(
                &[1, 2],
                AudioFormat {
                    sample_rate_hz: 44_100,
                    channels: 1
                }
            ),
            Err(AudioError::UnsupportedFormat)
        );
        assert_eq!(
            convert_to_mono_16khz(
                &[1, 2, 3],
                AudioFormat {
                    sample_rate_hz: 48_000,
                    channels: 2
                }
            ),
            Err(AudioError::UnalignedFrame)
        );
    }

    #[test]
    fn permission_denial_does_not_start_capture() {
        let mut capture = CaptureController::default();
        assert_eq!(capture.start(false), Err(AudioError::PermissionDenied));
        assert_eq!(capture.state(), CaptureState::Idle);
    }

    #[test]
    fn interruption_resume_invalidates_old_callbacks() {
        let mut capture = CaptureController::default();
        let first = capture.start(true).unwrap();
        capture.interrupt(first).unwrap();
        let second = capture.resume(true).unwrap();
        assert_ne!(first, second);
        assert_eq!(
            capture.accept_callback(first),
            Err(AudioError::StaleCallback)
        );
        assert_eq!(capture.accept_callback(second), Ok(()));
    }

    #[test]
    fn callback_after_stop_is_rejected() {
        let mut capture = CaptureController::default();
        let generation = capture.start(true).unwrap();
        capture.stop(generation).unwrap();
        assert_eq!(
            capture.accept_callback(generation),
            Err(AudioError::NotCapturing)
        );
    }
}
