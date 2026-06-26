#![allow(unsafe_code)]

use std::{fmt, ptr};

use plushpal_encrypted_storage::{KeyVault, SecretMaterial, SecretRef};

const ABI_VERSION: u32 = 1;
const OK: i32 = 0;
const NOT_FOUND: i32 = 2;
const BUFFER_TOO_SMALL: i32 = 3;
const MAXIMUM_SECRET_BYTES: usize = 16 * 1024;

#[repr(C)]
struct Bytes {
    data: *const u8,
    length: usize,
}

#[repr(C)]
struct MutBytes {
    data: *mut u8,
    length: usize,
}

unsafe extern "C" {
    fn pp_key_vault_store(abi_version: u32, record_id: Bytes, secret: Bytes) -> i32;
    fn pp_key_vault_read(
        abi_version: u32,
        record_id: Bytes,
        output: MutBytes,
        out_required: *mut usize,
    ) -> i32;
    fn pp_key_vault_delete(abi_version: u32, record_id: Bytes) -> i32;
}

#[derive(Default)]
pub struct PlatformKeyVault;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PlatformKeyVaultError;

impl fmt::Debug for PlatformKeyVault {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PlatformKeyVault([OS PROTECTED])")
    }
}

fn bytes(value: &[u8]) -> Bytes {
    Bytes {
        data: value.as_ptr(),
        length: value.len(),
    }
}

impl PlatformKeyVault {
    pub fn store_secret(
        &mut self,
        label: &str,
        mut secret: Vec<u8>,
    ) -> Result<SecretRef, PlatformKeyVaultError> {
        let status =
            unsafe { pp_key_vault_store(ABI_VERSION, bytes(label.as_bytes()), bytes(&secret)) };
        secret.fill(0);
        if status == OK {
            Ok(SecretRef(label.to_owned()))
        } else {
            Err(PlatformKeyVaultError)
        }
    }
}

impl KeyVault for PlatformKeyVault {
    fn store(&mut self, label: &str, secret: Vec<u8>) -> SecretRef {
        self.store_secret(label, secret)
            .expect("operating-system key vault rejected a secret")
    }

    fn delete(&mut self, secret_ref: &SecretRef) -> bool {
        let status = unsafe { pp_key_vault_delete(ABI_VERSION, bytes(secret_ref.0.as_bytes())) };
        status == OK || status == NOT_FOUND
    }

    fn contains(&self, secret_ref: &SecretRef) -> bool {
        let mut required = 0;
        let status = unsafe {
            pp_key_vault_read(
                ABI_VERSION,
                bytes(secret_ref.0.as_bytes()),
                MutBytes {
                    data: ptr::null_mut(),
                    length: 0,
                },
                &mut required,
            )
        };
        status == BUFFER_TOO_SMALL && (16..=MAXIMUM_SECRET_BYTES).contains(&required)
    }

    fn load(&self, secret_ref: &SecretRef) -> Option<SecretMaterial> {
        let mut required = 0;
        let probe = unsafe {
            pp_key_vault_read(
                ABI_VERSION,
                bytes(secret_ref.0.as_bytes()),
                MutBytes {
                    data: ptr::null_mut(),
                    length: 0,
                },
                &mut required,
            )
        };
        if probe == NOT_FOUND
            || probe != BUFFER_TOO_SMALL
            || !(16..=MAXIMUM_SECRET_BYTES).contains(&required)
        {
            return None;
        }
        let mut output = vec![0_u8; required];
        let status = unsafe {
            pp_key_vault_read(
                ABI_VERSION,
                bytes(secret_ref.0.as_bytes()),
                MutBytes {
                    data: output.as_mut_ptr(),
                    length: output.len(),
                },
                &mut required,
            )
        };
        (status == OK).then(|| SecretMaterial::new(output))
    }
}
