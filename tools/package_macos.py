"""Bundle Homebrew dylib dependencies and ad-hoc sign a Beam macOS beta."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--app', type=Path, required=True)
p.add_argument('--entitlements', type=Path, required=True)
p.add_argument('--audit', type=Path, required=True)
p.add_argument('--minimum-macos', default='26.0')
a = p.parse_args()
app = a.app.resolve()
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(exist_ok=True)
# Restore a valid ad-hoc signature if resuming an interrupted packaging run.
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--entitlements',
                str(a.entitlements), str(app)], check=True)

def run(args):
    return subprocess.check_output(args, text=True).strip()

def macho(path):
    return path.is_file() and 'Mach-O' in run(['file', '-b', str(path)])

copied = []
while True:
    pending = []
    for path in app.rglob('*'):
        if not macho(path):
            continue
        for line in run(['otool', '-L', str(path)]).splitlines()[1:]:
            dependency = line.strip().split(' (')[0]
            destination = frameworks / Path(dependency).name
            external = dependency.startswith(('/opt/homebrew/', '/usr/local/'))
            local = dependency.startswith('@loader_path/') and destination.is_file()
            if not (external or local):
                continue
            if not destination.exists():
                shutil.copy2(dependency, destination)
                pending.append(destination)
                copied.append(dependency)
            subprocess.run(['install_name_tool', '-change', dependency,
                            '@rpath/' + destination.name, str(path)], check=True)
            if path.parent == frameworks:
                subprocess.run(['install_name_tool', '-id', '@rpath/' + path.name,
                                str(path)], check=True)
    if not pending:
        break

for name in ['liblibtorrent_flutter.dylib', 'libssl.3.dylib', 'libcrypto.3.dylib']:
    if not (frameworks / name).is_file():
        raise RuntimeError('Missing bundled native library: ' + name)
info = app / 'Contents/Info.plist'
data = plistlib.loads(info.read_bytes())
data['LSMinimumSystemVersion'] = a.minimum_macos
info.write_bytes(plistlib.dumps(data))
seen = set()
for path in app.rglob('*'):
    real = path.resolve()
    if real in seen or not macho(path):
        continue
    if not real.is_relative_to(app):
        raise RuntimeError('Mach-O path escapes application bundle')
    real.chmod(real.stat().st_mode | stat.S_IWUSR)
    seen.add(real)
    arch = run(['lipo', '-archs', str(real)]).split()
    if 'arm64' not in arch:
        raise RuntimeError('Missing Apple silicon architecture: ' + str(path))
    if len(arch) > 1:
        subprocess.run(['lipo', str(real), '-thin', 'arm64', '-output', str(real)],
                       check=True)
    subprocess.run(['strip', '-S', str(real)], check=True)
# Swift module build metadata is not needed to run an application bundle.
for path in list(app.rglob('Modules')):
    if path.is_dir() and not path.is_symlink():
        if not path.resolve().is_relative_to(app):
            raise RuntimeError('Module path escapes application bundle')
        shutil.rmtree(path)
checks = []
for path in app.rglob('*'):
    if not macho(path):
        continue
    dependencies = run(['otool', '-L', str(path)])
    if '/opt/homebrew/' in dependencies or '/usr/local/' in dependencies:
        raise RuntimeError('External dependency remains: ' + str(path))
    arch = run(['lipo', '-archs', str(path)])
    if 'arm64' not in arch:
        raise RuntimeError('Missing Apple silicon architecture: ' + str(path))
    checks.append({'file': str(path.relative_to(app)), 'arch': arch})
subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--entitlements',
                str(a.entitlements), str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)],
               check=True)
a.audit.write_text(json.dumps({'minimumMacOS': a.minimum_macos, 'signing': 'ad-hoc',
                              'copiedDependencies': copied, 'machO': checks}, indent=2))
print('Verified', len(checks), 'Mach-O files; copied', len(copied), 'dependencies')
