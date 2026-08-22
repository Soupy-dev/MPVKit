#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_directory="$repository_root/Sources/BuildScripts/patch/libmpv"
fixture_directory="$repository_root/Tests/NativeApplePiP"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-apple-pip-native.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

if [[ -n "${MPV_SOURCE_DIR:-}" ]]; then
    source_directory="$(cd "$MPV_SOURCE_DIR" && pwd)"
    git clone --quiet --no-local --no-checkout "$source_directory" "$temporary_root/mpv"
else
    git clone --quiet --depth 1 --branch v0.41.0 --no-checkout \
        https://github.com/mpv-player/mpv.git "$temporary_root/mpv"
fi

git -C "$temporary_root/mpv" checkout --quiet v0.41.0
while IFS= read -r patch; do
    git -C "$temporary_root/mpv" apply --check "$patch"
    git -C "$temporary_root/mpv" apply "$patch"
done < <(find "$patch_directory" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)

client_source="$temporary_root/mpv/player/client.c"
sink_source="$temporary_root/mpv/video/out/vo_gpu_next.c"
audio_source="$temporary_root/mpv/audio/out/ao_audiounit.m"
for symbol in \
    mpv_apple_pip_api_version \
    mpv_apple_pip_get_capabilities \
    mpv_apple_pip_set_callback \
    mpv_apple_pip_set_mode \
    mpv_apple_pip_submit_target \
    mpv_apple_pip_disable_and_drain
do
    if ! grep -q "MPV_APPLE_PIP_EXPORT.*$symbol" "$client_source"; then
        echo "Missing retained client.c definition: $symbol" >&2
        exit 1
    fi
done

if ! grep -q 'visibility("default"), used, retain.*' "$audio_source" ||
   ! grep -q 'mpv_apple_audiounit_recovery_count' "$audio_source"; then
    echo "Missing retained AudioUnit recovery counter export." >&2
    exit 1
fi

for invariant in \
    '.token = slot->token' \
    '.generation = slot->generation' \
    '.backend = slot->backend' \
    '.pts = slot->pts' \
    'double pip_pts = frame->current ? p->last_pts : 0.0' \
    'CFRetain(surface)' \
    'pl_tex_poll(p->gpu, tex' \
    'CFRelease(surface)' \
    'slot->state = APPLE_PIP_SLOT_CALLBACK' \
    'while (apple_pip_has_completion_work_locked(state))' \
    'state->inline_callback_pending = true' \
    'state->inline_callback_in_progress = true' \
    'state->inline_callback_generation == state->generation' \
    'inline_callback(inline_callback_ctx, &inline_frame)' \
    'mix.num_frames > 0' \
    'state->force_redraw_armed = false' \
    'bool new_restore = config->mode == MPV_APPLE_PIP_MODE_DUAL_OUTPUT_RESTORE' \
    's == APPLE_PIP_SLOT_IN_FLIGHT) && metal_ready' \
    'apple_pip_metal_target_blit' \
    'MPV_APPLE_PIP_CAP_ASYNC_METAL_BLIT' \
    'MPV_APPLE_PIP_CAP_INLINE_RESTORE_NOTIFICATION' \
    'MPV_APPLE_PIP_CAP_INLINE_FRESH_FRAME_NOTIFICATION' \
    'MPV_APPLE_PIP_MODE_INLINE_FRESH_FRAME' \
    'p->apple_pip_highest_seen_frame_id' \
    'frame_id <= state->inline_probe_baseline_frame_id' \
    'apple_pip_signal_inline_presented'
do
    if ! grep -Fq "$invariant" "$sink_source"; then
        echo "Missing native sink invariant: $invariant" >&2
        exit 1
    fi
done

fresh_probe_block="$(sed -n \
    '/if (fresh_inline)/,/} else if (effective_mode == MPV_APPLE_PIP_MODE_INLINE_ONLY)/p' \
    "$sink_source")"
if [[ -z "$fresh_probe_block" ]] ||
   grep -Fq 'force_redraw = true' <<<"$fresh_probe_block" ||
   grep -Fq 'vo->want_redraw = true' <<<"$fresh_probe_block" ||
   grep -Fq 'p->last_id' <<<"$fresh_probe_block"; then
    echo "Fresh-frame validation must use the monotonic VO frame fence without forcing redraw." >&2
    exit 1
fi

if ! grep -Fq 'if (buffer_count > (UInt32)MP_NUM_CHANNELS)' "$audio_source"; then
    echo "AudioUnit silence recovery must cap the AudioBufferList walk." >&2
    exit 1
fi

if grep -Fq 'apple_pip_has_queued_target' "$sink_source"; then
    echo "Queued targets must not create a self-sustaining redraw loop." >&2
    exit 1
fi

if sed -n \
    '/static void apple_pip_signal_inline_presented/,/static MP_THREAD_VOID apple_pip_completion_worker/p' \
    "$sink_source" | grep -Eq '(^|[^[:alnum:]_])callback\('; then
    echo "Inline restore callbacks must be queued to the completion worker." >&2
    exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Patch and retained definitions validated; Mach-O dlsym check requires macOS."
    exit 0
fi

compiler="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
include_directory="$temporary_root/mpv/include"

"$compiler" -isysroot "$sdk" -std=c11 -O2 -ffunction-sections -fdata-sections \
    -I"$include_directory" -c "$fixture_directory/apple_pip_abi.c" \
    -o "$temporary_root/apple_pip_abi.o"
/usr/bin/ar rcs "$temporary_root/libapple-pip-abi.a" "$temporary_root/apple_pip_abi.o"
"$compiler" -isysroot "$sdk" -std=c11 -O2 -Wl,-dead_strip \
    -I"$include_directory" "$fixture_directory/apple_pip_dlsym.c" \
    "$temporary_root/libapple-pip-abi.a" -o "$temporary_root/apple-pip-dlsym"

for symbol in \
    mpv_apple_pip_api_version \
    mpv_apple_pip_get_capabilities \
    mpv_apple_pip_set_callback \
    mpv_apple_pip_set_mode \
    mpv_apple_pip_submit_target \
    mpv_apple_pip_disable_and_drain \
    mpv_apple_audiounit_recovery_count
do
    if ! nm -gU "$temporary_root/apple-pip-dlsym" | grep -q " _$symbol$"; then
        echo "Symbol absent after static link and dead strip: $symbol" >&2
        exit 1
    fi
done

"$temporary_root/apple-pip-dlsym"

# Xcode's App Store export runs `strip -D` on the final app executable. Dynamic lookup symbols are
# allowed to disappear there because the shipped Swift wrapper uses this linker-visible weak
# bridge. Exercise the exact strip pass and prove that every provider still resolves and calls the
# underlying native functions afterward.
"$compiler" -isysroot "$sdk" -std=c11 -O2 -Wl,-dead_strip \
    -I"$include_directory" \
    -I"$repository_root/Sources/_MPVKit-GPL/include" \
    "$fixture_directory/apple_pip_bridge.c" \
    "$repository_root/Sources/_MPVKit-GPL/dummy.c" \
    "$temporary_root/libapple-pip-abi.a" \
    -o "$temporary_root/apple-pip-weak-bridge"

"$temporary_root/apple-pip-weak-bridge"
/usr/bin/strip -D "$temporary_root/apple-pip-weak-bridge"
"$temporary_root/apple-pip-weak-bridge"

echo "Apple PiP weak bridge survived the App Store strip -D pass."
