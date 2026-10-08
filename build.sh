#!/bin/bash
# Compile Synchro, lance les tests, assemble build/Synchro.app et produit build/Synchro.dmg
# (aucun Xcode requis, seulement les Command Line Tools).
#   ./build.sh            tests, app et image disque
#   ./build.sh --install  idem, puis installe l'app dans /Applications
#   SKIP_TESTS=1          saute les tests ; ALLOW_DIRTY=1 tolère des modifications non validées dans git
#   SIGN_IDENTITY="-"     signature ad hoc même si un certificat est présent
#   SKIP_NOTARIZE=1       signe avec le certificat mais ne notarise pas (essai rapide)
#   NOTARY_PROFILE=nom    profil de « xcrun notarytool store-credentials » (défaut : notarisation)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.4}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCHS=(--arch arm64 --arch x86_64)   # binaire universel : Apple Silicon et Intel

# Une image publiée doit correspondre à un état enregistré du dépôt.
if [ -n "$(git status --porcelain 2>/dev/null)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "Erreur : des modifications ne sont pas validées dans git (ALLOW_DIRTY=1 pour passer outre)." >&2
    exit 1
fi
[ -n "${SKIP_TESTS:-}" ] || ./test.sh

# --- Signature et notarisation ------------------------------------------------
#
# Avec le certificat « Developer ID Application » dans le trousseau, le code est signé avec
# le runtime durci, puis ce qui est distribué est notarisé chez Apple : il s'ouvre sans
# avertissement sur n'importe quel Mac, et macOS conserve les autorisations accordées d'une
# version à l'autre (l'identité ne change plus). Sans certificat (autre machine), signature
# ad hoc et pas de notarisation.

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarisation}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    SIGN_ARGS=(--sign -)
    NOTARIZE=0; NOTARIZE_WHY="signature ad hoc, aucun certificat Developer ID"
elif [[ "${SKIP_NOTARIZE:-0}" != "0" ]]; then
    SIGN_ARGS=(--options runtime --timestamp --sign "${SIGN_IDENTITY}")
    NOTARIZE=0; NOTARIZE_WHY="SKIP_NOTARIZE=1"
else
    SIGN_ARGS=(--options runtime --timestamp --sign "${SIGN_IDENTITY}")
    NOTARIZE=1; NOTARIZE_WHY=""
fi

# sign_code OPTIONS… CHEMIN : signe, puis vérifie. Le serveur d'horodatage d'Apple renvoie
# parfois une heure décalée de quelques minutes, que « codesign --verify --strict » refuse
# (« timestamps differ ») : on signe alors de nouveau, jusqu'à trois fois.
sign_code() {
    local attempt
    for attempt in 1 2 3; do
        codesign --force "$@"
        codesign --verify --deep --strict "${@:$#}" && return 0
        printf 'Vérification de la signature refusée (essai %s/3), nouvelle signature…\n' "${attempt}" >&2
        sleep 2
    done
    echo "Erreur : signature impossible à vérifier : ${@:$#}" >&2
    exit 1
}

# notarize_file FICHIER : soumet l'archive ou l'image disque à Apple et attend le verdict
# (quelques minutes).
notarize_file() {
    local file="$1" output id
    echo "Notarisation de « $(basename "${file}") » (profil « ${NOTARY_PROFILE} »), quelques minutes…"
    if ! output="$(xcrun notarytool submit "${file}" --keychain-profile "${NOTARY_PROFILE}" --wait 2>&1)"; then
        printf '%s\n' "${output}" >&2
        echo "Erreur : notarisation impossible : session verrouillée (le profil n'est lisible qu'écran déverrouillé) ou profil « ${NOTARY_PROFILE} » absent (xcrun notarytool store-credentials)." >&2
        exit 1
    fi
    printf '%s\n' "${output}"
    if ! grep -q '^ *status: Accepted' <<< "${output}"; then
        id="$(sed -n 's/^ *id: //p' <<< "${output}" | head -n 1)"
        [[ -z "${id}" ]] || xcrun notarytool log "${id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
        echo "Erreur : notarisation refusée par Apple (détail ci-dessus)." >&2
        exit 1
    fi
}

# finalize_dmg FICHIER : signe l'image disque, la notarise, agrafe le ticket et vérifie que
# Gatekeeper l'accepte. Sans notarisation, dit seulement pourquoi.
finalize_dmg() {
    local dmg="$1"
    if [[ "${NOTARIZE}" -eq 0 ]]; then
        echo "Image disque non notarisée (${NOTARIZE_WHY}) : avertissement de macOS sur un autre Mac."
        return 0
    fi
    sign_code --timestamp --sign "${SIGN_IDENTITY}" "${dmg}"
    notarize_file "${dmg}"
    echo "Agrafage du ticket et vérification Gatekeeper…"
    xcrun stapler staple "${dmg}"
    spctl -a -t open --context context:primary-signature -vv "${dmg}"
}

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

sign_code "${SIGN_ARGS[@]}" "$APP"
echo "OK : $APP (version $VERSION, build $BUILD, signature : $SIGN_IDENTITY)"

STAGE="build/dmg"
{
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
    finalize_dmg build/Synchro.dmg
    echo "OK : build/Synchro.dmg (version $VERSION, build $BUILD)"
}

if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Synchro.app
    cp -R "$APP" /Applications/
    echo "OK : installée dans /Applications"
fi
