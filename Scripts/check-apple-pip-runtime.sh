#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

platform_skip() {
    local message="$1"
    if [[ "${MPVKIT_NATIVE_RUNTIME_REQUIRED:-0}" == "1" ]]; then
        echo "FAIL(platform): $message" >&2
        exit 1
    fi
    echo "SKIP(platform): $message"
    exit 0
}

[[ "$(uname -s)" == "Darwin" ]] \
    || platform_skip "native Apple GPU-PiP runtime validation requires macOS"
[[ "$(uname -m)" == "arm64" ]] \
    || platform_skip "native Apple GPU-PiP runtime validation targets Apple Silicon only"
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" =~ ^[0-9]+$ && "$macos_major" -ge 12 ]] \
    || platform_skip "custom Apple GPU-PiP requires macOS 12 or newer"

artifacts_root="${MPVKIT_LOCAL_ARTIFACTS_DIR:-$repository_root/dist/release}"
if [[ "$artifacts_root" != /* ]]; then
    artifacts_root="$repository_root/$artifacts_root"
fi
if [[ ! -d "$artifacts_root" ]]; then
    echo "FAIL(artifact): local artifact directory not found: $artifacts_root" >&2
    exit 2
fi
artifacts_root="$(cd "$artifacts_root" && pwd)"
case "$artifacts_root" in
    "$repository_root"|"$repository_root"/*) ;;
    *)
        echo "FAIL(artifact): MPVKIT_LOCAL_ARTIFACTS_DIR must be inside the checkout" >&2
        exit 2
        ;;
esac

artifact=""
for candidate in \
    "$artifacts_root/xcframework/Libmpv.xcframework" \
    "$artifacts_root/Libmpv.xcframework" \
    "$artifacts_root/Libmpv-GPL.xcframework" \
    "$artifacts_root/Libmpv.xcframework.zip" \
    "$artifacts_root/Libmpv-GPL.xcframework.zip"
do
    if [[ -e "$candidate" ]]; then
        artifact="$candidate"
        break
    fi
done
if [[ -z "$artifact" ]]; then
    echo "FAIL(artifact): no local Libmpv XCFramework or zip found under $artifacts_root" >&2
    exit 2
fi

# Runtime execution is meaningful only after the slice/export audit passes. This also catches a
# partially copied XCFramework before SwiftPM spends time linking the complete dependency graph.
bash "$repository_root/Scripts/check-built-apple-symbols.sh" "$artifact"

scratch_root="${MPVKIT_NATIVE_RUNTIME_SCRATCH_DIR:-}"
remove_scratch=0
if [[ -z "$scratch_root" ]]; then
    scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/mpvkit-native-pip-runtime.XXXXXX")"
    remove_scratch=1
else
    mkdir -p "$scratch_root"
    scratch_root="$(cd "$scratch_root" && pwd)"
fi
cleanup() {
    if [[ "$remove_scratch" == "1" ]]; then
        rm -rf "$scratch_root"
    fi
}
trap cleanup EXIT

echo "Running native Apple GPU-PiP lifecycle against: $artifact"
MPVKIT_LOCAL_ARTIFACTS_DIR="$artifacts_root" \
    MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}" \
    swift run \
        --package-path "$repository_root" \
        --scratch-path "$scratch_root/build" \
        --configuration release \
        NativeApplePiPRuntimeHarness
