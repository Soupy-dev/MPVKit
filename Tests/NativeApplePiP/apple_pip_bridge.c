#include <stdint.h>
#include <stdio.h>

#include <mpv/client.h>

#include "dummy.h"

typedef uint32_t (*api_version_function)(void);
typedef uint64_t (*recovery_count_function)(void);

static api_version_function api_version_from_pointer(void *pointer)
{
    union {
        void *pointer;
        api_version_function function;
    } value = { .pointer = pointer };
    return value.function;
}

static recovery_count_function recovery_count_from_pointer(void *pointer)
{
    union {
        void *pointer;
        recovery_count_function function;
    } value = { .pointer = pointer };
    return value.function;
}

int main(void)
{
    if (!mpv_create()) {
        fputs("failed pulling the libmpv client archive member\n", stderr);
        return 1;
    }

    void *const symbols[] = {
        mpvkit_apple_pip_api_version_symbol(),
        mpvkit_apple_pip_get_capabilities_symbol(),
        mpvkit_apple_pip_set_callback_symbol(),
        mpvkit_apple_pip_set_mode_symbol(),
        mpvkit_apple_pip_submit_target_symbol(),
        mpvkit_apple_pip_disable_and_drain_symbol(),
        mpvkit_apple_audiounit_recovery_count_symbol(),
    };
    for (size_t index = 0; index < sizeof(symbols) / sizeof(symbols[0]); index++) {
        if (!symbols[index]) {
            fprintf(stderr, "weak native bridge returned nil for symbol %zu\n", index);
            return 2;
        }
    }

    api_version_function api_version = api_version_from_pointer(symbols[0]);
    recovery_count_function recovery_count = recovery_count_from_pointer(symbols[6]);
    if (api_version() != 1 || recovery_count() != 0) {
        fputs("native bridge resolved an invalid function address\n", stderr);
        return 3;
    }

    puts("Apple PiP weak bridge resolved all seven native APIs.");
    return 0;
}
