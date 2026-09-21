#!/bin/bash
# Optional complete XCTest runner for a CLT toolchain with a separately installed Xcode.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
xcode_developer="${ACF_XCODE_DEVELOPER:-/Applications/Xcode.app/Contents/Developer}"
platform="$xcode_developer/Platforms/MacOSX.platform/Developer"
frameworks="$platform/Library/Frameworks"
libraries="$platform/usr/lib"
runner="$platform/Library/Xcode/Agents/xctest"
if [[ ! -d "$SDKROOT" || ! -x "$runner" ]]; then
    printf '%s\n' 'Set SDKROOT and ACF_XCODE_DEVELOPER to a compatible installed SDK and Xcode, or use swift test with a configured full Xcode.' >&2
    exit 1
fi
swift build --build-tests --build-system native \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xswiftc -I -Xswiftc "$libraries" \
    -Xlinker -L -Xlinker "$libraries" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$libraries"
binary_dir="$(swift build --build-system native --show-bin-path)"
"$runner" "$binary_dir/AgentConversationFinderPackageTests.xctest"
