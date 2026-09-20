#!/usr/bin/env python3
"""Build the release zip: everything needed to run the addon, nothing else.

    python tools/package.py
    python tools/package.py --out dist --version 1.0.0

The archive holds a single top-level `enmetry/` folder, so unzipping it into
an Ashita install's `addons/` puts the addon where it belongs.  The version
comes from `addon.version` in enmetry.lua unless --version overrides it.

Only `addon/` ships: the tests, the generators and the wiki snapshots are not
needed to run it.  LICENSE rides along because the vendored tables are derived
from LandSandBoat and the GPL asks for it.  A `build.lua` naming the commit is
written in, the same one `tools/deploy.py` leaves, so a release's session logs
say which build wrote them.

Entries are stored sorted, with a fixed timestamp, so the same commit always
produces a byte-identical archive.
"""

import argparse
import os
import re
import subprocess
import sys
import zipfile

ADDON_NAME = 'enmetry'
EXTRA = ['LICENSE']

# Any DOS timestamp does; this one keeps rebuilds byte-identical.
FIXED_TIME = (1980, 1, 1, 0, 0, 0)


def version_of(source):
    text = open(os.path.join(source, ADDON_NAME + '.lua')).read()
    found = re.search(r"addon\.version\s*=\s*'([^']+)'", text)
    if found is None:
        sys.exit('error: no addon.version in %s.lua' % ADDON_NAME)
    return found.group(1)


def describe(root):
    """The commit the build came from, `-dirty` if the tree had changes.

    Always the hash, never a tag: `git describe` would name the tag whenever
    HEAD happens to carry one, so the same code would stamp itself differently
    depending on whether a release had been cut yet.
    """
    def git(*args):
        return subprocess.run(['git'] + list(args), cwd=root,
                              capture_output=True, text=True, check=True).stdout.strip()

    try:
        out = git('rev-parse', '--short', 'HEAD')
        if git('status', '--porcelain', '--untracked-files=no'):
            out += '-dirty'
    except (OSError, subprocess.CalledProcessError):
        return None
    return out or None


def write(zf, name, data):
    info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    zf.writestr(info, data)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default='dist', help='directory for the archive (default: dist)')
    ap.add_argument('--version', help='override addon.version')
    ap.add_argument('--list', action='store_true', help='print what would ship and exit')
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source = os.path.join(root, 'addon')
    if not os.path.isfile(os.path.join(source, ADDON_NAME + '.lua')):
        sys.exit('error: %s.lua not found in %s' % (ADDON_NAME, source))

    version = args.version or version_of(source)
    build = describe(root)

    files = sorted(os.path.relpath(os.path.join(d, n), source).replace(os.sep, '/')
                   for d, _dirs, names in os.walk(source) for n in names)
    extra = [name for name in EXTRA if os.path.isfile(os.path.join(root, name))]

    if args.list:
        for name in files:
            print('%s/%s' % (ADDON_NAME, name))
        for name in extra:
            print('%s/%s' % (ADDON_NAME, name))
        print('%s/build.lua' % ADDON_NAME)
        return

    os.makedirs(os.path.join(root, args.out), exist_ok=True)
    path = os.path.join(root, args.out, '%s-%s.zip' % (ADDON_NAME, version))

    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for name in files:
            with open(os.path.join(source, name), 'rb') as fh:
                write(zf, '%s/%s' % (ADDON_NAME, name), fh.read())
        for name in extra:
            with open(os.path.join(root, name), 'rb') as fh:
                write(zf, '%s/%s' % (ADDON_NAME, name), fh.read())
        write(zf, '%s/build.lua' % ADDON_NAME, 'return %r\n' % (build or 'unknown'))

    print('%s\n  %d files, %d KiB, version %s, build %s'
          % (path, len(files) + len(extra) + 1, os.path.getsize(path) // 1024,
             version, build or 'unknown'))
    if build and build.endswith('-dirty'):
        print('  warning: built from a dirty tree')


if __name__ == '__main__':
    main()
