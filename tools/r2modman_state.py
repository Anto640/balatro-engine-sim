"""Rebuild r2modman's file manifest for balatroenginesim from what is actually
on disk, and keep its mods.yml entry in step with your_mod.json.

r2modman tracks, per mod, every file it installed (profile `_state/*.yml` plus a
profile-wide `installation_state.yml`). Deploying by copying files leaves that
manifest stale, and r2modman's enable / disable / uninstall then act on the old
list -- so this runs after every sync. Idempotent; tools/deploy.sh calls it.

    python tools/r2modman_state.py [version]      # default: read your_mod.json
"""
import json
import os
import pathlib
import re
import shutil
import sys
import time

BS = chr(92)  # backslash, kept out of literals so no shell can mangle it
NAME = 'balatroenginesim'

HERE = pathlib.Path(__file__).resolve().parent.parent
VERSION = sys.argv[1] if len(sys.argv) > 1 else json.loads(
    (HERE / 'your_mod.json').read_text(encoding='utf-8'))['version']

APPDATA = pathlib.Path(os.environ['APPDATA'])
PROFILE = pathlib.Path(os.environ.get(
    'BES_R2_PROFILE',
    APPDATA / 'r2modmanPlus-local' / 'Balatro' / 'profiles' / 'Default'))
MODDIR = PROFILE / 'mods' / NAME
CACHE_ROOT = APPDATA / 'r2modmanPlus-local' / 'Balatro' / 'cache' / NAME
CACHE = CACHE_ROOT / VERSION

if not MODDIR.is_dir():
    sys.exit('no deployed mod at %s -- run tools/deploy.sh first' % MODDIR)


def prune_empty(root):
    for d, dirs, files in os.walk(root, topdown=False):
        if not dirs and not files:
            os.rmdir(d)


# --- 1. a Thunderstore-shaped manifest, so r2modman recognises the folder ----
# Steamodded ignores a json with no `id` (same as Handy's manifest.json), so
# this sits harmlessly beside your_mod.json.
meta = json.loads((HERE / 'your_mod.json').read_text(encoding='utf-8'))
(MODDIR / 'manifest.json').write_text(json.dumps({
    'name': NAME,
    'version_number': VERSION,
    'website_url': '',
    'description': meta.get('description', '')[:250],
    'dependencies': [],
}, indent=2) + '\n', encoding='utf-8')

# --- 2. the cache mirrors the profile copy (r2modman installs FROM the cache) -
for old in sorted(CACHE_ROOT.glob('*')):
    if old.is_dir() and old.name != VERSION:
        shutil.rmtree(old)          # a version bump leaves the old dir orphaned
if CACHE.exists():
    shutil.rmtree(CACHE)
shutil.copytree(MODDIR, CACHE)
prune_empty(CACHE)
prune_empty(MODDIR)

files = sorted(str(p.relative_to(CACHE)).replace('/', BS)
               for p in CACHE.rglob('*') if p.is_file())

# --- 3. the per-mod manifest: (absolute cache source, profile-relative dest) --
lines = ['modName: ' + NAME, 'files:']
for rel in files:
    lines.append('  - - ' + str(CACHE) + BS + rel)
    lines.append('    - mods' + BS + NAME + BS + rel)
(PROFILE / '_state' / (NAME + '-state.yml')).write_text(
    '\n'.join(lines) + '\n', encoding='utf-8')

# --- 4. the profile-wide manifest: keep other mods' rows verbatim ------------
inst = PROFILE / '_state' / 'installation_state.yml'
raw = inst.read_text(encoding='utf-8').rstrip('\n').split('\n')
assert raw[0].strip() == 'currentState:', raw[0]
kept, i = [], 0
while i + 1 < len(raw):
    i += 1
    if raw[i].lstrip().startswith('- - ') and i + 1 < len(raw):
        if raw[i + 1].strip() != '- ' + NAME:
            kept += [raw[i], raw[i + 1]]
        i += 1
out = ['currentState:'] + kept
for rel in files:
    out += ['  - - mods' + BS + NAME + BS + rel, '    - ' + NAME]
inst.write_text('\n'.join(out) + '\n', encoding='utf-8')

# --- 5. mods.yml: one entry for us, with the version it actually is ----------
mods = PROFILE / 'mods.yml'
body = mods.read_text(encoding='utf-8')
parts = [b for b in re.split(r'(?m)^(?=- manifestVersion:)', body) if b.strip()]
parts = [p for p in parts if not re.search(r'(?m)^  name: %s$' % NAME, p)]
major, minor, patch = (list(VERSION.split('.')) + ['0', '0'])[:3]
parts.append(
    '- manifestVersion: 1\n'
    '  name: %s\n'
    '  authorName: %s\n'
    "  websiteUrl: ''\n"
    '  displayName: %s\n'
    '  description: %s\n'
    "  gameVersion: '0'\n"
    '  networkMode: both\n'
    '  packageType: other\n'
    '  installMode: managed\n'
    '  installedAtTime: %d\n'
    '  loaders: []\n'
    '  dependencies: []\n'
    '  incompatibilities: []\n'
    '  optionalDependencies: []\n'
    '  versionNumber:\n'
    '    major: %s\n'
    '    minor: %s\n'
    '    patch: %s\n'
    '  enabled: true\n'
    '  onlineSource: false\n'
    '  trustedPackage: false\n' % (
        NAME,
        (meta.get('author') or ['unknown'])[0],
        meta.get('display_name', NAME),
        meta.get('description', '')[:250].replace('\n', ' '),
        int(time.time() * 1000),
        major, minor, patch))
mods.write_text(''.join(parts), encoding='utf-8')

print('r2modman state rebuilt: %d files tracked, v%s' % (len(files), VERSION))
