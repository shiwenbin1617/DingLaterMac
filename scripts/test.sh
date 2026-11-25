#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
developer="$(xcode-select -p)"
frameworks="$developer/Library/Developer/Frameworks"
if [[ -d "$frameworks/Testing.framework" ]]; then
    swift test --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$frameworks" \
        -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$developer/Library/Developer/usr/lib"
else
    swift test --disable-xctest --enable-swift-testing
fi

