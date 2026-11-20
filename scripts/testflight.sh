#!/usr/bin/env bash
# Builds the iOS app for App Store Connect and, with --upload, sends it to
# TestFlight.
#
#   scripts/testflight.sh                  build, sign, export and check the IPA
#   scripts/testflight.sh --upload         the same, then upload it
#   scripts/testflight.sh --build-name 1.2.0 --build-number 42
#
# Needs: macOS with Xcode, Flutter on PATH, the team's "Apple Distribution"
# certificate in the keychain, and that team's Apple account signed in to Xcode
# (Settings > Accounts). No password or API key is read by this script: signing
# and upload go through Xcode's own account.
#
# The team comes from AC_IOS_TEAM_ID, or from DEVELOPMENT_TEAM in
# ios/Flutter/Environment.local.xcconfig (git-ignored).
#
# Why it is not just `flutter build ipa`:
#   - Xcode's automatic signing needs a development profile to archive, and a
#     team with no registered devices cannot have one. So the archive is built
#     unsigned.
#   - An unsigned archive carries no entitlements, and the export step would
#     then drop Associated Domains. So the app in the archive is ad-hoc signed
#     with the app's entitlements first; the export step re-signs everything
#     with the distribution certificate and keeps them.
set -euo pipefail

upload=false
build_name=""
build_number=""
while [ $# -gt 0 ]; do
  case "$1" in
    --upload) upload=true ;;
    --build-name) build_name="${2:?--build-name needs a value}"; shift ;;
    --build-number) build_number="${2:?--build-number needs a value}"; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
[ "$(uname)" = "Darwin" ] || die "this needs macOS with Xcode"
command -v flutter >/dev/null || die "flutter is not on PATH"
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)"

# A compiler override from the shell profile (CC=/opt/homebrew/...) breaks
# Xcode builds against the iOS SDK.
unset CC CXX

# Reads NAME from the xcconfig files, the local override winning.
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

team="${AC_IOS_TEAM_ID:-$(xcconfig DEVELOPMENT_TEAM)}"
[ -n "$team" ] || die "no team: set AC_IOS_TEAM_ID, or DEVELOPMENT_TEAM in ios/Flutter/Environment.local.xcconfig"
security find-identity -v -p codesigning | grep -q "Apple Distribution: .*($team)" \
  || die "no \"Apple Distribution\" certificate for team $team in the keychain"

bundle_id="$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER = \([^;]*\);.*/\1/p' ios/Runner.xcodeproj/project.pbxproj | grep -v RunnerTests | sort -u | head -1)"
[ -n "$bundle_id" ] || die "could not read the bundle identifier from the Xcode project"
[ -n "$build_name" ] || build_name="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' pubspec.yaml)"
# App Store Connect needs a build number higher than the last upload of this
# version: the hour, as yyMMddHH, is unique enough and stays below 2^31.
[ -n "$build_number" ] || build_number="$(date +%y%m%d%H)"
env_name="$(xcconfig AC_ENV_NAME)"

echo "App:         $bundle_id"
echo "Version:     $build_name ($build_number)"
echo "Team:        $team"
echo "Environment: ${env_name:-?} (API $(xcconfig AC_API_HOST))"
echo "Commit:      $(git rev-parse --short HEAD 2>/dev/null || echo '?')$(git diff --quiet HEAD -- lib ios pubspec.yaml 2>/dev/null || echo ' + uncommitted changes')"
$upload && echo "Upload:      yes" || echo "Upload:      no (pass --upload to send it to TestFlight)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
archive="build/ios/archive/Runner.xcarchive"
out="build/ios/ipa"

step "Building the archive (unsigned)"
flutter --no-version-check pub get >/dev/null
flutter --no-version-check gen-l10n >/dev/null
rm -rf "$archive" "$out"
flutter --no-version-check build ipa --release --no-codesign \
  --build-name="$build_name" --build-number="$build_number"
app="$archive/Products/Applications/Runner.app"
[ -d "$app" ] || die "the archive has no Runner.app"

step "Attaching the app's entitlements"
# Runner.entitlements names its hosts through xcconfig variables; put the values in.
entitlements="$work/Runner.entitlements"
cp ios/Runner/Runner.entitlements "$entitlements"
while grep -q '\$([A-Za-z_][A-Za-z0-9_]*)' "$entitlements"; do
  var="$(sed -n 's/.*\$(\([A-Za-z_][A-Za-z0-9_]*\)).*/\1/p' "$entitlements" | head -1)"
  value="$(xcconfig "$var")"
  [ -n "$value" ] || die "Runner.entitlements uses \$($var), which the xcconfig files do not set"
  sed -i '' "s|\$($var)|$value|g" "$entitlements"
done
plutil -lint "$entitlements" >/dev/null || die "the resolved entitlements are not a valid plist"
find "$app/Frameworks" -maxdepth 1 -name '*.framework' -print0 2>/dev/null \
  | while IFS= read -r -d '' framework; do codesign --force --sign - "$framework" 2>/dev/null; done
codesign --force --sign - --entitlements "$entitlements" "$app" 2>/dev/null

export_options() { # destination -> plist path
  local plist="$work/ExportOptions-$1.plist"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$1</string>
	<key>teamID</key><string>$team</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
  printf '%s' "$plist"
}

step "Signing and exporting the IPA"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
  -exportOptionsPlist "$(export_options export)" -allowProvisioningUpdates > "$work/export.log" 2>&1 \
  || { grep -E 'error' "$work/export.log" >&2 || tail -20 "$work/export.log" >&2
       die "export failed (is the team's Apple account signed in to Xcode?)"; }
ipa="$(find "$out" -maxdepth 1 -name '*.ipa' | head -1)"
[ -f "$ipa" ] || die "the export produced no .ipa"

step "Checking the IPA"
unzip -q "$ipa" -d "$work/ipa"
signed="$work/ipa/Payload/Runner.app"
plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$signed/Info.plist" 2>/dev/null; }
[ "$(plist_value CFBundleIdentifier)" = "$bundle_id" ] || die "IPA bundle id is $(plist_value CFBundleIdentifier), expected $bundle_id"
[ "$(plist_value CFBundleShortVersionString)" = "$build_name" ] || die "IPA version is $(plist_value CFBundleShortVersionString), expected $build_name"
[ "$(plist_value CFBundleVersion)" = "$build_number" ] || die "IPA build is $(plist_value CFBundleVersion), expected $build_number"
codesign --verify --deep --strict "$signed" 2>/dev/null || die "the IPA's signature does not verify"
signature="$(codesign -dvv "$signed" 2>&1)"
echo "$signature" | grep -q "^TeamIdentifier=$team$" || die "the IPA is not signed by team $team"
echo "$signature" | grep -q "^Authority=Apple Distribution" || die "the IPA is not signed with a distribution certificate"
signed_entitlements="$(codesign -d --entitlements :- "$signed" 2>/dev/null | plutil -p - 2>/dev/null || true)"
# Every entitlement the project asks for must have survived the export.
for key in $(/usr/libexec/PlistBuddy -c Print "$entitlements" | sed -n 's/^    \([A-Za-z0-9.-]*\) = .*/\1/p'); do
  echo "$signed_entitlements" | grep -q "\"$key\"" || die "the IPA lost the entitlement $key"
done
echo "$signed_entitlements" | grep -q '"get-task-allow" => false' || die "the IPA is debuggable (get-task-allow)"
echo "OK: $ipa ($(du -h "$ipa" | cut -f1 | tr -d ' '))"

if ! $upload; then
  printf '\nNot uploaded. Run again with --upload to send this build to TestFlight.\n'
  exit 0
fi

step "Uploading to App Store Connect"
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$work/upload" \
  -exportOptionsPlist "$(export_options upload)" -allowProvisioningUpdates > "$work/upload.log" 2>&1 \
  || { grep -E 'error' "$work/upload.log" >&2 || tail -20 "$work/upload.log" >&2; die "upload failed"; }
grep -E '^warning: ' "$work/upload.log" | cut -c1-300 || true
grep -q 'Upload succeeded' "$work/upload.log" || die "xcodebuild finished without reporting a successful upload"
cat <<EOF

Uploaded $build_name ($build_number). Apple now processes the build; then add
testers in App Store Connect > TestFlight. (Info.plist declares the app's
encryption exempt, so there is no export compliance question; see the README.)
EOF
