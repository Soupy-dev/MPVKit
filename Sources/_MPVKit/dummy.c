#include <stddef.h>
#include <stdint.h>

#include "dummy.h"

#if defined(__has_attribute)
#if __has_attribute(weak)
#define MPVKIT_WEAK_FALLBACK __attribute__((weak))
#else
#define MPVKIT_WEAK_FALLBACK
#endif
#else
#define MPVKIT_WEAK_FALLBACK
#endif

/*
 * Keep the optional ABI linker-visible without requiring it from older published Libmpv
 * artifacts. A rebuilt Libmpv's strong definitions replace these inert weak fallbacks. The Swift
 * wrappers call the providers directly, so taking each resolved symbol's address survives App
 * Store export's strip -D pass.
 */
typedef void (*mpvkit_apple_pip_frame_callback)(void *, const void *);

MPVKIT_WEAK_FALLBACK uint32_t mpv_apple_pip_api_version(void)
{
    return 0;
}

MPVKIT_WEAK_FALLBACK int mpv_apple_pip_get_capabilities(void *ctx, void *capabilities)
{
    (void)ctx;
    (void)capabilities;
    return -1;
}

MPVKIT_WEAK_FALLBACK int mpv_apple_pip_set_callback(
    void *ctx, mpvkit_apple_pip_frame_callback callback, void *callback_ctx)
{
    (void)ctx;
    (void)callback;
    (void)callback_ctx;
    return -1;
}

MPVKIT_WEAK_FALLBACK int mpv_apple_pip_set_mode(
    void *ctx, uint32_t mode, uint64_t generation)
{
    (void)ctx;
    (void)mode;
    (void)generation;
    return -1;
}

MPVKIT_WEAK_FALLBACK int mpv_apple_pip_submit_target(void *ctx, const void *target)
{
    (void)ctx;
    (void)target;
    return -1;
}

MPVKIT_WEAK_FALLBACK int mpv_apple_pip_disable_and_drain(void *ctx)
{
    (void)ctx;
    return -1;
}

MPVKIT_WEAK_FALLBACK uint64_t mpv_apple_audiounit_recovery_count(void)
{
    return 0;
}

#define MPVKIT_DEFINE_SYMBOL_PROVIDER(provider, symbol) \
    void *provider(void)                                  \
    {                                                     \
        union {                                           \
            __typeof__(&symbol) function;                 \
            void *pointer;                                \
        } value = { .function = symbol };                 \
        return value.pointer;                             \
    }

MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_api_version_symbol,
    mpv_apple_pip_api_version)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_get_capabilities_symbol,
    mpv_apple_pip_get_capabilities)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_set_callback_symbol,
    mpv_apple_pip_set_callback)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_set_mode_symbol,
    mpv_apple_pip_set_mode)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_submit_target_symbol,
    mpv_apple_pip_submit_target)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_pip_disable_and_drain_symbol,
    mpv_apple_pip_disable_and_drain)
MPVKIT_DEFINE_SYMBOL_PROVIDER(
    mpvkit_apple_audiounit_recovery_count_symbol,
    mpv_apple_audiounit_recovery_count)
