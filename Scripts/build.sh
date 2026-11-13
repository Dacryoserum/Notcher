#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2;; esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox -c "$configuration"
bin_path="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
app="$PWD/.build/AppBundle/Notcher.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/Notcher" "$app/Contents/MacOS/Notcher"
cp App/Info.plist "$app/Contents/Info.plist"
# A real app uses Contents/Resources; Bundle.module is only the swift-run fallback.
rm -rf "$app/Contents/MacOS/Notcher_Notcher.bundle"
cp Sources/Notcher/Resources/MediaBridge.js "$app/Contents/Resources/MediaBridge.js"
if [ -f App/Notcher.icns ]; then cp App/Notcher.icns "$app/Contents/Resources/Notcher.icns"; fi
codesign --force --sign - --identifier fr.notcher.app "$app"
codesign --verify --deep --strict "$app"
# Swap complete bundles instead of overwriting an executable that may still be running.
mkdir -p "$PWD/dist"
if [ -d "$PWD/dist/Notcher.app" ]; then
    rm -rf "$PWD/.build/PreviousNotcher.app"
    mv "$PWD/dist/Notcher.app" "$PWD/.build/PreviousNotcher.app"
fi
mv "$app" "$PWD/dist/Notcher.app"
app="$PWD/dist/Notcher.app"
printf 'Application prête : %s\n' "$app"
