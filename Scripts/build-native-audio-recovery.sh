#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-${TMPDIR:-/tmp}/mpvkit-native-audio-recovery}"

python3 - "$repository_root" "$output_root" <<'PY'
import pathlib
import plistlib
import subprocess
import sys
import wave

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
artifacts = root / 'dist/release/xcframework'
coupled = ['Libmpv', 'Libavcodec', 'Libavdevice', 'Libavfilter', 'Libavformat',
           'Libavutil', 'Libswresample', 'Libswscale', 'Libplacebo', 'MoltenVK']
libraries = []
for name in coupled:
    artifact = artifacts / (name + '.xcframework')
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    candidates = [item for item in info['AvailableLibraries']
                  if item['SupportedPlatform'] == 'ios'
                  and item.get('SupportedPlatformVariant') == 'simulator'
                  and 'arm64' in item['SupportedArchitectures']]
    if len(candidates) != 1:
        raise RuntimeError('Missing unique simulator artifact: ' + name)
    item = candidates[0]
    library = artifact / item['LibraryIdentifier'] / item['LibraryPath']
    libraries.append(library / name if library.suffix == '.framework' else library)
if any(marker not in libraries[0].read_bytes() for marker in [
        b'requesting synchronized audio output recovery',
        b'preserving playback position during AVFoundation recovery']):
    raise RuntimeError('The selected Libmpv artifact does not contain the recovery patch')

dependencies = {
    'openssl': ['ssl', 'crypto'], 'libass': ['ass'], 'libfreetype': ['freetype'],
    'libfribidi': ['fribidi'], 'libharfbuzz': ['harfbuzz'],
    'libshaderc': ['shaderc_combined'], 'lcms2': ['lcms2'], 'libdovi': ['dovi'],
    'libunibreak': ['unibreak'], 'libsmbclient': ['smbclient'], 'gmp': ['gmp'],
    'nettle': ['nettle', 'hogweed'], 'gnutls': ['gnutls'], 'libdav1d': ['dav1d'],
    'libuavs3d': ['uavs3d'], 'libuchardet': ['uchardet'], 'libbluray': ['bluray'],
}
for directory, names in dependencies.items():
    libraries.extend(root / 'dist' / directory / 'isimulator/thin/arm64/lib' / ('lib' + name + '.a')
                     for name in names)
for library in libraries:
    if not library.is_file():
        raise RuntimeError('Missing cached dependency: ' + str(library))

sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
executable = output / 'NativeAudioRecovery'
command = ['xcrun', '--sdk', 'iphonesimulator', 'clang', '-target', 'arm64-apple-ios15.0-simulator',
           '-isysroot', sdk, '-fno-objc-arc', '-fblocks',
           '-I' + str(root / 'dist/libmpv/isimulator/thin/arm64/include'),
           str(root / 'Tests/NativeAudioRecovery/main.m'), *map(str, libraries)]
for framework in ['UIKit', 'Foundation', 'AVFoundation', 'AudioToolbox', 'CoreAudio',
                  'CoreVideo', 'CoreFoundation', 'CoreMedia', 'Metal', 'VideoToolbox',
                  'QuartzCore', 'IOSurface', 'CoreText', 'OpenGLES', 'GLKit', 'Security',
                  'CoreGraphics']:
    command.extend(['-framework', framework])
command.extend(['-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2', '-lz', '-lc++',
                '-o', str(executable)])
subprocess.run(command, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(executable)], check=True)
fixture = output / 'silence.wav'
with wave.open(str(fixture), 'wb') as audio:
    audio.setnchannels(2)
    audio.setsampwidth(2)
    audio.setframerate(48000)
    audio.writeframes(bytes(48000 * 4 * 30))
print('Built actual patched iOS Simulator libmpv audio harness: ' + str(executable))
print('Fixture: ' + str(fixture))
PY
