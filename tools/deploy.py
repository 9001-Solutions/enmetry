#!/usr/bin/env python3
"""Copy the addon into an Ashita install.

    python tools/deploy.py --ashita "D:/Games/Ashita/"
    ENMETRY_ASHITA="D:/Games/Ashita/" python tools/deploy.py

The target is the Ashita game directory, the one holding addons/.  Give it with
--ashita or ENMETRY_ASHITA; there is no default.  Stale files under the
destination are removed so a renamed or deleted module can't linger and get
picked up by require().
"""

import argparse
import os
import shutil
import subprocess
import sys

ADDON_NAME = 'enmetry'

DEFAULT_ASHITA = os.environ.get('ENMETRY_ASHITA')


def describe(here):
    """The commit the build came from, `-dirty` if the tree had changes.

    Always the hash, never a tag: `git describe` would name the tag whenever
    HEAD happens to carry one, so the same code would stamp itself differently
    depending on whether a release had been cut yet.
    """
    def git(*args):
        return subprocess.run(['git'] + list(args), cwd=here,
                              capture_output=True, text=True, check=True).stdout.strip()

    try:
        out = git('rev-parse', '--short', 'HEAD')
        if git('status', '--porcelain', '--untracked-files=no'):
            out += '-dirty'
    except (OSError, subprocess.CalledProcessError):
        return None
    return out or None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ashita', default=DEFAULT_ASHITA,
                    help='Ashita game directory (the one holding addons/); '
                         'defaults to $ENMETRY_ASHITA')
    ap.add_argument('--dry-run', action='store_true',
                    help='report what would be copied and exit')
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    source = os.path.abspath(os.path.join(here, '..', 'addon'))

    if not os.path.isfile(os.path.join(source, ADDON_NAME + '.lua')):
        sys.exit('error: %s.lua not found in %s' % (ADDON_NAME, source))

    if not args.ashita:
        sys.exit('error: no Ashita game directory given\n'
                 '       pass --ashita or set ENMETRY_ASHITA')

    if not os.path.isdir(os.path.join(args.ashita, 'addons')):
        sys.exit('error: no addons/ directory under %s\n'
                 '       pass --ashita with the path to your Ashita game folder'
                 % args.ashita)

    dest = os.path.join(args.ashita, 'addons', ADDON_NAME)
    files = [os.path.relpath(os.path.join(d, n), source)
             for d, _dirs, names in os.walk(source) for n in names]

    if args.dry_run:
        print('%d files\n%s\n  -> %s' % (len(files), source, dest))
        return

    # A plain overwrite would leave behind modules that no longer exist.
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    shutil.copytree(source, dest)

    # The deployed copy carries the commit it came from, which the addon
    # writes into its logs as `build`; the source tree has no such file.
    build = describe(here)
    if build is not None:
        with open(os.path.join(dest, 'build.lua'), 'w') as fh:
            fh.write('return %r\n' % build)

    print('deployed %d files -> %s (build %s)' % (len(files), dest, build or 'unknown'))
    print('in game:  /addon reload %s' % ADDON_NAME)


if __name__ == '__main__':
    main()
