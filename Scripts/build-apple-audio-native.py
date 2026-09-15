import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
work = root / '.build/apple-spatial-native'
parser = argparse.ArgumentParser()
parser.add_argument('platform', choices=['ios', 'isimulator', 'tvos', 'tvsimulator', 'macos', 'maccatalyst'])
parser.add_argument('arch', choices=['arm64', 'arm64e', 'x86_64'])
args = parser.parse_args()
if args.arch == 'arm64e' and args.platform != 'tvos':
    parser.error('arm64e is only present in the current tvOS artifact')
if args.arch == 'x86_64' and args.platform in ['ios', 'tvos']:
    parser.error('Device artifacts do not contain x86_64')
variant = 'maccatalyst' if args.platform == 'maccatalyst' else ('simulator' if args.platform in ['isimulator', 'tvsimulator'] else None)
platform_name = 'ios' if args.platform in ['ios', 'isimulator', 'maccatalyst'] else ('tvos' if args.platform in ['tvos', 'tvsimulator'] else 'macos')
sdk_name = {'ios': 'iphoneos', 'isimulator': 'iphonesimulator', 'tvos': 'appletvos', 'tvsimulator': 'appletvsimulator', 'macos': 'macosx', 'maccatalyst': 'macosx'}[args.platform]
sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
version = {'ios': '15.0', 'tvos': '17.5', 'macos': '14.0'}[platform_name]
target = f'{args.arch}-apple-{platform_name}{version}' + ('-macabi' if variant == 'maccatalyst' else ('-simulator' if variant else ''))
prefix = work / f'deps-{args.platform}-{args.arch}'
(prefix / 'lib/pkgconfig').mkdir(parents=True, exist_ok=True)
(prefix / 'include').mkdir(exist_ok=True)
source = work / 'mpv-source'
patches = sorted((root / 'Sources/BuildScripts/patch/libmpv').glob('*.patch'))
expected = '\n'.join(p.name + ':' + base64.b64encode(p.read_bytes()).decode() for p in patches)
if not source.exists():
    baseline = root / 'dist/libmpv-v0.41.0'
    baseline_stamp = (baseline / '.mpvkit-patch-set').read_text()
    applied = next((index for index in range(len(patches) + 1) if '\n'.join(p.name + ':' + base64.b64encode(p.read_bytes()).decode() for p in patches[:index]) == baseline_stamp), None)
    if applied is None:
        raise RuntimeError('Baseline patch set is not a prefix of the reviewed patch set')
    shutil.copytree(baseline, source, ignore=shutil.ignore_patterns('.git'))
    for patch in patches[applied:]:
        subprocess.run(['git', 'apply', '--check', str(patch)], cwd=source, check=True)
        subprocess.run(['git', 'apply', str(patch)], cwd=source, check=True)
    (source / '.mpvkit-patch-set').write_text(expected)
if (source / '.mpvkit-patch-set').read_text() != expected:
    raise RuntimeError('Cached source does not match reviewed patch set')
source_copy = source
artifacts = {}
for location in [root / 'dist/release/xcframework', root / '.build/artifacts/mpvkit']:
    for artifact in location.rglob('*.xcframework'):
        if artifact.stem in artifacts:
            raise RuntimeError('Ambiguous artifact: ' + artifact.stem)
        artifacts[artifact.stem] = artifact
header_subdirs = {'Libplacebo': 'libplacebo', 'Libdovi': 'libdovi', 'nettle': 'nettle',
                  'gnutls': 'gnutls', 'Libbluray': 'libbluray'}
ffmpeg = ['Libavcodec', 'Libavdevice', 'Libavfilter', 'Libavformat', 'Libavutil', 'Libswresample', 'Libswscale']
header_subdirs.update({name: name.lower() for name in ffmpeg})
inputs = {}
for name, artifact in artifacts.items():
    if name in ['Libmpv', 'Libluajit']:
        continue
    info = plistlib.loads((artifact / 'Info.plist').read_bytes())
    matches = [item for item in info['AvailableLibraries']
               if item['SupportedPlatform'] == platform_name
               and item.get('SupportedPlatformVariant') == variant
               and args.arch in item['SupportedArchitectures']]
    if not matches and name == 'Libuavs3d' and args.platform == 'maccatalyst':
        continue
    if len(matches) != 1:
        raise RuntimeError('Missing exact platform architecture for ' + name)
    item = matches[0]
    library = artifact / item['LibraryIdentifier'] / item['LibraryPath']
    binary = library / name if library.suffix == '.framework' else library
    if not binary.is_file():
        raise RuntimeError('Missing binary: ' + str(binary))
    output_name = 'lib' + (name[3:].lower() if name.startswith('Lib') else name) + '.a'
    if name == 'MoltenVK':
        output_name = 'libMoltenVK.a'
    output = prefix / 'lib' / output_name
    if not output.exists():
        output.symlink_to(binary)
    header = library / 'Headers' if library.suffix == '.framework' else None
    if header and header.is_dir():
        destination = prefix / 'include' / header_subdirs.get(name, '')
        shutil.copytree(header, destination, dirs_exist_ok=True)
    inputs[name] = {'path': str(binary), 'sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
shutil.copytree(root / 'dist/vulkan/ios/thin/arm64/include', prefix / 'include', dirs_exist_ok=True)
versions = {}
for name in ffmpeg:
    hp = prefix / 'include' / name.lower()
    text = '\n'.join(p.read_text() for p in hp.glob('version*.h'))
    macro = name.upper()
    components = [re.search(r'#define\s+' + macro + r'_VERSION_' + component + r'\s+(\d+)', text).group(1)
                  for component in ['MAJOR', 'MINOR', 'MICRO']]
    versions[name.lower()] = '.'.join(components)
for pc in (root / 'dist').glob('*/ios/thin/arm64/lib/pkgconfig/*.pc'):
    if pc.name in ['mpv.pc', 'luajit.pc']:
        continue
    content = pc.read_text()
    content = re.sub(re.escape(str(root / 'dist')) + r'/[^/]+/ios/thin/arm64', str(prefix), content)
    if pc.parent.parent.parent.parent.parent.parent.name == 'FFmpeg':
        content = re.sub(r'(?m)^Version:.*$', 'Version: ' + versions[pc.stem], content)
        for name, version in versions.items():
            content = re.sub(r'(' + name + r'\s*>=\s*)[\d.]+', r'\g<1>' + version, content)
    if args.platform == 'maccatalyst':
        content = content.replace('-luavs3d ', '')
    (prefix / 'lib/pkgconfig' / pc.name).write_text(content)
(prefix / 'lib/pkgconfig/zlib.pc').write_text('Name: zlib\nDescription: Apple SDK zlib\nVersion: 1.3.1\nLibs: -lz\nCflags:\n')
(prefix / 'lib/pkgconfig/libxml-2.0.pc').write_text(f'Name: libXML\nDescription: Apple SDK XML\nVersion: 2.9.14\nLibs: -lxml2\nCflags: -I{sdk}/usr/include/libxml2\n')
flags = ['-arch', args.arch, '-isysroot', sdk, '-target', target, '-I' + str(prefix / 'include')]
link = ['-lc++', '-arch', args.arch, '-isysroot', sdk, '-target', target, '-L' + str(prefix / 'lib'), '-lgmp', '-lsmbclient']
if args.platform == 'maccatalyst':
    flags += ['-isystem', sdk + '/System/iOSSupport/usr/include', '-iframework', sdk + '/System/iOSSupport/System/Library/Frameworks']
    link += ['-iframework', sdk + '/System/iOSSupport/System/Library/Frameworks']
family = 'x86_64' if args.arch == 'x86_64' else 'aarch64'
cross = work / f'cross-{args.platform}-{args.arch}.meson'
lines = ["[binaries]", "c = '/usr/bin/clang'", "cpp = '/usr/bin/clang++'", "objc = '/usr/bin/clang'", "objcpp = '/usr/bin/clang++'", "ar = '/usr/bin/ar'", "strip = '/usr/bin/strip'", "pkg-config = '/opt/homebrew/bin/pkg-config'", '', '[properties]', 'has_function_printf = true', 'has_function_hfkerhisadf = false', '', '[host_machine]', "system = 'darwin'", "subsystem = '" + args.platform + "'", "kernel = 'xnu'", "cpu_family = '" + family + "'", "cpu = '" + args.arch + "'", "endian = 'little'", '', '[built-in options]', "default_library = 'static'", "buildtype = 'release'", "prefix = '" + str(work / f'installed-{args.platform}-{args.arch}') + "'"]
for language in ['c', 'cpp', 'objc', 'objcpp']:
    lines.append(language + '_args = ' + repr(flags))
    lines.append(language + '_link_args = ' + repr(link))
cross.write_text('\n'.join(lines) + '\n')
env = dict(os.environ)
env['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib/pkgconfig')
env['PKG_CONFIG_PATH'] = ''
build = work / f'build-{args.platform}-{args.arch}'
options = ['-Dlibmpv=true', '-Dgl=enabled', '-Dplain-gl=enabled', '-Diconv=enabled', '-Duchardet=enabled', '-Dvulkan=enabled', '-Dmoltenvk=enabled', '-Dios-sample-buffer=' + ('disabled' if platform_name == 'macos' else 'enabled'), '-Dapple-gpu-pip=enabled', '-Djavascript=disabled', '-Dzimg=disabled', '-Djpeg=disabled', '-Dvapoursynth=disabled', '-Drubberband=disabled', '-Dgpl=true', '-Dlibbluray=enabled', '-Dcplayer=false', '-Dvideotoolbox-gl=disabled', '-Dvideotoolbox-pl=enabled', '-Dswift-build=disabled', '-Daudiounit=' + ('disabled' if platform_name == 'macos' else 'enabled'), '-Davfoundation=enabled', '-Dcoreaudio=' + ('enabled' if platform_name == 'macos' else 'disabled'), '-Dlua=disabled', '-Dios-gl=' + ('disabled' if platform_name == 'macos' or args.platform == 'maccatalyst' else 'enabled'), '-Dcocoa=disabled', '-Dgl-cocoa=disabled']
setup = ['meson', 'setup', str(build), str(source_copy), '--cross-file', str(cross)] + options
if (build / 'build.ninja').exists():
    setup.insert(2, '--reconfigure')
subprocess.run(setup, env=env, check=True)
subprocess.run(['ninja', '-C', str(build), '-j4'], env=env, check=True)
binary = build / 'libmpv.a'
native_symbols = ['mpv_apple_pip_api_version', 'mpv_apple_pip_get_capabilities',
                  'mpv_apple_pip_set_callback', 'mpv_apple_pip_set_mode',
                  'mpv_apple_pip_submit_target', 'mpv_apple_pip_disable_and_drain',
                  'mpv_apple_audiounit_recovery_count']
symbols = subprocess.check_output(['nm', '-arch', args.arch, '-m', str(binary)], text=True)
if platform_name == 'macos':
    native_symbols = [symbol for symbol in native_symbols if 'audiounit' not in symbol]
for symbol in native_symbols:
    definitions = [line for line in symbols.splitlines()
                   if line.endswith('_' + symbol) and '(__TEXT,__text)' in line
                   and ' external ' in line and ' weak ' not in line]
    if len(definitions) != 1:
        raise RuntimeError('Missing strong native definition: ' + symbol)
(work / f'inputs-{args.platform}-{args.arch}.json').write_text(json.dumps({
    'target': target,
    'sdk': sdk,
    'patches_sha256': hashlib.sha256(expected.encode()).hexdigest(),
    'archive_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    'native_symbols': native_symbols,
    'inputs': inputs,
}, indent=2))
print('Prepared private native archive:', binary)
