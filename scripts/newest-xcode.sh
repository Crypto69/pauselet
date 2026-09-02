#!/bin/sh
# Prints the path of the newest release Xcode installed under /Applications,
# falling back to the newest beta if that is all there is. CI runner images
# rotate which versions they carry, so nothing pins a specific one.
set -eu
releases="$(ls -d /Applications/Xcode*.app 2>/dev/null | grep -iv beta | sort -V | tail -1 || true)"
if [ -n "$releases" ]; then
    echo "$releases"
    exit 0
fi
ls -d /Applications/Xcode*.app | sort -V | tail -1
