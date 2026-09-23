#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"
app="build/MonoQuota.app"
mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework SwiftUI \
  Sources/MonoQuota.swift -o "$app/Contents/MacOS/MonoQuota"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
