#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/VoicePrompt"
INSTALLED_APP="$HOME/Applications/VoicePromptMac.app"
BUILT_APP="$DERIVED_DATA/Build/Products/Debug/VoicePromptMac.app"
BUNDLE_IDENTIFIER="com.michalmar.voiceprompt.macos"

find_signing_identity() {
    local identities identity
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    identity="$(printf '%s\n' "$identities" | awk -F'"' '/"Apple Development:/{print $2; exit}')"
    if [[ -z "$identity" ]]; then
        identity="$(printf '%s\n' "$identities" | awk -F'"' '/"Developer ID Application:/{print $2; exit}')"
    fi
    printf '%s' "$identity"
}

designated_requirement() {
    codesign -dr - "$1" 2>&1 \
        | sed -nE 's/^#?[[:space:]]*designated => //p' \
        || true
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Error: this script requires macOS and Xcode." >&2
    exit 1
fi

cd "$REPO_ROOT"

if [[ ! -f Apple/Configuration.xcconfig ]]; then
    echo "Error: configure Apple/Configuration.xcconfig before installing. See docs/configuration.md." >&2
    exit 1
fi

if pgrep -x VoicePromptMac >/dev/null; then
    echo "Error: quit VoicePrompt from its menu-bar menu, then run this script again." >&2
    exit 1
fi

PREVIOUS_REQUIREMENT=""
if [[ -d "$INSTALLED_APP" ]]; then
    PREVIOUS_REQUIREMENT="$(designated_requirement "$INSTALLED_APP")"
fi

SIGNING_IDENTITY="${VOICEPROMPT_CODE_SIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(find_signing_identity)"
fi

SIGNING_ARGUMENTS=(CODE_SIGNING_ALLOWED=YES)
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
    echo "Using stable signing identity: $SIGNING_IDENTITY"
    SIGNING_ARGUMENTS+=(
        "CODE_SIGN_IDENTITY=$SIGNING_IDENTITY"
        CODE_SIGN_STYLE=Manual
    )
else
    echo "Warning: no stable code-signing identity was found; using ad-hoc signing." >&2
    echo "Accessibility permission will need to be granted again after each rebuild." >&2
    SIGNING_ARGUMENTS+=(CODE_SIGN_IDENTITY=-)
fi

echo "Building VoicePrompt for macOS..."
make apple-project
xcodebuild -quiet \
    -project Apple/VoicePrompt.xcodeproj \
    -scheme VoicePromptMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    "${SIGNING_ARGUMENTS[@]}" \
    build

if [[ ! -d "$BUILT_APP" ]]; then
    echo "Error: the macOS build did not produce $BUILT_APP." >&2
    exit 1
fi

NEW_REQUIREMENT="$(designated_requirement "$BUILT_APP")"

echo "Installing to $INSTALLED_APP..."
mkdir -p "$HOME/Applications"
ditto "$BUILT_APP" "$INSTALLED_APP"

if [[ -n "$PREVIOUS_REQUIREMENT" && "$PREVIOUS_REQUIREMENT" != "$NEW_REQUIREMENT" ]]; then
    if tccutil reset Accessibility "$BUNDLE_IDENTIFIER"; then
        echo "The app's signing identity changed, so stale Accessibility access was reset."
        echo "Grant Accessibility access once when VoicePrompt requests direct paste."
    else
        echo "Warning: macOS could not reset stale Accessibility access automatically." >&2
        echo "Remove VoicePrompt from Privacy & Security > Accessibility, then add $INSTALLED_APP." >&2
    fi
fi

open "$INSTALLED_APP"
echo "VoicePrompt is installed and launching in the menu bar."
