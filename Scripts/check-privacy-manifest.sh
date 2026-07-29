#!/bin/sh
set -eu

manifest="QuillvaultApp/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$manifest"

for required_value in \
  "NSPrivacyAccessedAPICategoryFileTimestamp" \
  "C617.1" \
  "3B52.1" \
  "NSPrivacyAccessedAPICategoryUserDefaults" \
  "CA92.1"
do
  plutil -p "$manifest" | grep -Fq "$required_value"
done
