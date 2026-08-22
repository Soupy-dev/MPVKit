#!/bin/zsh
# Rebuilds the Libplacebo.xcframework slices in dist/release/xcframework from
# libplacebo v7.360.1 plus the patches in Sources/BuildScripts/patch/libplacebo,
# with -Dxxhash=enabled and -Db_ndebug=true on top of the upstream
# mpvkit/libplacebo-build configuration (which builds with xxhash disabled and
# asserts compiled in).
#
# The deferred-submission patch (0001) batches per-render-pass vkQueueSubmit2
# calls into one submission per flush point when PL_VK_DEFER_SUBMITS=1 is set
# in the environment; MPVKitSampleBuffer sets that variable on MoltenVK before
# creating the mpv handle. Measured on the iOS simulator against the stock
# binary this cut whole-process playback CPU with the ArtCNN upscaler active
# by ~22% (29.7% -> 23.2% of one core, 480p/24fps test asset) and FSR 1 by
# ~14%; the xxhash build flag additionally removed the per-frame shader-text
# hashing hotspot (pl_mem_hash) from profiles entirely.
#
# Prerequisites:
#   - a full dist/ tree from a prior `make gpl` style build (this script reuses
#     the per-platform cross files under dist/libmpv/*/scratch/*/crossFile.meson
#     and the dependency pkgconfig prefixes under dist/<lib>/<platform>/thin)
#   - meson + ninja (brew), python3 with jinja2 importable
#   - an unpacked Libplacebo.xcframework at dist/release/xcframework (copy the
#     upstream artifact there first; this script replaces slice binaries only)
#
# Slices rebuilt: ios-arm64, ios simulator arm64, tvos arm64+arm64e, tvos
# simulator arm64. x86_64 simulator slices keep the upstream binaries (the
# patch is opt-in at runtime, so mixed slices only mean the optimization is
# absent there). Catalyst/macOS/visionOS slices are left untouched.

set -euo pipefail

MPVKIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$MPVKIT_ROOT/dist"
FW="$DIST/release/xcframework/Libplacebo.xcframework"
WORK="${LIBPLACEBO_WORK_DIR:-$MPVKIT_ROOT/.build/libplacebo-local}"
SRC="$WORK/libplacebo"

if [ ! -d "$FW" ]; then
  echo "error: $FW not found; unpack the upstream Libplacebo.xcframework there first" >&2
  exit 1
fi

mkdir -p "$WORK"

if [ ! -d "$SRC" ]; then
  git clone --branch v7.360.1 --depth 1 https://github.com/haasn/libplacebo.git "$SRC"
  (cd "$SRC" && git submodule update --init --recursive)
  for p in "$MPVKIT_ROOT"/Sources/BuildScripts/patch/libplacebo/*.patch; do
    (cd "$SRC" && git apply "$p")
  done
fi

XXHASH_PREFIX="$WORK/xxhash-prefix"
if [ ! -f "$XXHASH_PREFIX/include/xxhash.h" ]; then
  mkdir -p "$XXHASH_PREFIX/include" "$XXHASH_PREFIX/lib/pkgconfig"
  curl -sL https://raw.githubusercontent.com/Cyan4973/xxHash/v0.8.3/xxhash.h \
    -o "$XXHASH_PREFIX/include/xxhash.h"
  cat > "$XXHASH_PREFIX/lib/pkgconfig/libxxhash.pc" <<EOF
prefix=$XXHASH_PREFIX
includedir=\${prefix}/include

Name: libxxhash
Description: xxHash header-only
Version: 0.8.3
Cflags: -I\${includedir}
Libs:
EOF
fi

build_slice() {
  local platform=$1
  local arch=$2
  local outdir="$WORK/build-$platform-$arch"
  local cross="$WORK/crossFile-$platform-$arch.meson"

  sed -e "s|prefix = .*|prefix = '$WORK/out-$platform-$arch'|" \
    "$DIST/libmpv/$platform/scratch/arm64/crossFile.meson" > "$cross"
  if [ "$arch" = "arm64e" ]; then
    sed -i '' -e "s|'-arch', 'arm64'|'-arch', 'arm64e'|g" \
      -e "s|arm64-apple|arm64e-apple|g" \
      -e "s|^cpu = 'arm64'|cpu = 'arm64e'|" "$cross"
  fi
  grep -q b_ndebug "$cross" || sed -i '' \
    -e "s|buildtype = 'release'|buildtype = 'release'\nb_ndebug = 'true'|" "$cross"

  export PKG_CONFIG_LIBDIR="$DIST/libshaderc/$platform/thin/arm64/lib/pkgconfig:$DIST/lcms2/$platform/thin/arm64/lib/pkgconfig:$DIST/libdovi/$platform/thin/arm64/lib/pkgconfig:$DIST/vulkan/$platform/thin/arm64/lib/pkgconfig:$XXHASH_PREFIX/lib/pkgconfig:$DIST/pkgconfig/apple-sdk/${platform/isimulator/ios}"

  rm -rf "$outdir"
  (cd "$SRC" && meson setup "$outdir" --cross-file "$cross" \
    -Dopengl=enabled -Dvulkan=enabled -Dshaderc=enabled -Dlcms=enabled \
    -Dxxhash=enabled -Dunwind=disabled -Dglslang=disabled -Dd3d11=disabled \
    -Ddemos=false -Dtests=false -Ddovi=enabled -Dlibdovi=enabled)
  ninja -C "$outdir"
  echo "built $platform-$arch"
}

build_slice ios arm64
build_slice isimulator arm64
build_slice tvos arm64
build_slice tvos arm64e
build_slice tvsimulator arm64

replace_binary() {
  local slice=$1
  shift
  local bin="$FW/$slice/Libplacebo.framework/Libplacebo"
  cp "$bin" "$bin.orig-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  lipo -create "$@" -output "$bin"
  lipo -info "$bin"
}

keep_arch() {
  local slice=$1
  local arch=$2
  local out=$3
  lipo -thin "$arch" "$FW/$slice/Libplacebo.framework/Libplacebo" -output "$out"
}

keep_arch ios-arm64_x86_64-simulator x86_64 "$WORK/isim-x86.a" || true
keep_arch tvos-arm64_x86_64-simulator x86_64 "$WORK/tvsim-x86.a" || true

replace_binary ios-arm64 "$WORK/build-ios-arm64/src/libplacebo.a"
replace_binary ios-arm64_x86_64-simulator "$WORK/isim-x86.a" "$WORK/build-isimulator-arm64/src/libplacebo.a"
replace_binary tvos-arm64_arm64e "$WORK/build-tvos-arm64/src/libplacebo.a" "$WORK/build-tvos-arm64e/src/libplacebo.a"
replace_binary tvos-arm64_x86_64-simulator "$WORK/tvsim-x86.a" "$WORK/build-tvsimulator-arm64/src/libplacebo.a"

echo "done; touch Package.swift and clear the SwiftPM manifest cache so Xcode picks up the local artifact"
