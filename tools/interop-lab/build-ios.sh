#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
build_root="${BITCHAT_LAB_BUILD_ROOT:-$repo_root/work/interop-lab-ios-build}"
mkdir -p "$build_root"
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (iOS)' \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_root/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER=chat.bitchat.ndrlab \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG BITCHAT_INTEROP_LAB' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
app="$build_root/DerivedData/Build/Products/Debug-iphoneos/bitchat.app"
# The lab uses no share extension, app group, OS keychain or location services.
rm -rf "$app/PlugIns"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$app/Info.plist" || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$app/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string Controlled synthetic interoperability tests' "$app/Info.plist"
COPYFILE_DISABLE=1 tar -cf "$build_root/ndr-interop-ios.tar" -C "$(dirname "$app")" bitchat.app
shasum -a 256 "$build_root/ndr-interop-ios.tar"
