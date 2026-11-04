#!/bin/sh
# Builds and runs the tests. With only the Command Line Tools (no Xcode), Swift Testing
# lives in a framework folder swift doesn't search by default, so point it there.
set -eu
cd "$(dirname "$0")"
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ ! -d /Applications/Xcode.app ] && [ -d "$CLT/Frameworks/Testing.framework" ]; then
    F=$CLT/Frameworks
    L=$CLT/usr/lib
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
