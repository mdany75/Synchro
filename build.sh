#!/bin/bash
# Compile Synchro et assemble build/Synchro.app (aucun Xcode requis, seulement les Command Line Tools).
# Avec l'argument « dmg », lance d'abord les tests puis produit aussi build/Synchro.dmg pour la distribution.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.1}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=(--arch arm64 --arch x86_64)   # binaire universel : Apple Silicon et Intel

if [ "${1:-}" = "dmg" ]; then
    # Une image publiée doit correspondre à un état enregistré du dépôt.
    if [ -n "$(git status --porcelain 2>/dev/null)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
        echo "Erreur : des modifications ne sont pas validées dans git (ALLOW_DIRTY=1 pour passer outre)." >&2
        exit 1
    fi
    ./test.sh
fi

swift build -c release "${ARCHS[@]}" --product Synchro
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Synchro"

APP="build/Synchro.app"
# L'ancienne image disque ne correspondrait plus à l'app reconstruite.
rm -rf "$APP" build/Synchro.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Synchro"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sans cela, le binaire publié contient les chemins du dossier de compilation, donc le nom du compte macOS.
strip -S -x "$APP/Contents/MacOS/Synchro"
if LC_ALL=C grep -a -q -F -e "/Users/" -e "$PWD" "$APP/Contents/MacOS/Synchro"; then
    echo "Erreur : le binaire contient encore un chemin local." >&2
    exit 1
fi
for arch in arm64 x86_64; do
    lipo -archs "$APP/Contents/MacOS/Synchro" | grep -qw "$arch" || { echo "Erreur : architecture $arch absente." >&2; exit 1; }
done

ACCESS="Synchro accède à ce dossier pour lire la source ou mettre à jour la destination de vos tâches."
cat > "$APP/Contents/Info.plist" <<EOF
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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>Synchro accède aux disques externes pour lire la source ou mettre à jour la destination de vos tâches.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>Synchro accède aux volumes réseau (NAS) pour lire la source ou mettre à jour la destination de vos tâches.</string>
    <key>NSDesktopFolderUsageDescription</key><string>$ACCESS</string>
    <key>NSDocumentsFolderUsageDescription</key><string>$ACCESS</string>
    <key>NSDownloadsFolderUsageDescription</key><string>$ACCESS</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "OK : $APP (version $VERSION, build $BUILD)"

if [ "${1:-}" = "dmg" ]; then
    STAGE="build/dmg"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    trap 'rm -rf "$STAGE" build/dmg.log' EXIT
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    # hdiutil annonce ce verbe comme obsolète mais reste l'outil présent sur toutes les versions prises en charge.
    if ! hdiutil create -volname "Synchro" -srcfolder "$STAGE" -ov -format UDZO build/Synchro.dmg >build/dmg.log 2>&1; then
        cat build/dmg.log >&2
        echo "Erreur : création de l'image disque impossible." >&2
        exit 1
    fi
    echo "OK : build/Synchro.dmg (version $VERSION, build $BUILD)"
fi
