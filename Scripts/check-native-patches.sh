#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patch_directory="$repository_root/Sources/BuildScripts/patch/libmpv"
temporary_root=""

cleanup() {
    if [[ -n "$temporary_root" ]]; then
        rm -rf "$temporary_root"
    fi
}
trap cleanup EXIT

if [[ -n "${MPV_SOURCE_DIR:-}" ]]; then
    source_directory="$(cd "$MPV_SOURCE_DIR" && pwd)"
else
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-native-patches.XXXXXX")"
    source_directory="$temporary_root/mpv"
    git clone --quiet --depth 1 --branch v0.41.0 https://github.com/mpv-player/mpv.git "$source_directory"
fi

worktree="$source_directory"
if [[ -n "${MPV_SOURCE_DIR:-}" ]]; then
    temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-native-patches.XXXXXX")"
    worktree="$temporary_root/mpv"
    git clone --quiet --no-local "$source_directory" "$worktree"
    git -C "$worktree" checkout --quiet v0.41.0
fi

while IFS= read -r patch; do
    git -C "$worktree" apply --check "$patch"
    git -C "$worktree" apply "$patch"
done < <(find "$patch_directory" -maxdepth 1 -type f -name '*.patch' -print | LC_ALL=C sort)

git -C "$worktree" diff --check

grep -Fq 'static bool audio_frame_matches_ao' "$worktree/audio/out/buffer.c"
grep -Fq 'mp_aframe_get_format(frame) != ao->format' "$worktree/audio/out/buffer.c"
grep -Fq 'mp_aframe_get_rate(frame) != ao->samplerate' "$worktree/audio/out/buffer.c"
grep -Fq 'mp_aframe_get_planes(frame) != ao->num_planes' "$worktree/audio/out/buffer.c"
grep -Fq 'mp_aframe_get_sstride(frame) != (size_t)ao->sstride' \
    "$worktree/audio/out/buffer.c"
grep -Fq '!mp_aframe_get_chmap(frame, &channels)' "$worktree/audio/out/buffer.c"
grep -Fq '!mp_chmap_equals(&channels, &ao->channels)' "$worktree/audio/out/buffer.c"
grep -Fq 'if (!data[n])' "$worktree/audio/out/buffer.c"
grep -Fq 'if (!audio_frame_matches_ao(ao, p->pending, fdata)) {' \
    "$worktree/audio/out/buffer.c"
grep -Fq 'TA_FREEP(&p->pending);' "$worktree/audio/out/buffer.c"
grep -Fq 'ao_request_reload(ao);' "$worktree/audio/out/buffer.c"

# `git apply` accepts extra added lines after an under-counted new-file hunk as trailing
# patch text. Guard the two generated Objective-C translation units explicitly so a malformed
# hunk cannot silently truncate their final cleanup/initializer lines again.
grep -Fq '*target_ptr = NULL;' "$worktree/video/out/apple_pip_metal.m"
grep -Fq '.uninit         = moltenvk_uninit,' "$worktree/video/out/vulkan/context_moltenvk.m"

# PiP target reuse must remain bounded by the public queue limit, retain the
# libplacebo fence poll before reuse, and clear only at the two drain barriers.
grep -Fq 'target_cache[APPLE_PIP_MAX_TARGETS]' "$worktree/video/out/vo_gpu_next.c"
grep -Fq 'if (needs_poll && pl_tex_poll' "$worktree/video/out/vo_gpu_next.c"
grep -Fq 'apple_pip_release_cached_target_locked(state, cache_entry);' \
    "$worktree/video/out/vo_gpu_next.c"
[[ "$(grep -Fc 'apple_pip_clear_target_cache_locked(p);' \
    "$worktree/video/out/vo_gpu_next.c")" -eq 2 ]]

iphone_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang \
    -fsyntax-only \
    -fobjc-arc \
    -x objective-c \
    -I"$worktree" \
    -isysroot "$iphone_sdk" \
    -target arm64-apple-ios14.0 \
    "$worktree/video/out/apple_pip_metal.m"

bash "$repository_root/Scripts/check-avfoundation-recovery.sh" "$worktree"

echo "All libmpv patches apply cleanly to mpv v0.41.0."
