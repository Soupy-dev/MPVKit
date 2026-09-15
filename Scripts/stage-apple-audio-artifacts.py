from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
work = root / '.build/apple-spatial-native'
staged = work / 'staged-runtime'
if staged.exists():
    raise RuntimeError('Staging directory already exists: ' + str(staged))
staged.mkdir()
source = work / 'mpv-source'
patch_hash = hashlib.sha256((source / '.mpvkit-patch-set').read_bytes()).hexdigest()
active = root / 'dist/release/xcframework'
for artifact in active.glob('*.xcframework'):
    subprocess.run(['/bin/cp', '-cR', str(artifact), str(staged / artifact.name)], check=True)
marker_path = root / 'dist/release/MoltenVK.imported-mtltexture-residency-fix'
if marker_path.exists():
    marker = json.loads(marker_path.read_text())
    marker['artifact'] = 'MoltenVK.xcframework'
    (staged / marker_path.name).write_text(json.dumps(marker, indent=2) + '\n')
artifact = staged / 'Libmpv.xcframework'
info = plistlib.loads((artifact / 'Info.plist').read_bytes())
manifest = {'patch_set_sha256': patch_hash, 'source': str(source), 'slices': {}, 'retained_slices': {}}
platforms = {('ios', None): 'ios', ('ios', 'simulator'): 'isimulator', ('ios', 'maccatalyst'): 'maccatalyst', ('tvos', None): 'tvos', ('tvos', 'simulator'): 'tvsimulator', ('macos', None): 'macos'}
for item in info['AvailableLibraries']:
    identifier = item['LibraryIdentifier']
    framework = artifact / identifier / item['LibraryPath']
    binary = artifact / identifier / item['BinaryPath']
    key = (item['SupportedPlatform'], item.get('SupportedPlatformVariant'))
    if key not in platforms:
        manifest['retained_slices'][identifier] = hashlib.sha256(binary.read_bytes()).hexdigest()
        continue
    archives = []
    records = {}
    for arch in item['SupportedArchitectures']:
        platform = platforms[key]
        archive = work / f'build-{platform}-{arch}/libmpv.a'
        record = json.loads((work / f'inputs-{platform}-{arch}.json').read_text())
        if record['patches_sha256'] != patch_hash or record['archive_sha256'] != hashlib.sha256(archive.read_bytes()).hexdigest():
            raise RuntimeError('Unvalidated native archive: ' + str(archive))
        records[arch] = record
        archives.append(str(archive))
    subprocess.run(['xcrun', 'lipo', '-create', *archives, '-output', str(binary)], check=True)
    for header in (source / 'include/mpv').glob('*.h'):
        shutil.copy2(header, framework / 'Headers/mpv' / header.name)
    for signature in framework.rglob('_CodeSignature'):
        if signature.is_dir():
            shutil.rmtree(signature)
    data = binary.read_bytes()
    if b'apple-compressed-audio' not in data or b'Apple compressed audio unavailable; falling back to PCM' not in data:
        raise RuntimeError('Missing compressed audio implementation: ' + identifier)
    manifest['slices'][identifier] = {'sha256': hashlib.sha256(data).hexdigest(), 'architectures': records}
manifest['info_plist_sha256'] = hashlib.sha256((artifact / 'Info.plist').read_bytes()).hexdigest()
(staged / 'apple-audio-provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(staged)
print('Patch set:', patch_hash)
for identifier, record in manifest['slices'].items():
    print(identifier, record['sha256'])
