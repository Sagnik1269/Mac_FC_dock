#!/usr/bin/env bash
# Builds "FC Dock.app" into ./build.
# Set SIGN_IDENTITY to a codesigning identity (e.g. "Apple Development: you@example.com")
# so macOS keeps the Accessibility permission across rebuilds. Defaults to ad-hoc signing.
# Set SDK_PATH to force a specific macOS SDK.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/FC Dock.app"
BIN=".build/manual/FCDock"
mkdir -p "$(dirname "$BIN")"

# Compiles with swiftc directly: it's a single module with no dependencies, and this avoids
# swift-package / Xcode-license problems. Tries SDKs newest-first until one matches the compiler.
compile() {
    xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" -sdk "$1" \
        $(find Sources/FCDock -name "*.swift" | sort) -o "$BIN"
}

if [[ -n "${SDK_PATH:-}" ]]; then
    compile "$SDK_PATH"
else
    built=0
    sdk_dir="$(dirname "$(xcrun --show-sdk-path)")"
    for sdk in "$(xcrun --show-sdk-path)" $(ls -d "$sdk_dir"/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -rV); do
        if output="$(compile "$sdk" 2>&1)"; then
            echo "Compiled with $sdk"
            built=1
            break
        fi
        # Skip SDKs the compiler can't read; anything else is a real error in our code.
        if ! grep -q "this SDK is not supported by the compiler" <<<"$output"; then
            echo "$output" >&2
            exit 1
        fi
    done
    if [[ $built -eq 0 ]]; then
        echo "No installed macOS SDK matches this Swift compiler." >&2
        exit 1
    fi
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FCDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
