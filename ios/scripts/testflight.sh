#!/bin/zsh
# Builds the app and uploads it to TestFlight, signed in with the team's App Store Connect API key instead of the
# Xcode account, so an expired sign-in in Xcode no longer stops an upload.
#
#   ios/scripts/testflight.sh           raises the build number by one, archives, uploads
#   ios/scripts/testflight.sh --same    uploads with the build number as it stands
#
# The key is not part of the repository. It is read from ~/.appstoreconnect/reiseplaner.env (ASC_KEY_ID, ASC_ISSUER_ID)
# and ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8.
set -euo pipefail

here="${0:A:h}"
ios="${here:h}"
env_file="$HOME/.appstoreconnect/reiseplaner.env"
[[ -f "$env_file" ]] || { echo "Fehlt: $env_file (ASC_KEY_ID und ASC_ISSUER_ID)"; exit 1; }
source "$env_file"
: "${ASC_KEY_ID:?ASC_KEY_ID fehlt in $env_file}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt in $env_file}"
key="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
[[ -f "$key" ]] || { echo "Fehlt: der Schlüssel AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys"; exit 1; }
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

project="$ios/TravelPlanner.xcodeproj"
pbx="$project/project.pbxproj"
build=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$pbx" | grep -o '[0-9]*$')
if [[ "${1:-}" != "--same" ]]; then
  next=$((build + 1))
  sed -i '' "s/CURRENT_PROJECT_VERSION = ${build};/CURRENT_PROJECT_VERSION = ${next};/g" "$pbx"
  build=$next
fi
echo "Build $build"

work=$(mktemp -d)
archive="$HOME/Library/Developer/Xcode/Archives/TravelPlanner-testflight.xcarchive"
xcodebuild -project "$project" -scheme TravelPlanner -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive" "${auth[@]}" archive > "$work/archive.log" 2>&1 \
  || { grep -E "error:|ARCHIVE" "$work/archive.log" | head -20; echo "Archiv fehlgeschlagen, Protokoll: $work/archive.log"; exit 1; }
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$ios/Config/ExportOptions-TestFlight.plist" \
  -exportPath "$work/upload" "${auth[@]}" > "$work/export.log" 2>&1 \
  || { grep -E "error|EXPORT" "$work/export.log" | head -20; echo "Upload fehlgeschlagen, Protokoll: $work/export.log"; exit 1; }
grep -q "Upload succeeded" "$work/export.log" || { echo "Kein „Upload succeeded“ im Protokoll: $work/export.log"; exit 1; }
echo "Build $build ist bei TestFlight hochgeladen."
