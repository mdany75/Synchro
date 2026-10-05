#!/bin/bash
# Compile Synchro et assemble Synchro.app (aucun Xcode requis, seulement les Command Line Tools).
# Avec l'argument « dmg », produit aussi build/Synchro.dmg pour la distribution.
set -euo pipefail
cd "$(dirname "$0")"

# Binaire universel : Apple Silicon et Intel.
swift build -c release --arch arm64 --arch x86_64
APP="build/Synchro.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Synchro "$APP/Contents/MacOS/Synchro"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Synchro</string>
    <key>CFBundleDisplayName</key><string>Synchro</string>
    <key>CFBundleIdentifier</key><string>com.mdany75.synchro</string>
    <key>CFBundleExecutable</key><string>Synchro</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Synchro lit le disque source pour le synchroniser.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Synchro écrit sur le NAS pour y copier la source.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "OK : $APP"

if [ "${1:-}" = "dmg" ]; then
    STAGE="build/dmg"
    rm -rf "$STAGE" build/Synchro.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Synchro" -srcfolder "$STAGE" -ov -format UDZO build/Synchro.dmg >/dev/null
    rm -rf "$STAGE"
    echo "OK : build/Synchro.dmg"
fi
