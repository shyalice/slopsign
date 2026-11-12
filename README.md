# SlopSign

Native iOS ESign reconstruction made with latest stock components, there may be some differences, I tried my best to copy it's logic fully while making it proper styled and better. Bundle: `io.alicehatesyou.signer`.

## Build

Requires Xcode 26, XcodeGen and the local dependencies in `Vendor/`.

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Signer.xcodeproj -scheme Signer -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .work/DeviceBuild \
  -clonedSourcePackagesDirPath .work/SourcePackages CODE_SIGNING_ALLOWED=NO build
Scripts/package-preview.sh build/ESign-preview.ipa
```

The packaging script produces an ad-hoc signed preview for the user's VM. Installation on a standard iPhone requires a valid signing identity and a profile that authorizes that device, plus an accepted installation route.
