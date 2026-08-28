#!/usr/bin/env python3
"""Puts the Sparkle public key into the project.

    python3 Tools/set_update_key.py <public-key>

Deliberately not a sed one-liner. An EdDSA public key is base64, so it
contains "/" and "+" and usually ends in "=" — characters that fight sed's
delimiter and the shell's quoting, and that are invalid unquoted inside a
project file. Getting any of that wrong produces a project Xcode will not
open, which is a bad trade for saving a script.

Whitespace and stray newlines from copying out of a terminal are stripped,
the key is checked for shape, and the project file is re-validated
afterwards so a mistake surfaces here rather than in Xcode.
"""

import pathlib
import re
import subprocess
import sys

PROJECT = pathlib.Path("RosyTranscribe.xcodeproj/project.pbxproj")
SETTING = "INFOPLIST_KEY_SUPublicEDKey"
PLACEHOLDER = "REPLACE_WITH_PUBLIC_ED_KEY"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    # Copying from a terminal drags in newlines and spaces; drop all of it.
    key = "".join(sys.argv[1].split())

    if key == PLACEHOLDER:
        print("That is the placeholder, not a key. Run generate_keys first.")
        return 1
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", key):
        print("That does not look like a base64 key: %r" % key)
        print("Pass the public key generate_keys printed, on its own.")
        return 1
    if not PROJECT.exists():
        print("Run this from the repository root; %s is not here." % PROJECT)
        return 1

    text = PROJECT.read_text()
    # Matches the placeholder or a previously set key, so re-running is fine.
    pattern = re.compile(r'(%s = )"[^"]*";' % re.escape(SETTING))
    updated, count = pattern.subn(r'\1"%s";' % key, text)
    if count == 0:
        print("Could not find a quoted %s setting to update." % SETTING)
        return 1

    PROJECT.write_text(updated)
    print("Set %s in %d configuration(s)." % (SETTING, count))

    check = subprocess.run([sys.executable, "Tools/validate_pbxproj.py"],
                           capture_output=True, text=True)
    if check.returncode != 0:
        PROJECT.write_text(text)
        print("The project file no longer parses, so nothing was changed:")
        print((check.stdout + check.stderr).strip().splitlines()[-1])
        return 1

    print("Project file still parses. Build away.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
