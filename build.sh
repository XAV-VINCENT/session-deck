#!/usr/bin/env bash
# Builds "Session Deck.app" and installs it in ~/Applications (pass --no-install to only build).
# Pictures and icon: .build/release/SessionDeck --render-assets docs/images (then move AppIcon.icns to Resources/).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app="build/Session Deck.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SessionDeck "$app/Contents/MacOS/SessionDeck"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $app"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x SessionDeck 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Session Deck.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/Session Deck.app"
  echo "Installed and started ~/Applications/Session Deck.app"
fi
