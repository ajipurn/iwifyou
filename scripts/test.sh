#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/swift-env.sh

developer_directory="$(xcode-select -p)"
testing_frameworks="$developer_directory/Library/Developer/Frameworks"
if [[ ! -d "$testing_frameworks/Testing.framework" ]]; then
    testing_frameworks="$developer_directory/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi

if [[ -d "$testing_frameworks/Testing.framework" ]]; then
    swiftpm test "$@" -Xswiftc -F -Xswiftc "$testing_frameworks" \
        -Xlinker -F -Xlinker "$testing_frameworks" \
        -Xlinker -rpath -Xlinker "$testing_frameworks"
else
    swiftpm test "$@"
fi
