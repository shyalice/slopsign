#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path=".work/DeviceBuild/Build/Products/Release-iphoneos/Signer.app"
[[ -f "$app_path/Signer" ]] || { print -u2 'Build the iOS device Release target first'; exit 1; }
output_path="${1:-build/ESign-preview.ipa}"
stage_dir="$(mktemp -d .work/PreviewPackage.XXXXXX)"
trap 'rm -rf -- "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload" "${output_path:h}"
/usr/bin/ditto "$app_path" "$stage_dir/Payload/Signer.app"
tls_identity="Signer/Resources/Installation/server.p12"
if [[ -f "$tls_identity" ]]; then
  mkdir -p "$stage_dir/Payload/Signer.app/Installation"
  /usr/bin/ditto "$tls_identity" "$stage_dir/Payload/Signer.app/Installation/server.p12"
fi
# The preview carries an ad hoc signature for VMs, not an Apple installation identity.
preview_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$stage_dir/Payload/Signer.app/Info.plist")"
/usr/libexec/PlistBuddy -c "Add :application-identifier string $preview_bundle_id" "$stage_dir/Preview.entitlements" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$stage_dir/Preview.entitlements"
/usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string $preview_bundle_id" "$stage_dir/Preview.entitlements"
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements "$stage_dir/Preview.entitlements" "$stage_dir/Payload/Signer.app"
/usr/bin/ditto -c -k --keepParent "$stage_dir/Payload" "$output_path"
/usr/bin/unzip -tq "$output_path"
/usr/bin/shasum -a 256 "$output_path" > "$output_path.sha256"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$stage_dir/Payload/Signer.app/Info.plist"
/usr/bin/du -h "$output_path"
