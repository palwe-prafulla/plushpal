#![forbid(unsafe_code)]

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Platform {
    Ios,
    Android,
    MacOs,
    Windows,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Architecture {
    Arm64,
    X86_64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Acceleration {
    None,
    Metal,
    Vulkan,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeviceProfile {
    pub platform: Platform,
    pub architecture: Architecture,
    pub os_major: u16,
    pub total_memory_mib: u64,
    pub available_memory_mib: u64,
    pub free_storage_mib: u64,
    pub logical_cores: u16,
    pub acceleration: Acceleration,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelCandidate {
    pub model_id: String,
    pub quality_rank: u16,
    pub supported_platforms: Vec<Platform>,
    pub supported_architectures: Vec<Architecture>,
    pub minimum_os_versions: Vec<PlatformOsMinimum>,
    pub minimum_total_memory_mib: u64,
    pub expected_peak_memory_mib: u64,
    pub installed_size_mib: u64,
    pub minimum_logical_cores: u16,
    pub requires_acceleration: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlatformOsMinimum {
    pub platform: Platform,
    pub major: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IneligibilityReason {
    UnsupportedPlatform,
    UnsupportedArchitecture,
    OperatingSystemTooOld { required: u16, actual: u16 },
    InsufficientTotalMemory { required_mib: u64, actual_mib: u64 },
    InsufficientAvailableMemory { required_mib: u64, actual_mib: u64 },
    InsufficientStorage { required_mib: u64, actual_mib: u64 },
    TooFewLogicalCores { required: u16, actual: u16 },
    MissingAcceleration,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CandidateAssessment {
    pub model_id: String,
    pub eligible: bool,
    pub reasons: Vec<IneligibilityReason>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapabilityAssessment {
    pub recommended_model_id: Option<String>,
    pub candidates: Vec<CandidateAssessment>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AssessmentPolicy {
    pub memory_headroom_percent: u64,
    pub storage_reserve_mib: u64,
}

impl Default for AssessmentPolicy {
    fn default() -> Self {
        Self {
            memory_headroom_percent: 20,
            storage_reserve_mib: 512,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct CapabilityAssessor {
    policy: AssessmentPolicy,
}

impl CapabilityAssessor {
    #[must_use]
    pub const fn new(policy: AssessmentPolicy) -> Self {
        Self { policy }
    }

    #[must_use]
    pub fn assess(
        &self,
        device: &DeviceProfile,
        candidates: &[ModelCandidate],
    ) -> CapabilityAssessment {
        let mut assessments = Vec::with_capacity(candidates.len());
        let mut recommended: Option<(&ModelCandidate, String)> = None;

        for candidate in candidates {
            let reasons = self.ineligibility_reasons(device, candidate);
            let eligible = reasons.is_empty();
            if eligible
                && recommended
                    .as_ref()
                    .is_none_or(|(current, _)| candidate.quality_rank > current.quality_rank)
            {
                recommended = Some((candidate, candidate.model_id.clone()));
            }
            assessments.push(CandidateAssessment {
                model_id: candidate.model_id.clone(),
                eligible,
                reasons,
            });
        }

        CapabilityAssessment {
            recommended_model_id: recommended.map(|(_, model_id)| model_id),
            candidates: assessments,
        }
    }

    fn ineligibility_reasons(
        &self,
        device: &DeviceProfile,
        candidate: &ModelCandidate,
    ) -> Vec<IneligibilityReason> {
        let mut reasons = Vec::new();
        if !candidate.supported_platforms.contains(&device.platform) {
            reasons.push(IneligibilityReason::UnsupportedPlatform);
        }
        if !candidate
            .supported_architectures
            .contains(&device.architecture)
        {
            reasons.push(IneligibilityReason::UnsupportedArchitecture);
        }
        if let Some(minimum) = candidate
            .minimum_os_versions
            .iter()
            .find(|minimum| minimum.platform == device.platform)
        {
            if device.os_major < minimum.major {
                reasons.push(IneligibilityReason::OperatingSystemTooOld {
                    required: minimum.major,
                    actual: device.os_major,
                });
            }
        }
        if device.total_memory_mib < candidate.minimum_total_memory_mib {
            reasons.push(IneligibilityReason::InsufficientTotalMemory {
                required_mib: candidate.minimum_total_memory_mib,
                actual_mib: device.total_memory_mib,
            });
        }
        let required_available = percentage_with_ceiling(
            candidate.expected_peak_memory_mib,
            100 + self.policy.memory_headroom_percent,
        );
        if device.available_memory_mib < required_available {
            reasons.push(IneligibilityReason::InsufficientAvailableMemory {
                required_mib: required_available,
                actual_mib: device.available_memory_mib,
            });
        }
        let required_storage = candidate
            .installed_size_mib
            .saturating_add(self.policy.storage_reserve_mib);
        if device.free_storage_mib < required_storage {
            reasons.push(IneligibilityReason::InsufficientStorage {
                required_mib: required_storage,
                actual_mib: device.free_storage_mib,
            });
        }
        if device.logical_cores < candidate.minimum_logical_cores {
            reasons.push(IneligibilityReason::TooFewLogicalCores {
                required: candidate.minimum_logical_cores,
                actual: device.logical_cores,
            });
        }
        if candidate.requires_acceleration && device.acceleration == Acceleration::None {
            reasons.push(IneligibilityReason::MissingAcceleration);
        }
        reasons
    }
}

const fn percentage_with_ceiling(value: u64, percent: u64) -> u64 {
    value.saturating_mul(percent).saturating_add(99) / 100
}

#[must_use]
pub fn initial_model_candidates() -> Vec<ModelCandidate> {
    let platforms = vec![
        Platform::Ios,
        Platform::Android,
        Platform::MacOs,
        Platform::Windows,
    ];
    let architectures = vec![Architecture::Arm64, Architecture::X86_64];
    let minimum_os_versions = vec![
        PlatformOsMinimum {
            platform: Platform::Ios,
            major: 17,
        },
        PlatformOsMinimum {
            platform: Platform::Android,
            major: 29,
        },
        PlatformOsMinimum {
            platform: Platform::MacOs,
            major: 13,
        },
        PlatformOsMinimum {
            platform: Platform::Windows,
            major: 11,
        },
    ];
    vec![
        ModelCandidate {
            model_id: "qwen3-1.7b-q8".to_owned(),
            quality_rank: 10,
            supported_platforms: platforms.clone(),
            supported_architectures: architectures.clone(),
            minimum_os_versions: minimum_os_versions.clone(),
            minimum_total_memory_mib: 4_096,
            expected_peak_memory_mib: 2_500,
            installed_size_mib: 1_830,
            minimum_logical_cores: 4,
            requires_acceleration: true,
        },
        ModelCandidate {
            model_id: "qwen3-4b-q4".to_owned(),
            quality_rank: 20,
            supported_platforms: platforms,
            supported_architectures: architectures,
            minimum_os_versions,
            minimum_total_memory_mib: 8_192,
            expected_peak_memory_mib: 3_400,
            installed_size_mib: 2_800,
            minimum_logical_cores: 6,
            requires_acceleration: true,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(memory: u64, available: u64, storage: u64) -> DeviceProfile {
        DeviceProfile {
            platform: Platform::Ios,
            architecture: Architecture::Arm64,
            os_major: 18,
            total_memory_mib: memory,
            available_memory_mib: available,
            free_storage_mib: storage,
            logical_cores: 8,
            acceleration: Acceleration::Metal,
        }
    }

    #[test]
    fn enhanced_device_selects_highest_quality_eligible_tier() {
        let result = CapabilityAssessor::default()
            .assess(&device(16_384, 8_192, 10_000), &initial_model_candidates());
        assert_eq!(result.recommended_model_id.as_deref(), Some("qwen3-4b-q4"));
    }

    #[test]
    fn standard_device_falls_back_to_smaller_tier() {
        let result = CapabilityAssessor::default()
            .assess(&device(6_144, 3_200, 4_000), &initial_model_candidates());
        assert_eq!(
            result.recommended_model_id.as_deref(),
            Some("qwen3-1.7b-q8")
        );
    }

    #[test]
    fn memory_headroom_boundary_is_inclusive() {
        let candidate = &initial_model_candidates()[0];
        let result = CapabilityAssessor::default().assess(
            &device(4_096, 3_000, 2_342),
            std::slice::from_ref(candidate),
        );
        assert_eq!(
            result.recommended_model_id.as_deref(),
            Some("qwen3-1.7b-q8")
        );
    }

    #[test]
    fn one_mib_below_storage_reserve_fails() {
        let candidate = &initial_model_candidates()[0];
        let result = CapabilityAssessor::default().assess(
            &device(4_096, 3_000, 2_341),
            std::slice::from_ref(candidate),
        );
        assert_eq!(result.recommended_model_id, None);
        assert!(result.candidates[0]
            .reasons
            .contains(&IneligibilityReason::InsufficientStorage {
                required_mib: 2_342,
                actual_mib: 2_341,
            }));
    }

    #[test]
    fn missing_acceleration_and_old_os_are_reported_together() {
        let candidate = &initial_model_candidates()[0];
        let mut profile = device(8_192, 4_000, 4_000);
        profile.os_major = 16;
        profile.acceleration = Acceleration::None;
        let result =
            CapabilityAssessor::default().assess(&profile, std::slice::from_ref(candidate));
        assert!(result.candidates[0].reasons.contains(
            &IneligibilityReason::OperatingSystemTooOld {
                required: 17,
                actual: 16,
            }
        ));
        assert!(result.candidates[0]
            .reasons
            .contains(&IneligibilityReason::MissingAcceleration));
    }
}
