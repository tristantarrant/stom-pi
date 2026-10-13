#!/usr/bin/env python3
"""Patch removed stdlib 'collections' ABCs inside the staged venv.

tornado==4.3 (pinned by mod-ui/requirements.txt) predates Python 3.10 and uses two
forms that no longer work on modern interpreters:

  A. `from collections import MutableMapping`          -> rewritten to a try/except
                                                          with the collections.abc fallback
  B. bare module-level `import collections` plus attribute access such as
     `collections.MutableMapping` (tornado/httputil.py) -> a shim is inserted after the
      import that backfills the missing attributes from collections.abc

Only names actually removed in Python 3.10 are touched; OrderedDict, UserDict,
Counter & co. still live in plain `collections` and must be left alone. Any package
using these ABCs this way is broken on modern Pythons regardless of us, so the
rewrites are safe wherever they fire. Idempotent: already-patched files are skipped.
"""

import os
import re
import sys

SITE = sys.argv[1]

ABC_NAMES = (
    'MutableMapping', 'Mapping', 'MutableSequence', 'Sequence', 'MutableSet',
    'Set', 'Iterable', 'Iterator', 'Callable', 'Hashable', 'Container',
)

MARKER = '# tornado-abc-fix'

FROM_IMP = re.compile(r'^from collections import ([A-Za-z_][A-Za-z0-9_, \t]*)$', re.M)
BARE_IMP_LINE = re.compile(r'^import collections[^\S\n]*\n', re.M)  # column-0 only (module level)
ATTR_USE = re.compile(r'\bcollections\.(' + '|'.join(ABC_NAMES) + r')\b')

SHIM = (
    'try:  %s shim: ABCs moved out of "collections" in Python >= 3.10\n'
    '    from collections import abc as _tornado_abc_fix_abcm\n'
    'except ImportError:\n'
    '    pass\n'
    'else:\n'
    '    for _tornado_abc_fix_name in %s:\n'
    '        if not hasattr(collections, _tornado_abc_fix_name):\n'
    '            setattr(collections, _tornado_abc_fix_name,\n'
    '                    getattr(_tornado_abc_fix_abcm, _tornado_abc_fix_name))\n' % (MARKER, repr(list(ABC_NAMES)))
)


def fix_from_import(match):
    names = [n.strip() for n in match.group(1).split(',') if n.strip()]
    # Leave non-ABC imports (OrderedDict, defaultdict, ...) untouched.
    if not all(n in ABC_NAMES for n in names):
        return match.group(0)
    joined = ', '.join(names)
    return ('try:\n'
            'from collections.abc import %s\n' % joined +
            'except ImportError:\n'
            'from collections import %s' % joined)


patched = 0
for root, dirs, files in os.walk(SITE):
    dirs[:] = [d for d in dirs if d != '__pycache__']
    for name in files:
        if not name.endswith('.py'):
            continue
        path = os.path.join(root, name)
        with open(path, encoding='utf-8') as fh:
            src = fh.read()

        new = FROM_IMP.sub(fix_from_import, src)

        # Pattern B: attribute access on a bare module-level `import collections`.
        if (MARKER not in new and ATTR_USE.search(new)):
            m = BARE_IMP_LINE.search(new)
            if m is None:
                print('WARNING: %s uses removed ABC attributes but has no '
                      'module-level "import collections" anchor; skipped' % os.path.relpath(path, SITE))
            else:
                pos = m.end()  # just after the import line's newline -> shim starts on its own line
                new = new[:pos] + SHIM + new[pos:]

        if new != src:
            with open(path, 'w', encoding='utf-8') as fh:
                fh.write(new)
            patched += 1
            print('patched %s' % os.path.relpath(path, SITE))

print('tornado-abc-fix: rewrote ABC imports in %d file(s)' % patched)
