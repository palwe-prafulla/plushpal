#include "plushpal_key_vault.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>

#include <cstring>
#include <string>

namespace {
constexpr size_t kMaximumRecordIdBytes = 256;

bool valid_record_id(pp_key_vault_bytes_t value) {
  return value.data != nullptr && value.length > 0 &&
         value.length <= kMaximumRecordIdBytes &&
         std::memchr(value.data, '\0', value.length) == nullptr;
}

bool to_target_name(pp_key_vault_bytes_t record_id, std::wstring &target) {
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS,
      reinterpret_cast<const char *>(record_id.data),
      static_cast<int>(record_id.length), nullptr, 0);
  if (length <= 0) return false;
  std::wstring record(static_cast<size_t>(length), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                          reinterpret_cast<const char *>(record_id.data),
                          static_cast<int>(record_id.length), record.data(),
                          length) != length) {
    return false;
  }
  target = L"PlushPal/" + record;
  return true;
}

pp_key_vault_status_t map_error(DWORD error) {
  switch (error) {
  case ERROR_NOT_FOUND:
    return PP_KEY_VAULT_NOT_FOUND;
  case ERROR_ACCESS_DENIED:
  case ERROR_NO_SUCH_LOGON_SESSION:
    return PP_KEY_VAULT_ACCESS_DENIED;
  default:
    return PP_KEY_VAULT_INTERNAL;
  }
}
} // namespace

extern "C" pp_key_vault_status_t pp_key_vault_store(
    uint32_t abi_version, pp_key_vault_bytes_t record_id,
    pp_key_vault_bytes_t secret) {
  if (abi_version != PP_KEY_VAULT_ABI_VERSION || !valid_record_id(record_id) ||
      secret.data == nullptr || secret.length < 16 ||
      secret.length > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  std::wstring target;
  if (!to_target_name(record_id, target)) return PP_KEY_VAULT_INVALID_ARGUMENT;
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = target.data();
  credential.CredentialBlobSize = static_cast<DWORD>(secret.length);
  credential.CredentialBlob = const_cast<LPBYTE>(secret.data);
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.UserName = const_cast<LPWSTR>(L"PlushPal");
  if (!CredWriteW(&credential, 0)) return map_error(GetLastError());
  return PP_KEY_VAULT_OK;
}

extern "C" pp_key_vault_status_t pp_key_vault_read(
    uint32_t abi_version, pp_key_vault_bytes_t record_id,
    pp_key_vault_mut_bytes_t output, size_t *out_required) {
  if (abi_version != PP_KEY_VAULT_ABI_VERSION || !valid_record_id(record_id) ||
      out_required == nullptr || (output.data == nullptr && output.length != 0)) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  std::wstring target;
  if (!to_target_name(record_id, target)) return PP_KEY_VAULT_INVALID_ARGUMENT;
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    return map_error(GetLastError());
  }
  const size_t required = credential->CredentialBlobSize;
  *out_required = required;
  if (output.data == nullptr || output.length < required) {
    CredFree(credential);
    return PP_KEY_VAULT_BUFFER_TOO_SMALL;
  }
  std::memcpy(output.data, credential->CredentialBlob, required);
  CredFree(credential);
  return PP_KEY_VAULT_OK;
}

extern "C" pp_key_vault_status_t pp_key_vault_delete(
    uint32_t abi_version, pp_key_vault_bytes_t record_id) {
  if (abi_version != PP_KEY_VAULT_ABI_VERSION || !valid_record_id(record_id)) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  std::wstring target;
  if (!to_target_name(record_id, target)) return PP_KEY_VAULT_INVALID_ARGUMENT;
  if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0)) {
    return map_error(GetLastError());
  }
  return PP_KEY_VAULT_OK;
}
