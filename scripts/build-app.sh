#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/RoughScore-module-cache"
export SWIFT_MODULECACHE_PATH="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --cache-path "${TMPDIR:-/tmp}/RoughScore-spm-cache" -c release -debug-info-format none
app="build/RoughScore.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/RoughScore "$app/Contents/MacOS/RoughScore"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RoughScore</string>
<key>CFBundleDisplayName</key><string>RoughScore</string>
<key>CFBundleIdentifier</key><string>com.roughscore.sketch</string>
<key>CFBundleExecutable</key><string>RoughScore</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>com.roughscore.project</string>
<key>UTTypeDescription</key><string>RoughScore Project</string>
<key>UTTypeConformsTo</key><array><string>public.json</string></array>
<key>UTTypeTagSpecification</key><dict>
<key>public.filename-extension</key><array><string>roughscore</string></array>
</dict></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "Built: $PWD/$app"
