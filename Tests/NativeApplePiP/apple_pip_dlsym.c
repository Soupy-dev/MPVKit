#include <dlfcn.h>
#include <stdio.h>

#include <mpv/client.h>

int main(void)
{
    static const char *const symbols[] = {
        "mpv_apple_pip_api_version",
        "mpv_apple_pip_get_capabilities",
        "mpv_apple_pip_set_callback",
        "mpv_apple_pip_set_mode",
        "mpv_apple_pip_submit_target",
        "mpv_apple_pip_disable_and_drain",
        "mpv_apple_audiounit_recovery_count",
    };

    if (!mpv_create()) {
        fputs("failed pulling the libmpv client archive member\n", stderr);
        return 1;
    }

    for (size_t i = 0; i < sizeof(symbols) / sizeof(symbols[0]); i++) {
        if (!dlsym(RTLD_DEFAULT, symbols[i])) {
            fprintf(stderr, "dead-stripped or hidden symbol: %s\n", symbols[i]);
            return 2;
        }
    }

    puts("Apple PiP ABI and seven retained dlsym symbols validated.");
    return 0;
}
