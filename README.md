# MPVKit

[![mpv](https://img.shields.io/badge/mpv-v0.41.0-blue.svg)](https://github.com/mpv-player/mpv)
[![ffmpeg](https://img.shields.io/badge/ffmpeg-n8.1.2-blue.svg)](https://github.com/FFmpeg/FFmpeg)
[![license](https://img.shields.io/github/license/mpvkit/MPVKit)](https://github.com/mpvkit/MPVKit/main/LICENSE)

> MPVKit is only suitable for learning `libmpv` and will not be maintained too frequently.

`MPVKit` is a collection of tools to use `mpv` in `iOS`, `macOS`, `tvOS` applications.

It includes scripts to build `mpv` native libraries.

Forked from [kingslay/FFmpegKit](https://github.com/kingslay/FFmpegKit)

## About Metal support

Metal support only a patch version ([#7857](https://github.com/mpv-player/mpv/pull/7857)) and does not officially support it yet. Encountering any issues is not strange. 

## Apple GPU and sample-buffer renderers

The `MPVKitSampleBuffer` and `MPVKitSampleBuffer-GPL` products expose two
`@MainActor` renderers. They are also included in the corresponding `MPVKit`
products. Renderer callbacks are delivered on the main actor.

| Renderer | Intended use |
|---|---|
| `MPVGPUPlayerRenderer` | Preferred inline renderer. It uses mpv `gpu-next`, Vulkan, libplacebo, MoltenVK, and a `CAMetalLayer`; its default PiP policy first attempts the same mpv session's native GPU output. |
| `MPVMetalSampleBufferRenderer` | Standalone sample-buffer renderer and hardened compatibility bridge. It renders into bounded IOSurface-backed buffers and feeds an `AVSampleBufferDisplayLayer`. |

Inline playback is available on iOS/tvOS 14 or newer and Apple Silicon macOS
11 or newer. Custom sample-buffer PiP is runtime-gated to iOS/tvOS 15 and
macOS 12. The new macOS renderer is arm64-only; Intel uses the unsupported stub.
MPVKit owns frame production, clocks, readiness, and safe teardown. The host
continues to own `AVPictureInPictureController`, scene and window policy,
remote-command policy, and application lifecycle decisions.

### Single-session GPU PiP

`MPVGPUPlayerRendererOptions.pictureInPictureBackendPreference` accepts:

| Preference | Behavior |
|---|---|
| `.automatic` | Default. Attempts the native one-session GPU sink once for each load, then latches the video-only compatibility bridge if the runtime probe or first-frame preparation fails. An active native failure receives at most one compatibility failover attempt. |
| `.singleSessionGPU` | Strict one-session mode. Preparation fails instead of reopening the media when the native sink is unavailable. |
| `.compatibilityDualSession` | Always uses the second, video-only mpv instance. The primary instance remains authoritative for audio, position, pause, speed, and commands. |

The native sink receives the final `gpu-next`/libplacebo image after subtitles
and OSD composition. It can render while a background `CAMetalLayer` has no
drawable, and it returns the exact frame PTS only after GPU completion. This
fork's native patch prefers direct Vulkan/libplacebo rendering into a
three-buffer IOSurface pool. When direct import is unavailable, it renders to
an exportable offscreen texture and completes an asynchronous Metal blit into
the IOSurface before releasing the exact PTS and generation. If neither runtime
probe succeeds, `.automatic` latches the compatibility bridge for that load.

The compatibility instance is muted and video-only, but it must open the URL a
second time. Use `.singleSessionGPU` when a signed, one-shot, or live source
must never be reopened. The bridge disables primary video only after its first
valid frame and waits for the restored primary output before destroying the
second instance. Backend selection never oscillates within one media load.

Use `inlineLayer` for the on-screen player and
`pictureInPictureDisplayLayer` for AVKit's sample-buffer content source:

```swift
@MainActor
func configurePlayback(url: URL) async throws {
    let renderer = MPVGPUPlayerRenderer(
        options: .init(pictureInPictureBackendPreference: .automatic)
    )
    try renderer.start()
    renderer.load(url)

    // Await this before asking AVKit to start PiP. It completes only after a
    // valid frame from the current load generation has been enqueued.
    try await renderer.preparePictureInPicture()

    // The host now asks its AVPictureInPictureController to start. Forward
    // AVKit's didStart callback only after AVKit has completed the handoff.
    renderer.beginPictureInPicture()

    // Forward AVKit's didTransitionToRenderSize value when it changes.
    renderer.updatePictureInPictureRenderSize(CGSize(width: 1280, height: 720))

    // Forward AVKit's didStop callback and its restoration decision.
    renderer.endPictureInPicture(restoringInlinePlayback: true)

    // stop() is nonblocking and idempotent. Await the drain before reuse.
    renderer.stop()
    await renderer.waitUntilStopped()
}
```

`MPVPictureInPictureState` reports `.idle`, generation-scoped `.preparing`,
`.ready`, `.active`, `.restoring`, and `.failed` states. Hosts should use
`onPictureInPictureStateChange` instead of watchdog/priming bursts. After a
PiP pause, speed change, duration change, or seek, invalidate the host-owned
AVKit playback state; `waitForPictureInPictureTimelineUpdate()` can be used to
wait until the renderer/timebase update is installed before completing a skip
command. A new load supersedes old preparation, frame, flush, and GPU callbacks.

`prepareForPictureInPictureStart(primeFrameCount:)`,
`primePictureInPictureFrames(reason:count:)`, and the standalone renderer's
`primeFrames(reason:count:)` remain for source compatibility but are deprecated.
Their counts are bounded to a coalesced immediate attempt plus one retry. New
code should await `preparePictureInPicture()`.

`MPVGPUPlayerRendererOptions` also controls the three-buffer capacity, the
one-second default preparation timeout, PiP frame size/FPS, inline drawable
pixel cap, and resize debounce interval. `updateInlineLayerLayout` updates the
visible layer immediately while coalescing expensive drawable resizes. Invalid
or non-finite sizes are ignored, and a zero-sized detachment keeps the last
valid drawable.

Hosts that require hardware-only decoding should pass
`additionalMPVOptions["hwdec-software-fallback"] = "no"`. MPVKit applies that
policy to both the primary gpu-next handle and the compatibility dual-session
PiP handle; the standalone compatibility renderer otherwise keeps its
source-compatible software-fallback default.

Diagnostics expose the requested and selected PiP backend, fallback reason,
active mpv instance count, preparation generation/latency, resize requests and
coalescing, scheduler coalescing, display backpressure, pool exhaustion, stale
generation drops, in-flight GPU buffers, GPU latency, timeline epoch/rate, and
AudioUnit recovery count. Stream codec, size, FPS, HDR tags, pixel format, and
hardware-decoder details are included as well. The actual backend is reported
as `.singleSessionGPUDirectIOSurface`,
`.singleSessionGPUAsynchronousMetalBlit`, or `.compatibilityDualSession`.

### HDR behavior and the compatibility renderer

Inline `gpu-next` playback retains its native color pipeline. EDR layer hinting
is opt-in through `enablesTargetColorspaceHint` and is enabled only when the
loaded stream is actually tagged as HDR. Single-session GPU PiP intentionally
targets predictable SDR BT.709/sRGB BGRA8, so libplacebo tone-maps HDR before
the frame reaches AVKit.

When used directly, `MPVMetalSampleBufferRenderer` keeps its standalone HDR
path: libmpv renders a high-bit-depth source, Metal converts it asynchronously
into an RGBA16F IOSurface-backed pixel buffer, and CoreVideo color metadata is
attached. Conversion failures preserve the last good frame and fall back to
tagged SDR. Its diagnostics report the active presentation backend
(`metalHighBitDepthHDRIOSurface`, `metalHDRIOSurface`, `metalIOSurface`, or
`softwareIOSurface`), formats, color tags, frame counts, failures, timeline,
backpressure, and pool usage.

Both renderers use demand-driven scheduling, bounded allocation, asynchronous
GPU completion, and asynchronous teardown. `start()` rejects reuse while the
renderer is `.stopping`; call `waitUntilStopped()` before restarting it.

The iOS, tvOS, and macOS demos exercise the renderer API. Simulator builds are
useful for compile and state-flow validation, but PiP black-frame, timing, HDR,
thermal, and long-run acceptance require physical devices.

After building Apple-platform artifacts, an Apple Silicon Mac can exercise the
native sink itself against the local Libmpv rather than only checking exported
symbols. The harness creates one real mpv handle, plays a deterministic local
H.264 fixture through gpu-next/MoltenVK, validates all four output modes and
generation-scoped IOSurface callbacks, then verifies `disable_and_drain` has no
late callback:

```bash
MPVKIT_LOCAL_ARTIFACTS_DIR=dist/release \
  MPVKIT_NATIVE_RUNTIME_REQUIRED=1 \
  bash Scripts/check-apple-pip-runtime.sh
```

Unsupported hosts print `SKIP(platform)` unless the required flag is set;
missing or incomplete artifacts and runtime failures always fail distinctly.

## Installation

### Swift Package Manager

```
https://github.com/mpvkit/MPVKit.git
```

### Choose which version

| Version | License | Note |
|---|---|---|
| MPVKit | LGPL | [FFmpeg details](https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md) , [mpv details](https://github.com/mpv-player/mpv/blob/master/Copyright) |
| MPVKit-GPL | GPL | Support samba protocol, same as old MPVKit version |


## How to build

```bash
make build
# specified platforms (ios,macos,tvos,tvsimulator,isimulator,maccatalyst,xros,xrsimulator)
make build platform=ios,macos
# build GPL version
make build enable-gpl
# clean all build temp files and cache
make clean
# see help
make help
```

## Make demo app using the local build version

On a fresh manifest evaluation, `dist/release` is selected automatically only
when it contains the complete coupled libmpv, MoltenVK, libplacebo, and FFmpeg
runtime for Eclipse's active iOS, tvOS, and macOS-harness matrix. SwiftPM's
shared manifest cache does not watch generated artifact contents, however, so
deterministic build and archive commands should explicitly set
`MPVKIT_LOCAL_ARTIFACTS_DIR`. Source-only manifest evaluations continue using
the versioned remote artifacts.

Set `MPVKIT_LOCAL_ARTIFACTS_DIR` to explicitly select a different relative or
absolute directory inside this checkout. The manifest looks both in that
directory and its `xcframework/` child for the ten required unpacked
`.xcframework` directories. ZIP-only roots are rejected. Every required
artifact must expose the complete active slice/architecture matrix; a missing,
partial, or ambiguous coupled runtime fails manifest evaluation instead of
mixing private local binaries with versioned remote binaries.

Local files use the unsuffixed names emitted by `make build enable-gpl`, such as
`Libmpv.xcframework` and `Libavcodec.xcframework`. GPL binary targets are bound
to those exact validated paths. Unrelated binary targets not in the coupled
runtime set continue using their versioned remote artifacts.

A locally backported MoltenVK imported-texture residency fix is recognized only
when both `MoltenVK.xcframework` and the provenance marker
`MoltenVK.imported-mtltexture-residency-fix` exist under the selected artifact
root. Without that marker, MPVKit keeps Metal argument buffers disabled to avoid
the MoltenVK 1.4.1 asynchronous PiP device-loss path.

```bash
export MPVKIT_LOCAL_ARTIFACTS_DIR=dist/release
xcodebuild -resolvePackageDependencies # or build a demo/Eclipse normally
```

The directory must resolve inside this MPVKit checkout because SwiftPM local
binary target paths are package-relative. The variable affects manifest
evaluation, so it must be present in the environment that launches
`xcodebuild` or resolves the package. To verify the release URL/checksum path in
a checkout that has `dist/release`, temporarily move that runtime out of the
package directory as well as unsetting the variable.

## Run default mpv player

```bash
./mpv.sh --input-commands='script-message display-stats-toggle' [url]
./mpv.sh --list-options
```

> Use <kbd>Shift</kbd>+<kbd>i</kbd> to show stats overlay

## Related Projects

* [moltenvk-build](https://github.com/mpvkit/moltenvk-build)
* [libplacebo-build](https://github.com/mpvkit/libplacebo-build)
* [libdovi-build](https://github.com/mpvkit/libdovi-build)
* [libshaderc-build](https://github.com/mpvkit/libshaderc-build)
* [libluajit-build](https://github.com/mpvkit/libluajit-build)
* [libass-build](https://github.com/mpvkit/libass-build)
* [libbluray-build](https://github.com/mpvkit/libbluray-build)
* [libsmbclient-build](https://github.com/mpvkit/libsmbclient-build)
* [gnutls-build](https://github.com/mpvkit/gnutls-build)
* [openssl-build](https://github.com/mpvkit/openssl-build)

## Donation

If you appreciate my current work, you can buy me a cup of coffee ☕️.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/C0C410P7UN)

## License

`MPVKit` source alone is licensed under the LGPL v3.0.

`MPVKit` bundles (`frameworks`, `xcframeworks`), which include both `libmpv` and `FFmpeg` libraries, are also licensed under the LGPL v3.0. However, if the source code is built using the optional `enable-gpl` flag or prebuilt binaries with `-GPL` postfix are used, then `MPVKit` bundles become subject to the GPL v3.0.
