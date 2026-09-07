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
work = root / '.build/tvos-native-local'
parser = argparse.ArgumentParser()
parser.add_argument('platform', choices=['tvos', 'tvsimulator'])
parser.add_argument('arch', choices=['arm64', 'arm64e', 'x86_64'])
args = parser.parse_args()
variant = 'simulator' if args.platform == 'tvsimulator' else None
sdk_name = 'appletvsimulator' if variant else 'appletvos'
sdk = subprocess.check_output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'], text=True).strip()
target = f'{args.arch}-apple-tvos17.5' + ('-simulator' if variant else '')
prefix = work / f'deps-{args.platform}-{args.arch}'
(prefix / 'lib/pkgconfig').mkdir(parents=True, exist_ok=True)
(prefix / 'include').mkdir(exist_ok=True)
source = root / 'dist/libmpv-v0.41.0'
patches = sorted((root / 'Sources/BuildScripts/patch/libmpv').glob('*.patch'))
expected = '\n'.join(p.name + ':' + base64.b64encode(p.read_bytes()).decode() for p in patches)
if (source / '.mpvkit-patch-set').read_text() != expected:
    raise RuntimeError('Cached source does not match reviewed patch set')
source_copy = work / 'mpv-source'
if not source_copy.exists():
    shutil.copytree(source, source_copy, ignore=shutil.ignore_patterns('.git'))
if (source_copy / '.mpvkit-patch-set').read_text() != expected:
    raise RuntimeError('Isolated source does not match reviewed patch set')
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
               if item['SupportedPlatform'] == 'tvos'
               and item.get('SupportedPlatformVariant') == variant
               and args.arch in item['SupportedArchitectures']]
    if len(matches) != 1:
        raise RuntimeError('Missing exact tvOS architecture for ' + name)
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
    (prefix / 'lib/pkgconfig' / pc.name).write_text(content)
(prefix / 'lib/pkgconfig/zlib.pc').write_text('Name: zlib\nDescription: Apple SDK zlib\nVersion: 1.3.1\nLibs: -lz\nCflags:\n')
(prefix / 'lib/pkgconfig/libxml-2.0.pc').write_text(f'Name: libXML\nDescription: Apple SDK XML\nVersion: 2.9.14\nLibs: -lxml2\nCflags: -I{sdk}/usr/include/libxml2\n')
flags = ['-arch', args.arch, '-isysroot', sdk, '-target', target, '-I' + str(prefix / 'include')]
link = ['-lc++', '-arch', args.arch, '-isysroot', sdk, '-target', target, '-L' + str(prefix / 'lib'), '-lgmp', '-lsmbclient']
family = 'x86_64' if args.arch == 'x86_64' else 'aarch64'
cross = work / f'cross-{args.platform}-{args.arch}.meson'
lines = ["[binaries]", "c = '/usr/bin/clang'", "cpp = '/usr/bin/clang++'", "objc = '/usr/bin/clang'", "objcpp = '/usr/bin/clang++'", "ar = '/usr/bin/ar'", "strip = '/usr/bin/strip'", "pkg-config = '/opt/homebrew/bin/pkg-config'", '', '[properties]', 'has_function_printf = true', 'has_function_hfkerhisadf = false', '', '[host_machine]', "system = 'darwin'", "subsystem = '" + ('tvos-simulator' if variant else 'tvos') + "'", "kernel = 'xnu'", "cpu_family = '" + family + "'", "cpu = '" + args.arch + "'", "endian = 'little'", '', '[built-in options]', "default_library = 'static'", "buildtype = 'release'", "prefix = '" + str(work / f'installed-{args.platform}-{args.arch}') + "'"]
for language in ['c', 'cpp', 'objc', 'objcpp']:
    lines.append(language + '_args = ' + repr(flags))
    lines.append(language + '_link_args = ' + repr(link))
cross.write_text('\n'.join(lines) + '\n')
env = dict(os.environ)
env['PKG_CONFIG_LIBDIR'] = str(prefix / 'lib/pkgconfig')
env['PKG_CONFIG_PATH'] = ''
build = work / f'build-{args.platform}-{args.arch}'
options = ['-Dlibmpv=true', '-Dgl=enabled', '-Dplain-gl=enabled', '-Diconv=enabled', '-Duchardet=enabled', '-Dvulkan=enabled', '-Dmoltenvk=enabled', '-Dios-sample-buffer=enabled', '-Dapple-gpu-pip=enabled', '-Djavascript=disabled', '-Dzimg=disabled', '-Djpeg=disabled', '-Dvapoursynth=disabled', '-Drubberband=disabled', '-Dgpl=true', '-Dlibbluray=enabled', '-Dcplayer=false', '-Dvideotoolbox-gl=disabled', '-Dvideotoolbox-pl=enabled', '-Dswift-build=disabled', '-Daudiounit=enabled', '-Davfoundation=enabled', '-Dcoreaudio=disabled', '-Dlua=disabled', '-Dios-gl=enabled']
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
