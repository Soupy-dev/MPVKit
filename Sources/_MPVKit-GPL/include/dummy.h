#ifndef MPVKIT_DUMMY_H
#define MPVKIT_DUMMY_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *mpvkit_apple_pip_api_version_symbol(void);
void *mpvkit_apple_pip_get_capabilities_symbol(void);
void *mpvkit_apple_pip_set_callback_symbol(void);
void *mpvkit_apple_pip_set_mode_symbol(void);
void *mpvkit_apple_pip_submit_target_symbol(void);
void *mpvkit_apple_pip_disable_and_drain_symbol(void);
void *mpvkit_apple_audiounit_recovery_count_symbol(void);

#ifdef __cplusplus
}
#endif

#endif
