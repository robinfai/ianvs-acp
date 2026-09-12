/* ianvs ACP C ABI v11. Implementation: rust/crates/ianvs-acp-ffi/src/lib.rs.
 * Strings passed in are borrowed NUL-terminated UTF-8, valid for the call.
 * Returned strings are owned and must be freed with ianvs_acp_string_free.
 * Poll from one consumer only; never use a handle concurrently with free.
 * Command true means queued; completion/failure arrives in schema-v4 events.
 */
#ifndef IANVS_ACP_H
#define IANVS_ACP_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define IANVS_ACP_FFI_VERSION 11
#define IANVS_ACP_EVENT_SCHEMA_VERSION 4
typedef struct IanvsRuntime IanvsRuntime;

uint32_t ianvs_acp_ffi_version(void);
IanvsRuntime * ianvs_acp_runtime_new(void);
void ianvs_acp_runtime_free(IanvsRuntime * runtime);
bool ianvs_acp_start_agent(IanvsRuntime * runtime, const char * config_json);
bool ianvs_acp_create_session(IanvsRuntime * runtime, const char * request_id, const char * cwd, const char * additional_directories_json);
bool ianvs_acp_restore_session(IanvsRuntime * runtime, const char * request_id, const char * session_id, const char * cwd, const char * additional_directories_json, bool replay_history);
bool ianvs_acp_list_sessions(IanvsRuntime * runtime, const char * request_id);
bool ianvs_acp_close_session(IanvsRuntime * runtime, const char * request_id, const char * session_id);
bool ianvs_acp_delete_session(IanvsRuntime * runtime, const char * request_id, const char * session_id);
bool ianvs_acp_authenticate(IanvsRuntime * runtime, const char * request_id, const char * method_id);
bool ianvs_acp_logout(IanvsRuntime * runtime, const char * request_id);
bool ianvs_acp_prompt(IanvsRuntime * runtime, const char * request_id, const char * session_id, const char * text);
bool ianvs_acp_prompt_with_attachments(IanvsRuntime * runtime, const char * request_id, const char * session_id, const char * text, const char * attachments_json);
bool ianvs_acp_cancel(IanvsRuntime * runtime, const char * request_id, const char * session_id);
bool ianvs_acp_respond_permission(IanvsRuntime * runtime, const char * request_id, const char * decision_json);
bool ianvs_acp_set_mode(IanvsRuntime * runtime, const char * request_id, const char * session_id, const char * mode_id);
bool ianvs_acp_set_config_option(IanvsRuntime * runtime, const char * request_id, const char * session_id, const char * config_id, const char * value_json);
bool ianvs_acp_dispose(IanvsRuntime * runtime);
char * ianvs_acp_poll_events(IanvsRuntime * runtime, uint32_t max_events, uint64_t max_bytes, uint32_t timeout_ms);
char * ianvs_acp_last_error(IanvsRuntime * runtime);
void ianvs_acp_string_free(char * value);

#ifdef __cplusplus
}
#endif
#endif
