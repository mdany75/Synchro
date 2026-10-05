#!/bin/bash
# Lance les tests du moteur. Avec les seuls Command Line Tools, le module des macros de test
# n'est pas trouvé automatiquement : on indique son emplacement.
set -euo pipefail
cd "$(dirname "$0")"
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" "$@"
