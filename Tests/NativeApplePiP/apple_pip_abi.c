#include <stddef.h>
#include <stdint.h>

#include <mpv/apple_pip.h>

_Static_assert(sizeof(void *) == 8, "MPVKit Apple targets require a 64-bit ABI");

_Static_assert(MPV_APPLE_PIP_API_VERSION == 1u, "unexpected API version");
_Static_assert(MPV_APPLE_PIP_PIXEL_FORMAT_BGRA == 0x42475241u,
               "unexpected BGRA fourcc");
_Static_assert(MPV_APPLE_PIP_OK == 0, "unexpected result ABI");
_Static_assert(MPV_APPLE_PIP_INTERNAL_ERROR == -8, "unexpected result ABI");
_Static_assert(MPV_APPLE_PIP_MODE_INLINE_ONLY == 0, "unexpected mode ABI");
_Static_assert(MPV_APPLE_PIP_MODE_DUAL_OUTPUT_RESTORE == 3,
               "unexpected mode ABI");
_Static_assert(MPV_APPLE_PIP_CAP_DIRECT_IOSURFACE == (1ull << 0),
               "unexpected capability ABI");
_Static_assert(MPV_APPLE_PIP_CAP_ASYNC_COMPLETION == (1ull << 3),
               "unexpected capability ABI");
_Static_assert(MPV_APPLE_PIP_FRAME_READY == 0, "unexpected status ABI");
_Static_assert(MPV_APPLE_PIP_FRAME_RENDER_FAILED == 3,
               "unexpected status ABI");

_Static_assert(offsetof(struct mpv_apple_pip_capabilities, struct_size) == 0,
               "capabilities layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_capabilities, api_version) == 4,
               "capabilities layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_capabilities, flags) == 8,
               "capabilities layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_capabilities, pixel_format) == 16,
               "capabilities layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_capabilities, max_queued_targets) == 20,
               "capabilities layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_capabilities, diagnostic) == 24,
               "capabilities layout changed");
_Static_assert(sizeof(struct mpv_apple_pip_capabilities) == 184,
               "capabilities layout changed");

_Static_assert(offsetof(struct mpv_apple_pip_target, struct_size) == 0,
               "target layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_target, io_surface) == 16,
               "target layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_target, token) == 24,
               "target layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_target, generation) == 32,
               "target layout changed");
_Static_assert(sizeof(struct mpv_apple_pip_target) == 40,
               "target layout changed");

_Static_assert(offsetof(struct mpv_apple_pip_frame, struct_size) == 0,
               "frame layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_frame, backend) == 20,
               "frame layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_frame, token) == 24,
               "frame layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_frame, generation) == 32,
               "frame layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_frame, pts) == 40,
               "frame layout changed");
_Static_assert(offsetof(struct mpv_apple_pip_frame, duration) == 48,
               "frame layout changed");
_Static_assert(sizeof(struct mpv_apple_pip_frame) == 56,
               "frame layout changed");

/*
 * Simulate libmpv's client.c archive member. Referencing mpv_create pulls this
 * object from a static archive; retain/default-visibility must then preserve
 * the optional entry points for dlsym under -dead_strip.
 */
MPV_EXPORT mpv_handle *mpv_create(void)
{
    return (mpv_handle *)(uintptr_t)1;
}

MPV_APPLE_PIP_EXPORT uint32_t mpv_apple_pip_api_version(void)
{
    return MPV_APPLE_PIP_API_VERSION;
}

MPV_APPLE_PIP_EXPORT int mpv_apple_pip_get_capabilities(
    mpv_handle *ctx, struct mpv_apple_pip_capabilities *capabilities)
{
    (void)ctx;
    (void)capabilities;
    return MPV_APPLE_PIP_OK;
}

MPV_APPLE_PIP_EXPORT int mpv_apple_pip_set_callback(
    mpv_handle *ctx, mpv_apple_pip_frame_callback callback,
    void *callback_ctx)
{
    (void)ctx;
    (void)callback;
    (void)callback_ctx;
    return MPV_APPLE_PIP_OK;
}

MPV_APPLE_PIP_EXPORT int mpv_apple_pip_set_mode(
    mpv_handle *ctx, uint32_t mode, uint64_t generation)
{
    (void)ctx;
    (void)mode;
    (void)generation;
    return MPV_APPLE_PIP_OK;
}

MPV_APPLE_PIP_EXPORT int mpv_apple_pip_submit_target(
    mpv_handle *ctx, const struct mpv_apple_pip_target *target)
{
    (void)ctx;
    (void)target;
    return MPV_APPLE_PIP_OK;
}

MPV_APPLE_PIP_EXPORT int mpv_apple_pip_disable_and_drain(mpv_handle *ctx)
{
    (void)ctx;
    return MPV_APPLE_PIP_OK;
}

__attribute__((visibility("default"), used, retain))
uint64_t mpv_apple_audiounit_recovery_count(void)
{
    return 0;
}
