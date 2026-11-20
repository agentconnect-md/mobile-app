#!/usr/bin/env bash
# Builds the macOS app and wraps it in a DMG to hand to people directly
# (no App Store, no TestFlight).
#
#   scripts/dmg.sh                         build and make an unsigned DMG
#   scripts/dmg.sh --identity "Developer ID Application: Name (TEAMID)"
#                                          the same, signed with that certificate
#   scripts/dmg.sh --identity "…" --notary-profile ac-notary
#                                          signed, notarized by Apple and stapled
#   scripts/dmg.sh --build-name 1.2.0 --build-number 42
#
# The identity can also come from AC_MAC_IDENTITY and the profile from
# AC_NOTARY_PROFILE. Without them the steps that need them are skipped, and
# the script says so.
#
# Needs: macOS with Xcode, Flutter on PATH. For signing: a "Developer ID
# Application" certificate in the keychain (Apple Developer account >
# Certificates; only the Account Holder can create one). For notarizing: a
# keychain profile made once with
#   xcrun notarytool store-credentials ac-notary --apple-id <id> --team-id <TEAMID>
# (it asks for an app-specific password and keeps it in the keychain; this
# script never sees a password). Notarizing sends the DMG to Apple; nothing
# else leaves the Mac, and the script never uploads or publishes the DMG.
#
# What the signing step does, and why it is not left to Xcode:
#   - `flutter build macos` signs ad hoc ("Sign to Run Locally"). Developer ID
#     distribution needs every nested framework and the app signed with the
#     Developer ID certificate, the hardened runtime on (notarization requires
#     it) and a secure timestamp. So the built app is re-signed here, inside
#     out, with the app's own entitlements (macos/Runner/Release.entitlements:
#     App Sandbox, outgoing network, files the person chooses).
#   - No provisioning profile is involved: none of those entitlements needs one.
set -euo pipefail

identity="${AC_MAC_IDENTITY:-}"
profile="${AC_NOTARY_PROFILE:-}"
build_name=""
build_number=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity) identity="${2:?--identity needs a value}"; shift ;;
    --notary-profile) profile="${2:?--notary-profile needs a value}"; shift ;;
    --build-name) build_name="${2:?--build-name needs a value}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
skip() { printf '\n--  %s\n' "$*"; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[ "$(uname)" = "Darwin" ] || die "this needs macOS with Xcode"
command -v flutter >/dev/null || die "flutter is not on PATH"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"
[ -d macos ] || die "no macos/ folder here"

# A compiler override from the shell profile (CC=/opt/homebrew/...) breaks Xcode builds.
unset CC CXX

# Reads NAME from the xcconfig files the build uses, the local override winning.
xcconfig() {
  local name="$1" file value=""
  for file in ios/Flutter/Environment.xcconfig ios/Flutter/Environment.local.xcconfig; do
    [ -f "$file" ] || continue
    local found
    found="$(sed -n "s|^[[:space:]]*$name[[:space:]]*=[[:space:]]*||p" "$file" | sed 's|[[:space:]]*//.*$||; s|[[:space:]]*$||' | tail -1)"
    [ -n "$found" ] && value="$found"
  done
  printf '%s' "$value"
}

if [ -n "$identity" ]; then
  case "$identity" in
    "Developer ID Application:"*) ;;
    *) die "--identity must be a \"Developer ID Application: …\" certificate (got \"$identity\"); other certificates do not pass Gatekeeper" ;;
  esac
  security find-identity -v -p codesigning | grep -qF "\"$identity\"" \
    || die "no certificate \"$identity\" in the keychain (see: security find-identity -v -p codesigning)"
fi
[ -z "$profile" ] || [ -n "$identity" ] || die "--notary-profile needs --identity: Apple only notarizes Developer ID signed apps"

[ -n "$build_name" ] || build_name="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"
[ -n "$build_number" ] || build_number="$(date +%y%m%d%H)"
env_name="$(xcconfig AC_ENV_NAME)"

echo "Version:     $build_name ($build_number)"
echo "Environment: ${env_name:-?} (API $(xcconfig AC_API_HOST))"
echo "Commit:      $(git rev-parse --short HEAD 2>/dev/null || echo '?')$(git diff --quiet HEAD -- lib macos ios/Flutter pubspec.yaml 2>/dev/null || echo ' + uncommitted changes')"
echo "Signing:     ${identity:-none (unsigned DMG)}"
echo "Notarizing:  ${profile:-no}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out="build/macos/dmg"

step "Building the app (release)"
flutter --no-version-check pub get >/dev/null
flutter --no-version-check gen-l10n >/dev/null
flutter --no-version-check build macos --release \
  --build-name="$build_name" --build-number="$build_number"
app="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' | head -1)"
[ -d "$app" ] || die "the build produced no .app"
name="$(basename "$app" .app)"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null; }
bundle_id="$(plist_value CFBundleIdentifier)"
[ "$(plist_value CFBundleShortVersionString)" = "$build_name" ] || die "the app's version is $(plist_value CFBundleShortVersionString), expected $build_name"
echo "App:         $app ($bundle_id)"

# The app goes into the DMG from a copy, so the build folder stays as built.
stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/$name.app"
staged="$stage/$name.app"

if [ -n "$identity" ]; then
  step "Signing with $identity"
  entitlements="macos/Runner/Release.entitlements"
  plutil -lint "$entitlements" >/dev/null || die "$entitlements is not a valid plist"
  sign() { codesign --force --options runtime --timestamp --sign "$identity" "$@"; }
  # Inside out: loose libraries and helper executables, then each framework, then the app.
  find "$staged/Contents" -type f \( -name '*.dylib' -o -perm +111 \) ! -path "$staged/Contents/MacOS/*" -print0 \
    | while IFS= read -r -d '' file; do
        file "$file" | grep -q 'Mach-O' && sign "$file" >/dev/null 2>&1 || true
      done
  find "$staged/Contents/Frameworks" -depth -name '*.framework' -print0 2>/dev/null \
    | while IFS= read -r -d '' framework; do sign "$framework"; done
  sign --entitlements "$entitlements" "$staged"

  step "Checking the signature"
  codesign --verify --deep --strict "$staged" || die "the app's signature does not verify"
  signature="$(codesign -dvv "$staged" 2>&1)"
  echo "$signature" | grep -q '^Authority=Developer ID Application' || die "the app is not signed with a Developer ID certificate"
  echo "$signature" | grep -q 'flags=.*runtime' || die "the hardened runtime is not on"
  signed_entitlements="$(codesign -d --entitlements :- "$staged" 2>/dev/null | plutil -p - 2>/dev/null || true)"
  for key in $(/usr/libexec/PlistBuddy -c Print "$entitlements" | sed -n 's/^    \([A-Za-z0-9.-]*\) = .*/\1/p'); do
    echo "$signed_entitlements" | grep -q "\"$key\"" || die "the signed app lost the entitlement $key"
  done
  echo "$signed_entitlements" | grep -q 'get-task-allow' && die "the app is debuggable (get-task-allow)"
  echo "OK: $(echo "$signature" | sed -n 's/^Authority=\(Developer ID Application.*\)/\1/p')"
else
  skip "Not signed: no --identity (or AC_MAC_IDENTITY). The DMG will hold the ad hoc signed build;
    Gatekeeper blocks it on other Macs until the person allows it (see README, \"macOS\")."
fi

step "Making the DMG"
ln -s /Applications "$stage/Applications"
mkdir -p "$out"
suffix=""
[ -n "$identity" ] || suffix="-unsigned"
[ "$env_name" = "Production" ] || [ -z "$env_name" ] || suffix="-$(printf '%s' "$env_name" | tr '[:upper:]' '[:lower:]')$suffix"
dmg="$out/$name-$build_name$suffix.dmg"
rm -f "$dmg"
hdiutil create -volname "$name" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" >/dev/null
[ -n "$identity" ] && codesign --force --timestamp --sign "$identity" "$dmg"

if [ -n "$profile" ]; then
  step "Notarizing (sends the DMG to Apple; usually a few minutes)"
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait | tee "$work/notary.log"
  grep -q 'status: Accepted' "$work/notary.log" \
    || die "Apple did not accept it; see: xcrun notarytool log <id above> --keychain-profile $profile"
  step "Stapling the ticket"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg" 2>&1 || die "Gatekeeper does not accept the DMG"
elif [ -n "$identity" ]; then
  skip "Not notarized: no --notary-profile (or AC_NOTARY_PROFILE). A signed but not notarized
    app is still blocked by Gatekeeper on other Macs, like an unsigned one."
else
  skip "Not notarized: only a Developer ID signed app can be."
fi

( cd "$out" && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256" )
printf '\nDMG:    %s (%s)\nSHA256: %s\n' "$dmg" "$(du -h "$dmg" | cut -f1 | tr -d ' ')" "$(cut -d' ' -f1 "$dmg.sha256")"
if [ -n "$profile" ]; then
  echo "Signed, notarized and stapled: opens on any Mac with the usual \"downloaded from the internet\" question."
elif [ -n "$identity" ]; then
  echo "Signed, not notarized: for your own testing only."
else
  echo "Unsigned: for people who know to allow it in System Settings > Privacy & Security (see README)."
fi
echo "Nothing was uploaded or published."
