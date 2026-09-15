import argparse
from pathlib import Path
import plistlib
import subprocess
import struct
import math

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('fixture', type=Path)
parser.add_argument('--source', type=Path, default=root / '.build/apple-spatial-native/mpv-source')
parser.add_argument('--archive', type=Path, default=root / '.build/apple-spatial-native/build-macos-arm64/libmpv.a')
parser.add_argument('--output', type=Path, default=root / '.build/apple-audio-validation')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
frameworks = ['AVFoundation', 'AudioToolbox', 'CoreAudio', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'Foundation', 'IOSurface', 'Metal', 'QuartzCore', 'VideoToolbox', 'AppKit', 'OpenGL', 'Carbon', 'IOKit', 'CoreServices', 'Security', 'SystemConfiguration', 'UniformTypeIdentifiers', 'DiskArbitration']
link = [str(args.archive)]
include = ['-I' + str(args.source), '-I' + str(args.source / 'include')]
seen = set()
for location in [root / 'dist/release/xcframework', root / '.build/artifacts/mpvkit']:
    for artifact in sorted(location.rglob('*.xcframework')):
        name = artifact.stem
        if name == 'Libmpv':
            continue
        if name in seen:
            raise RuntimeError('Ambiguous artifact: ' + name)
        seen.add(name)
        info = plistlib.loads((artifact / 'Info.plist').read_bytes())
        choices = [x for x in info['AvailableLibraries'] if x['SupportedPlatform'] == 'macos' and 'arm64' in x['SupportedArchitectures']]
        if len(choices) != 1:
            raise RuntimeError('Missing exact Mac artifact: ' + name)
        item = choices[0]
        library = artifact / item['LibraryIdentifier'] / item['LibraryPath']
        if library.suffix == '.framework':
            include += ['-F' + str(library.parent)]
            link += ['-F', str(library.parent), '-framework', name]
        else:
            link.append(str(library))
for framework in frameworks:
    link += ['-framework', framework]
link += ['-lz', '-lbz2', '-liconv', '-lexpat', '-lresolv', '-lxml2', '-lc++']
include += ['-I' + str(root / '.build/apple-spatial-native/deps-macos-arm64/include')]
bundle = args.output / 'AudioHarness.app/Contents'
(bundle / 'MacOS').mkdir(parents=True, exist_ok=True)
(bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.Eclipse.AudioHarness', 'CFBundleExecutable': 'AudioHarness', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
for test in ['packets', 'playback']:
    obj = args.output / (test + '.o')
    binary = args.output / test if test == 'packets' else bundle / 'MacOS/AudioHarness'
    with (args.output / (test + '-build.log')).open('w') as log:
        subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos14.0', '-fno-objc-arc', '-fblocks', '-fsanitize=address'] + include + ['-c', str(root / 'Tests/NativeAppleAudio' / (test + '.m')), '-o', str(obj)], check=True, stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macosx14.0', '-sanitize=address', str(obj), '-o', str(binary)] + link, check=True, stdout=log, stderr=subprocess.STDOUT)
    with (args.output / (test + '.log')).open('w') as log:
        subprocess.run([str(binary), str(args.fixture.resolve())], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=45)
    print('PASS', test, flush=True)
rate = 48000
channels = 6
frames = rate * 12
samples = bytearray()
for frame in range(frames):
    for channel in range(channels):
        samples += struct.pack('<h', int(math.sin(frame * 2 * math.pi * (300 + channel * 100) / rate) * 100))
fmt = struct.pack('<HHIIHHHHI', 0xfffe, channels, rate, rate * channels * 2, channels * 2, 16, 22, 16, 0x3f) + bytes.fromhex('0100000000001000800000aa00389b71')
data = b'fmt ' + struct.pack('<I', len(fmt)) + fmt + b'data' + struct.pack('<I', len(samples)) + samples
wav = args.output / 'pcm-5.1.wav'
wav.write_bytes(b'RIFF' + struct.pack('<I', len(data) + 4) + b'WAVE' + data)
with (args.output / 'pcm-playback.log').open('w') as log:
    subprocess.run([str(bundle / 'MacOS/AudioHarness'), str(wav), 'pcm'], check=True, stdout=log, stderr=subprocess.STDOUT, timeout=45)
print('PASS multichannel PCM playback', flush=True)
