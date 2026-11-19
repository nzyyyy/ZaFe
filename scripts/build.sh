#!/bin/bash
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
signing_identity="${ZAFE_SIGNING_IDENTITY:-Apple Development:}"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$project_dir/dist"

swift build --disable-sandbox --cache-path "$project_dir/.build/cache" --configuration release
binary_dir="$(swift build --disable-sandbox --cache-path "$project_dir/.build/cache" --configuration release --show-bin-path)"
stage_dir="$(mktemp -d "$project_dir/.build/package.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
bundle="$stage_dir/ZaFe.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/ZaFe" "$bundle/Contents/MacOS/ZaFe"
cp "$project_dir/Resources/Info.plist" "$bundle/Contents/Info.plist"

swift "$project_dir/scripts/make-icon.swift" "$stage_dir/AppIcon.iconset"
iconutil --convert icns "$stage_dir/AppIcon.iconset" --output "$bundle/Contents/Resources/AppIcon.icns"
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign "$signing_identity" --identifier dev.zafe.local --timestamp=none "$bundle"
codesign --verify --deep --strict "$bundle"
ditto "$bundle" "$project_dir/dist/ZaFe.app"
printf '\nBuilt: %s\n' "$project_dir/dist/ZaFe.app"
