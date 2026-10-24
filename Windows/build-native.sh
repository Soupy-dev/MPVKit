set -euo pipefail
root="$(cygpath -u "$1")"
jobs="$2"
ffmpeg_commit="$3"
cd "$root"
prefix="$root/.local/ffmpeg-prefix"
export PKG_CONFIG_PATH="$(cygpath -m "$prefix/lib/pkgconfig");$(cygpath -m /ucrt64/lib/pkgconfig);$(cygpath -m /ucrt64/share/pkgconfig)"
export PATH="$prefix/bin:$PATH"
ffmpeg_arguments=(--target-os=mingw32 --arch=x86_64 --cc=gcc --cxx=g++ --enable-shared
    --disable-static --disable-autodetect --enable-d3d11va --enable-dxva2 --enable-mediafoundation
    --enable-schannel --enable-version3 --enable-libdav1d --enable-libass --enable-libxml2 --enable-zlib
    --disable-doc --disable-debug --disable-ffplay --disable-avdevice)
identity="$( { printf '%s\n' "$ffmpeg_commit" "$prefix" "${ffmpeg_arguments[@]}"; gcc -dumpfullversion -dumpversion; pacman -Q; } | sha256sum | cut -d' ' -f1)"
if [[ ! -f "$prefix/bin/avcodec-62.dll" || ! -f "$prefix/build-identity" || "$(cat "$prefix/build-identity")" != "$identity" ]]; then
    cd "$root/.local/upstream/ffmpeg"
    if [[ -f ffbuild/config.mak ]]; then make distclean; fi
    ./configure --prefix="$(cygpath -m "$prefix")" "${ffmpeg_arguments[@]}"
    make -j"$jobs"
    make install
    printf '%s' "$identity" > "$prefix/build-identity"
fi
for pc in "$prefix"/lib/pkgconfig/*.pc; do
    sed -i 's|^prefix=.*|prefix=${pcfiledir}/../..|;s|^libdir=.*|libdir=${prefix}/lib|;s|^includedir=.*|includedir=${prefix}/include|' "$pc"
done
[[ "$(pkg-config --modversion libavcodec)" == 62.* ]] || { echo 'The pinned FFmpeg pkg-config path was not selected.' >&2; exit 1; }
cd "$root"
arguments=(--buildtype=release --default-library=shared --auto-features=disabled
    "-Dpkg_config_path=['$(cygpath -m "$prefix/lib/pkgconfig")']"
    -Dlibmpv=true -Dcplayer=true -Dgpl=false -Dbuild-date=false
    -Dd3d11=enabled -Dd3d-hwaccel=enabled -Dwasapi=enabled -Dwin32-threads=enabled
    -Dshaderc=enabled -Dspirv-cross=enabled -Dvulkan=enabled -Dlcms2=enabled
    -Dlibarchive=enabled -Dlibbluray=enabled -Diconv=enabled -Duchardet=enabled -Dlua=luajit
    -Dgl=disabled -Dlibavdevice=disabled -Dtests=false)
if [[ -f .local/native-build/meson-private/coredata.dat ]]; then
    meson setup --reconfigure --clearcache .local/native-build .local/upstream/mpv "${arguments[@]}"
else
    meson setup .local/native-build .local/upstream/mpv "${arguments[@]}"
fi
meson compile -C .local/native-build -j "$jobs"
meson introspect --dependencies .local/native-build > .local/native-dependencies.json
python3 -c 'import json; d=json.load(open(".local/native-dependencies.json")); assert any(x["name"] == "libavcodec" and x["version"].startswith("62.") for x in d), "mpv did not link the pinned FFmpeg"'
gcc -O2 -std=c17 -Wall -Wextra -Werror -shared Windows/native/windows.c -o .local/native-build/mpvkit-windows.dll -ldxgi -ldxguid -lole32
pacman -Q > .local/native-packages.txt
