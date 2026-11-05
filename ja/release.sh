#!/bin/bash
# Builds build-ja/build/{BurrowJA.dmg,BurrowJA.zip,appcast.xml} for a GitHub release.
# Needs the Sparkle signing key in the login Keychain. Bump ja/VERSION first.
set -euo pipefail

cd "$(dirname "$0")/.."
python3 ja/apply_ja.py
cd build-ja
scripts/bundle.sh
scripts/dmg.sh
ditto -c -k --keepParent "build/Burrow JA.app" build/BurrowJA.zip
scripts/appcast.sh
ls -la build
