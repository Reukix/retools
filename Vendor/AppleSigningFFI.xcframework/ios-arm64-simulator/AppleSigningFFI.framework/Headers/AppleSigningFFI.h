#ifndef RETOOLS_APPLE_SIGNING_H
#define RETOOLS_APPLE_SIGNING_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// These calls block and must run off the main thread. Results are JSON.
// Callback returns strdup-allocated JSON; Rust frees it with libc free.
typedef char *(*RTAppleTwoFactorCallback)(const char *request_json, void *context);
char *rt_apple_check_service(const char *request_json);
char *rt_apple_login(const char *request_json, RTAppleTwoFactorCallback callback, void *context);
char *rt_apple_profile(const char *request_json);
/// Profiles for an app and its extensions: App IDs, features and App Groups like SideStore.
char *rt_apple_app_profiles(const char *request_json);
/// The team's App IDs with expiry dates and the remaining App ID quota.
char *rt_apple_app_ids(const char *request_json);
/// The team's iOS development certificates (read only).
char *rt_apple_certificates(const char *request_json);
/// Revokes a development certificate by serial number; apps signed with it stop launching.
char *rt_apple_revoke_certificate(const char *request_json);
void rt_apple_string_free(char *value);
// Asynchronous local pairing. Copy event JSON during the callback; never free it.
// A nonzero handle receives exactly one terminal completed/failed/cancelled event.
typedef void (*RTDevicePairingEvent)(const char *event_json, void *context);
uint64_t rt_device_pairing_start(const char *request_json, RTDevicePairingEvent callback, void *context);
void rt_device_pairing_cancel(uint64_t handle);
bool rt_device_pairing_matches(const uint8_t *record, size_t length, const char *identifier, const char *auth_tag);
char *rt_device_pairing_verify(const uint8_t *record, size_t length, const char *host_ip, uint16_t port);
#ifdef __cplusplus
}
#endif
#endif
