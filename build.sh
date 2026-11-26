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
# Sign with a real identity when this Mac has one. An ad-hoc signature carries no Team
# Identifier, and the notification daemon will not register an app that has none: the
# request either errors with "Notifications are not allowed for this application" or
# never calls back at all, depending on how the app was launched. Session Deck then
# falls back to its own banner and a sound, which need no permission. Set SIGN_IDENTITY
# to override the search; Developer ID wins over Apple Development because it is the one
# another Mac will also accept.
identity="${SIGN_IDENTITY:-}"
for prefix in "Developer ID Application" "Apple Development"; do
  [[ -n "$identity" ]] && break
  identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n "s/.*\"\($prefix:[^\"]*\)\".*/\1/p" | head -1)
done

if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" "$app"
  echo "Signed as $identity"
else
  codesign --force --sign - "$app"
  echo "Signed ad hoc: no code-signing identity on this Mac, so Notification Centre will"
  echo "refuse to register the app and alerts will use the banner and a sound. Adding an"
  echo "Apple ID in Xcode > Settings > Accounts creates a free one."
fi
echo "Built $app"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x SessionDeck 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Session Deck.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/Session Deck.app"
  echo "Installed and started ~/Applications/Session Deck.app"
fi
