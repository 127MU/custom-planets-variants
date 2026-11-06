"""Package only the Rust/Flutter app and the verified HTTP proxy runtime."""
import argparse, hashlib, io, json, lzma, shutil, zipfile
from pathlib import Path
from proxy_runtime_policy import include_proxy_file
from font_assets import verify_icons

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser()
p.add_argument('--output',type=Path,required=True)
p.add_argument('--proxy-runtime',type=Path,required=True)
p.add_argument('--solid-payload',type=Path,help='Write an XZ launcher payload containing the complete distribution')
p.add_argument('--flutter-build',type=Path,default=ROOT/'ui/build/windows/x64/runner/Release')
p.add_argument('--rust-build',type=Path,default=ROOT/'backend/target/release')
a=p.parse_args()
verify_icons(a.flutter_build)
if not (a.flutter_build/'url_launcher_windows_plugin.dll').is_file():
    p.error('Windows browser launcher plugin is missing from the Flutter build')
out=a.output.resolve();release=out/'CPV_2.0.1'
if release.exists():p.error('Use a fresh package output directory')
release.mkdir(parents=True)
for file in a.flutter_build.rglob('*'):
    if not file.is_file() or file.suffix.lower() in {'.pdb','.lib','.exp','.ilk'}:continue
    relative=file.relative_to(a.flutter_build)
    if relative.as_posix()=='cpv.exe':relative=Path('自定义星球和变种.exe')
    dst=release/relative;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,dst)
for name in ['cpv-core.exe','cpv-steam-bridge.exe']:shutil.copy2(a.rust_build/name,release/name)
(release/'proxy').mkdir()
shutil.copy2(ROOT/'proxy/war_status_addon.py',release/'proxy/war_status_addon.py')

# Redistributable CRT files: no installer or development SDK in the package.
redists=list(Path('C:/Program Files/Microsoft Visual Studio/2022/Community/VC/Redist/MSVC').glob('*/x64/Microsoft.VC143.CRT'))
if redists:
    for name in ['msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll']:
        file=sorted(redists)[-1]/name
        if file.exists():shutil.copy2(file,release/name)

metadata = json.loads((a.proxy_runtime / 'runtime.json').read_text('utf8'))
assert metadata['core'] == 'mitmproxy' and metadata['version'] == '12.3.1'
kept = {name: digest for name, digest in metadata['files'].items() if include_proxy_file(name)}
for name, digest in kept.items():
    file = (a.proxy_runtime / name).resolve()
    assert file.is_relative_to(a.proxy_runtime.resolve())
    assert hashlib.sha256(file.read_bytes()).hexdigest() == digest, name
    dst = release / 'mitmproxy' / name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(file, dst)
metadata['files'] = kept
metadata['capture_modes'] = ['regular', 'upstream']
(release / 'mitmproxy/runtime.json').write_text(json.dumps(metadata, indent=2), 'utf8')
(release/'licenses').mkdir()
for name in ['Morrow-LICENSE','Morrow-NOTICE','Morrow-PROVENANCE.md','SHODAN-LICENSE','lzma-rust2-LICENSE','hd2-datamined-LICENSE']:
    shutil.copy2(ROOT/'licenses'/name,release/'licenses'/name)
shutil.copy2(ROOT/'licenses/Morrow-LICENSE',release/'LICENSE')
shutil.copy2(ROOT/'README.md',release/'README.md')
shutil.copy2(ROOT/'README.en.md',release/'README.en.md')
files={f.relative_to(release).as_posix():hashlib.sha256(f.read_bytes()).hexdigest() for f in release.rglob('*') if f.is_file()}
(release/'manifest.json').write_text(json.dumps({'product':'CPV','version':'2.0.1','files':files},ensure_ascii=False,indent=2),'utf8')
if a.solid_payload:
    stored = io.BytesIO()
    entries = sorted((f for f in release.rglob('*') if f.is_file()),
                     key=lambda f: (f.suffix.lower(), f.as_posix()))
    with zipfile.ZipFile(stored, 'w', zipfile.ZIP_STORED) as z:
        for f in entries:
            z.write(f, release.name + '/' + f.relative_to(release).as_posix())
    a.solid_payload.parent.mkdir(parents=True, exist_ok=True)
    with lzma.open(a.solid_payload, 'wb', preset=6) as payload:
        payload.write(stored.getbuffer())
archive=out/(release.name+'_Windows.zip')
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for f in release.rglob('*'):
        if f.is_file():z.write(f,release.name+'/'+f.relative_to(release).as_posix())
source=out/(release.name+'_Source.zip')
with zipfile.ZipFile(source,'w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for folder in ['backend/src','assets','proxy','licenses','ui/lib','ui/assets','ui/shaders','ui/windows','ui/test']:
        for f in (ROOT/folder).rglob('*'):
            if folder=='licenses' and f.name.startswith('Qt-'):continue
            if folder=='assets' and f.name in {'i18n-en.json','app.manifest','icon-prompt.txt'}:continue
            if f.is_file() and not any(part in {'ephemeral','__pycache__'} for part in f.parts):z.write(f,'CPV_Source/'+f.relative_to(ROOT).as_posix())
    for name in ['.gitignore','LICENSE','README.md','README.en.md','backend/Cargo.toml','backend/Cargo.lock','backend/build.rs','ui/pubspec.yaml','ui/pubspec.lock','ui/analysis_options.yaml','ui/.gitignore','ui/.metadata','ui/README.md','tools/build-rust.ps1','tools/package-rust.py','tools/proxy_runtime_policy.py','tools/font_assets.py','tools/release-manifest.py','tests/test_catalog.py','tests/test_translations.py','tests/test_war_status_addon.py','tests/test_rust_core.py']:
        z.write(ROOT/name,'CPV_Source/'+name)
hashes={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in [archive,source]}
(out/'SHA256SUMS.txt').write_text(''.join(f'{digest}  {name}\n' for name,digest in hashes.items()),'utf8')
print(json.dumps({'release':str(release),'zip_bytes':archive.stat().st_size,'source_bytes':source.stat().st_size,'files':len(files)},ensure_ascii=False))
