#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/swift-env.sh

configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    print -u2 'Usage: ./scripts/build-app.sh [release|debug]'
    exit 1
fi

swiftpm build -c "$configuration"
binary_directory="$(swiftpm build -c "$configuration" --show-bin-path)"
application="${PWD}/build/iwifyou.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
cp "$binary_directory/iwifyou" "$application/Contents/MacOS/iwifyou"
cp Resources/Info.plist "$application/Contents/Info.plist"
mkdir -p "$application/Contents/Resources/Fonts"
cp Resources/Fonts/* "$application/Contents/Resources/Fonts/"
swift scripts/make-icon.swift "$application/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier app.iwifyou.mac "$application"
print "App tersedia: $application"
