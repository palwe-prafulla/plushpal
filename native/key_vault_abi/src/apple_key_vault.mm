#include "plushpal_key_vault.h"

#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#include <TargetConditionals.h>

#include <cstring>

namespace {

constexpr size_t kMaximumRecordIdBytes = 256;
constexpr size_t kMaximumSecretBytes = 16 * 1024;

bool valid_record_id(pp_key_vault_bytes_t value) {
  return value.data != nullptr && value.length > 0 &&
         value.length <= kMaximumRecordIdBytes &&
         std::memchr(value.data, '\0', value.length) == nullptr;
}

CFStringRef create_record_id(pp_key_vault_bytes_t value) {
  return CFStringCreateWithBytes(kCFAllocatorDefault, value.data, value.length,
                                 kCFStringEncodingUTF8, false);
}

CFMutableDictionaryRef create_query(CFStringRef account) {
  CFMutableDictionaryRef query = CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  if (query != nullptr) {
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR("com.plushpal.local"));
    CFDictionarySetValue(query, kSecAttrAccount, account);
  }
  return query;
}

pp_key_vault_status_t map_status(OSStatus status) {
  switch (status) {
  case errSecSuccess:
    return PP_KEY_VAULT_OK;
  case errSecItemNotFound:
    return PP_KEY_VAULT_NOT_FOUND;
  case errSecAuthFailed:
  case errSecInteractionNotAllowed:
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
      secret.length > kMaximumSecretBytes) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFStringRef account = create_record_id(record_id);
  if (account == nullptr) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFMutableDictionaryRef query = create_query(account);
  CFDataRef data = CFDataCreate(kCFAllocatorDefault, secret.data, secret.length);
  if (query == nullptr || data == nullptr) {
    if (query != nullptr) CFRelease(query);
    if (data != nullptr) CFRelease(data);
    CFRelease(account);
    return PP_KEY_VAULT_INTERNAL;
  }
  SecItemDelete(query);
  CFDictionarySetValue(query, kSecValueData, data);
  CFDictionarySetValue(query, kSecAttrAccessible,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
  const OSStatus status = SecItemAdd(query, nullptr);
  CFRelease(data);
  CFRelease(query);
  CFRelease(account);
  return map_status(status);
}

extern "C" pp_key_vault_status_t pp_key_vault_read(
    uint32_t abi_version, pp_key_vault_bytes_t record_id,
    pp_key_vault_mut_bytes_t output, size_t *out_required) {
  if (abi_version != PP_KEY_VAULT_ABI_VERSION || !valid_record_id(record_id) ||
      out_required == nullptr || (output.data == nullptr && output.length != 0)) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFStringRef account = create_record_id(record_id);
  if (account == nullptr) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFMutableDictionaryRef query = create_query(account);
  if (query == nullptr) {
    CFRelease(account);
    return PP_KEY_VAULT_INTERNAL;
  }
  CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
  CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
  CFTypeRef result = nullptr;
  const OSStatus status = SecItemCopyMatching(query, &result);
  CFRelease(query);
  CFRelease(account);
  if (status != errSecSuccess) {
    return map_status(status);
  }
  if (result == nullptr || CFGetTypeID(result) != CFDataGetTypeID()) {
    if (result != nullptr) CFRelease(result);
    return PP_KEY_VAULT_INTERNAL;
  }
  CFDataRef data = static_cast<CFDataRef>(result);
  const size_t required = static_cast<size_t>(CFDataGetLength(data));
  *out_required = required;
  if (output.data == nullptr || output.length < required) {
    CFRelease(data);
    return PP_KEY_VAULT_BUFFER_TOO_SMALL;
  }
  std::memcpy(output.data, CFDataGetBytePtr(data), required);
  CFRelease(data);
  return PP_KEY_VAULT_OK;
}

extern "C" pp_key_vault_status_t pp_key_vault_delete(
    uint32_t abi_version, pp_key_vault_bytes_t record_id) {
  if (abi_version != PP_KEY_VAULT_ABI_VERSION || !valid_record_id(record_id)) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFStringRef account = create_record_id(record_id);
  if (account == nullptr) {
    return PP_KEY_VAULT_INVALID_ARGUMENT;
  }
  CFMutableDictionaryRef query = create_query(account);
  if (query == nullptr) {
    CFRelease(account);
    return PP_KEY_VAULT_INTERNAL;
  }
  const OSStatus status = SecItemDelete(query);
  CFRelease(query);
  CFRelease(account);
  return map_status(status);
}
