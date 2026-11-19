#!/usr/bin/env python3
#
# set-base.py - Make the packaged scripts find each other in the Nix store
#
#     set-base.py SHARE FILE...
#
# The scripts find each other through BASE and SCRIPT_BASE in ~/.tis/tis-clone.cfg, which setup.sh points at a
# checkout.  In the Nix package they're SHARE, whatever the config says, so they're set again right after
# each place a FILE reads the config:
#
#     . ${HOME}/.tis/tis-clone.cfg                         (shell scripts)
#     . ${CFG}                                              (setup.sh)
#     '. "$HOME/.tis/tis-clone.cfg" && printf ...'          (Python's load_cfg())
#
# A FILE that still mentions reading the config some other way stops the build, so a new script can't
# quietly run the checkout's copies of the others.  tis-serve.py's '. "$1"' only reads FSM_URLBASE.
#

import re
import sys

share, files = sys.argv[1], sys.argv[2:]
base = "BASE=%s; SCRIPT_BASE=%s/scripts" % (share, share)

SHELL_RE = re.compile(r'^([ \t]*\. (?:\$\{HOME\}/\.tis/tis-clone\.cfg|\$\{CFG\}))[ \t]*$', re.M)
PY_RE = re.compile(r'''('\. "\$HOME/\.tis/tis-clone\.cfg" && )''')
# Anything else that looks like it reads the config
ANY_RE = re.compile(r'''^[ \t]*\. .*tis-clone\.cfg|'\. "\$HOME/\.tis/tis-clone\.cfg"''', re.M)

bad = []
for f in files:
    with open(f, encoding="utf-8") as fh:
        text = fh.read()
    new = SHELL_RE.sub(lambda m: "%s; %s" % (m.group(1), base), text)
    new = PY_RE.sub(lambda m: m.group(1) + base.replace("; ", " && ") + " && ", new)
    for m in ANY_RE.finditer(new):
        line = new[new.rfind("\n", 0, m.start()) + 1:new.find("\n", m.start())]
        if "SCRIPT_BASE=%s/scripts" % share not in line:
            bad.append("%s: %s" % (f, line.strip()))
    if new != text:
        with open(f, "w", encoding="utf-8") as fh:
            fh.write(new)

if bad:
    sys.exit("These read tis-clone.cfg without BASE being set after; update nix/set-base.py:\n  "
             + "\n  ".join(bad))
