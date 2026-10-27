#!/usr/bin/env bash
# Run on a Mac with Xcode; GitHub Actions calls this same script.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

python3 tools/generate_project.py
plutil -lint HelloYrq.xcodeproj/project.pbxproj HelloYrq/Info.plist
xcodebuild -version

# No certificate, Apple ID, provisioning profile, or paid account is used here.
# The resulting IPA MUST be re-signed on Windows before installing on an iPhone.
xcodebuild \
  -project HelloYrq.xcodeproj -scheme HelloYrq -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
  build 2>&1 | tee build/device-build.log

APP='build/device/Build/Products/Release-iphoneos/HelloYrq.app'
test -f "$APP/HelloYrq"
file "$APP/HelloYrq" | tee build/binary-info.txt
file "$APP/HelloYrq" | grep -q arm64
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/HelloYrq.app
(cd build/package && /usr/bin/zip -qry ../HelloYrq-unsigned.ipa Payload)
unzip -t build/HelloYrq-unsigned.ipa

SIMULATOR_ID="$(python3 tools/select_simulator.py)"
echo "Running native API and UI tests on simulator: $SIMULATOR_ID"
test_status=0
xcodebuild \
  -project HelloYrq.xcodeproj -scheme HelloYrq -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/simulator -resultBundlePath build/HelloYrq.xcresult \
  -parallel-testing-enabled NO \
  test 2>&1 | tee build/simulator-test.log || test_status=$?

# The screenshot is also retained inside the xcresult if this optional export
# command is unavailable on a particular Xcode version.
if ! xcrun xcresulttool export attachments --path build/HelloYrq.xcresult --output-path build/screenshots; then
  echo 'Screenshot export unavailable; open HelloYrq.xcresult to view the attachment.'
fi
if ! xcrun xcresulttool get test-results summary --path build/HelloYrq.xcresult > build/test-summary.json; then
  echo 'Summary export unavailable; inspect the xcresult and simulator-test.log.'
fi
if [ "$test_status" -ne 0 ]; then
  exit "$test_status"
fi
printf '\nNative device build and iPhone simulator API/UI tests passed.\n'
printf 'IPA: build/HelloYrq-unsigned.ipa (requires local signing).\n'
