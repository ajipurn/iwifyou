#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/swift-env.sh

usage='Usage: ./scripts/build-app.sh [release|debug] [--universal]'
configuration="release"
universal=false
for argument in "$@"; do
    case "$argument" in
        release|debug) configuration="$argument" ;;
        --universal) universal=true ;;
        *) print -u2 "$usage"; exit 1 ;;
    esac
done

application="${PWD}/build/iwifyou.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources"
if $universal; then
    # Apple Silicon and Intel slices, for builds shared with other Macs.
    slices=()
    for triple in arm64-apple-macosx14.0 x86_64-apple-macosx14.0; do
        swiftpm build -c "$configuration" --triple "$triple"
        slices+=("$(swiftpm build -c "$configuration" --triple "$triple" --show-bin-path)/iwifyou")
    done
    lipo -create "${slices[@]}" -output "$application/Contents/MacOS/iwifyou"
else
    swiftpm build -c "$configuration"
    binary_directory="$(swiftpm build -c "$configuration" --show-bin-path)"
    cp "$binary_directory/iwifyou" "$application/Contents/MacOS/iwifyou"
fi
cp Resources/Info.plist "$application/Contents/Info.plist"
mkdir -p "$application/Contents/Resources/Fonts"
cp Resources/Fonts/* "$application/Contents/Resources/Fonts/"
swift scripts/make-icon.swift "$application/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier app.iwifyou.mac "$application"
print "App tersedia: $application"
