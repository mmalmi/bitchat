#!/bin/bash
set -euo pipefail
# Run only after source-built NdrFfi preparation with the pinned Apple toolchain.
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
build_root="${BITCHAT_LAB_BUILD_ROOT:-$repo_root/work/interop-lab-build}"
mkdir -p "$build_root"
xcodebuild -project bitchat.xcodeproj -scheme 'bitchat (macOS)' \
  -configuration Debug -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_root/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER=chat.bitchat.ndrlab \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG BITCHAT_INTEROP_LAB' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
app="$build_root/DerivedData/Build/Products/Debug/bitchat.app"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$app/Contents/Info.plist" || true
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$app/Contents/Info.plist"
# The app has a separate sandbox, no app-group/keychain/location entitlement.
while IFS= read -r -d '' framework; do
  codesign --force --sign - "$framework"
done < <(find "$app/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0)
codesign --force --sign - --entitlements tools/interop-lab/macos.entitlements "$app"
codesign --verify --deep --strict "$app"
COPYFILE_DISABLE=1 tar -cf "$build_root/ndr-interop-macos.tar" -C "$(dirname "$app")" bitchat.app
shasum -a 256 "$build_root/ndr-interop-macos.tar"
