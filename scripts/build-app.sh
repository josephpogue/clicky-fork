#!/usr/bin/env bash
# Builds Clicky Fork with xcodebuild and prints the absolute path of the app as its last line.
#
#   scripts/build-app.sh [--configuration Debug|Release] [--install]
#
# Signing team: $CLICKY_DEVELOPMENT_TEAM, else the team of the first "Apple Development"
# identity in the keychain. With neither, the app is signed ad hoc and a warning is printed.
# --install copies the app to /Applications, after asking a running copy to quit.
# The script never launches the app.
set -euo pipefail

configuration="Debug"
should_install="no"
while [ $# -gt 0 ]; do
  case "$1" in
    --configuration)
      [ $# -ge 2 ] || { echo "error: --configuration needs Debug or Release" >&2; exit 2; }
      configuration="$2"; shift 2 ;;
    --install) should_install="yes"; shift ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$configuration" in
  Debug|Release) ;;
  *) echo "error: --configuration must be Debug or Release" >&2; exit 2 ;;
esac

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_path="$repository_root/build/DerivedData"
bundle_identifier="com.clickyfork.app"
product_file_name="Clicky Fork.app"

# Find the signing team.
development_team="${CLICKY_DEVELOPMENT_TEAM:-}"
if [ -z "$development_team" ]; then
  identity_name="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9][0-9]*) [0-9A-F]* "\(Apple Development:[^"]*\)".*/\1/p' | head -n 1 || true)"
  if [ -n "$identity_name" ]; then
    development_team="$(security find-certificate -c "$identity_name" -p 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -n 1 || true)"
  fi
fi

signing_arguments=()
if [ -n "$development_team" ]; then
  signing_arguments=(DEVELOPMENT_TEAM="$development_team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
else
  echo "warning: no Apple Development identity found; signing ad hoc. Permissions will need re-granting after each rebuild." >&2
  signing_arguments=(CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES)
fi

build_log="$(mktemp -t clicky-fork-build)"
set +e
xcodebuild \
  -project "$repository_root/leanring-buddy.xcodeproj" \
  -scheme leanring-buddy \
  -configuration "$configuration" \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data_path" \
  "${signing_arguments[@]}" \
  build >"$build_log" 2>&1
build_status=$?
set -e
if [ "$build_status" -ne 0 ]; then
  echo "Build failed. First errors:" >&2
  grep -m 10 'error:' "$build_log" >&2 || tail -n 20 "$build_log" >&2
  echo "Full log: $build_log" >&2
  exit "$build_status"
fi
rm -f "$build_log"

built_app_path="$derived_data_path/Build/Products/$configuration/$product_file_name"
[ -d "$built_app_path" ] || { echo "error: built app not found at $built_app_path" >&2; exit 1; }

# Build the brain helper (the MCP program the Claude CLI starts to serve the two brain tools) and put it in the bundle.
# It is signed with the identity the app was signed with, then the app is re-signed so its seal covers the helper
# while its designated requirement stays the same (macOS permissions survive rebuilds).
package_path="$repository_root/Packages/ClickyCore"
helper_swift_configuration="release"
[ "$configuration" = "Debug" ] && helper_swift_configuration="debug"
helper_build_log="$(mktemp -t clicky-fork-helper-build)"
if ! swift build -c "$helper_swift_configuration" --package-path "$package_path" --product ClickyBrainTools >"$helper_build_log" 2>&1; then
  echo "Helper build failed. First errors:" >&2
  grep -m 10 'error:' "$helper_build_log" >&2 || tail -n 20 "$helper_build_log" >&2
  echo "Full log: $helper_build_log" >&2
  exit 1
fi
rm -f "$helper_build_log"
helper_binary_path="$(swift build -c "$helper_swift_configuration" --package-path "$package_path" --show-bin-path)/ClickyBrainTools"
[ -f "$helper_binary_path" ] || { echo "error: built helper not found at $helper_binary_path" >&2; exit 1; }
bundled_helper_path="$built_app_path/Contents/MacOS/ClickyBrainTools"
cp -f "$helper_binary_path" "$bundled_helper_path"

# The signing identity of the app: its authority line, or ad hoc when it was signed that way.
app_signature_details="$(codesign -dvv "$built_app_path" 2>&1 || true)"
signing_identity="-"
if ! printf '%s\n' "$app_signature_details" | grep -q '^Signature=adhoc'; then
  signing_identity="$(printf '%s\n' "$app_signature_details" | sed -n 's/^Authority=\(Apple Development:.*\)$/\1/p' | head -n 1)"
  [ -n "$signing_identity" ] || signing_identity="-"
fi
codesign --force --sign "$signing_identity" --options runtime "$bundled_helper_path"
codesign --force --sign "$signing_identity" \
  --preserve-metadata=identifier,entitlements,requirements,flags,runtime "$built_app_path"

if [ "$should_install" = "yes" ]; then
  installed_app_path="/Applications/$product_file_name"
  if pgrep -f "$installed_app_path/Contents/MacOS/" >/dev/null 2>&1 \
     || osascript -e "application id \"$bundle_identifier\" is running" 2>/dev/null | grep -q true; then
    osascript -e "quit app id \"$bundle_identifier\"" >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      osascript -e "application id \"$bundle_identifier\" is running" 2>/dev/null | grep -q true || break
      sleep 0.5
    done
    if osascript -e "application id \"$bundle_identifier\" is running" 2>/dev/null | grep -q true; then
      echo "error: Clicky Fork is still running; quit it and run again." >&2
      exit 1
    fi
  fi
  rm -rf "$installed_app_path"
  cp -R "$built_app_path" "$installed_app_path"
  echo "$installed_app_path"
else
  echo "$built_app_path"
fi
