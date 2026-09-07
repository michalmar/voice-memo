#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/VoicePrompt"
INSTALLED_APP="$HOME/Applications/VoicePromptMac.app"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this script requires macOS and Xcode." >&2
    exit 1
fi

cd "$REPO_ROOT"

if [[ ! -f Apple/Configuration.xcconfig ]]; then
    echo "Error: configure Apple/Configuration.xcconfig before installing. See docs/configuration.md." >&2
    exit 1
fi

echo "Building VoicePrompt for macOS..."
make apple-project
xcodebuild -quiet \
    -project Apple/VoicePrompt.xcodeproj \
    -scheme VoicePromptMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build

if pgrep -x VoicePromptMac >/dev/null; then
    echo "Error: quit VoicePrompt from its menu-bar menu, then run this script again." >&2
    exit 1
fi

echo "Installing to $INSTALLED_APP..."
mkdir -p "$HOME/Applications"
ditto "$DERIVED_DATA/Build/Products/Debug/VoicePromptMac.app" "$INSTALLED_APP"
open "$INSTALLED_APP"
echo "VoicePrompt is installed and launching in the menu bar."
