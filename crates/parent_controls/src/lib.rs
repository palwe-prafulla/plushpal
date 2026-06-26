#![forbid(unsafe_code)]

use std::num::NonZeroU32;

use ring::pbkdf2;
use subtle::ConstantTimeEq;

const PIN_HASH_BYTES: usize = 32;
const MIN_PIN_DIGITS: usize = 4;
const MAX_PIN_DIGITS: usize = 8;
const PBKDF2_ITERATIONS: u32 = 120_000;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ParentAuthError {
    InvalidPin,
    InvalidSalt,
    LockedUntil(i64),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ParentPinHash {
    salt: [u8; 16],
    derived: [u8; PIN_HASH_BYTES],
}

impl ParentPinHash {
    pub fn derive(pin: &str, salt: [u8; 16]) -> Result<Self, ParentAuthError> {
        validate_pin(pin)?;
        if salt.iter().all(|byte| *byte == 0) {
            return Err(ParentAuthError::InvalidSalt);
        }
        let mut derived = [0_u8; PIN_HASH_BYTES];
        pbkdf2::derive(
            pbkdf2::PBKDF2_HMAC_SHA256,
            NonZeroU32::new(PBKDF2_ITERATIONS).expect("iteration count is non-zero"),
            &salt,
            pin.as_bytes(),
            &mut derived,
        );
        Ok(Self { salt, derived })
    }

    pub fn verify(&self, candidate: &str) -> Result<bool, ParentAuthError> {
        validate_pin(candidate)?;
        let expected = Self::derive(candidate, self.salt)?;
        Ok(self.derived.ct_eq(&expected.derived).into())
    }

    #[must_use]
    pub fn encoded(&self) -> String {
        format!(
            "v1:{}:{}",
            hex_encode(&self.salt),
            hex_encode(&self.derived)
        )
    }

    pub fn decode(value: &str) -> Result<Self, ParentAuthError> {
        let mut parts = value.split(':');
        if parts.next() != Some("v1") || parts.clone().count() != 2 {
            return Err(ParentAuthError::InvalidPin);
        }
        let salt = decode_array(parts.next().unwrap_or_default())?;
        let derived = decode_array(parts.next().unwrap_or_default())?;
        Ok(Self { salt, derived })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ParentGate {
    failed_attempts: u8,
    locked_until: Option<i64>,
}

impl ParentGate {
    pub fn authorize(
        &mut self,
        stored: &ParentPinHash,
        candidate: &str,
        now: i64,
    ) -> Result<(), ParentAuthError> {
        if self.locked_until.is_some_and(|until| now < until) {
            return Err(ParentAuthError::LockedUntil(
                self.locked_until.unwrap_or(now),
            ));
        }
        if stored.verify(candidate)? {
            self.failed_attempts = 0;
            self.locked_until = None;
            return Ok(());
        }
        self.failed_attempts = self.failed_attempts.saturating_add(1);
        if self.failed_attempts >= 5 {
            let until = now.saturating_add(60);
            self.locked_until = Some(until);
            return Err(ParentAuthError::LockedUntil(until));
        }
        Err(ParentAuthError::InvalidPin)
    }
}

fn validate_pin(pin: &str) -> Result<(), ParentAuthError> {
    if !(MIN_PIN_DIGITS..=MAX_PIN_DIGITS).contains(&pin.len())
        || !pin.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(ParentAuthError::InvalidPin);
    }
    Ok(())
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_array<const N: usize>(value: &str) -> Result<[u8; N], ParentAuthError> {
    if value.len() != N * 2 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ParentAuthError::InvalidPin);
    }
    let mut output = [0_u8; N];
    for (index, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(pair).map_err(|_| ParentAuthError::InvalidPin)?;
        output[index] = u8::from_str_radix(text, 16).map_err(|_| ParentAuthError::InvalidPin)?;
    }
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pin_hash_round_trip_never_encodes_plain_pin() {
        let hash = ParentPinHash::derive("4826", [7; 16]).unwrap();
        let encoded = hash.encoded();
        assert!(!encoded.contains("4826"));
        let decoded = ParentPinHash::decode(&encoded).unwrap();
        assert!(decoded.verify("4826").unwrap());
        assert!(!decoded.verify("4827").unwrap());
    }

    #[test]
    fn malformed_pins_and_zero_salt_fail_closed() {
        for pin in ["123", "123456789", "12a4", " 1234"] {
            assert_eq!(
                ParentPinHash::derive(pin, [1; 16]),
                Err(ParentAuthError::InvalidPin)
            );
        }
        assert_eq!(
            ParentPinHash::derive("1234", [0; 16]),
            Err(ParentAuthError::InvalidSalt)
        );
    }

    #[test]
    fn five_failures_lock_gate_and_success_resets_counter() {
        let hash = ParentPinHash::derive("4826", [9; 16]).unwrap();
        let mut gate = ParentGate::default();
        for attempt in 0..4 {
            assert_eq!(
                gate.authorize(&hash, "1111", attempt),
                Err(ParentAuthError::InvalidPin)
            );
        }
        assert_eq!(
            gate.authorize(&hash, "1111", 4),
            Err(ParentAuthError::LockedUntil(64))
        );
        assert_eq!(
            gate.authorize(&hash, "4826", 63),
            Err(ParentAuthError::LockedUntil(64))
        );
        assert_eq!(gate.authorize(&hash, "4826", 64), Ok(()));
    }
}
