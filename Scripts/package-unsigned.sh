#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path=".work/DeviceBuild/Build/Products/Release-iphoneos/Signer.app"
[[ -f "$app_path/Signer" ]] || { print -u2 'Build the iOS device Release target first'; exit 1; }
output_path="${1:-build/ESign-unsigned.ipa}"
stage_dir="$(mktemp -d .work/UnsignedPackage.XXXXXX)"
trap 'rm -rf -- "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload" "${output_path:h}"
/usr/bin/ditto "$app_path" "$stage_dir/Payload/Signer.app"
python3 - "$stage_dir/Payload/Signer.app" <<'PY'
import shutil, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
magic = {bytes.fromhex(value) for value in ('feedface','feedfacf','cefaedfe','cffaedfe','cafebabe','bebafeca','cafebabf','bfbafeca')}
for file in list(app.rglob('*')):
    if file.is_symlink() or not file.is_file():
        continue
    if file.name == 'embedded.mobileprovision' or file.suffix.lower() in {'.p12','.pfx','.pem','.key','.mobileprovision','.provisionprofile'}:
        file.unlink()
        continue
    with file.open('rb') as handle:
        header = handle.read(4)
    if header in magic:
        signed = subprocess.run(['codesign','-d',str(file)],capture_output=True)
        if signed.returncode == 0:
            subprocess.run(['codesign','--remove-signature',str(file)],check=True,capture_output=True)
        assert subprocess.run(['codesign','-d',str(file)],capture_output=True).returncode != 0
for directory in sorted(app.rglob('_CodeSignature'),key=lambda p:len(p.parts),reverse=True):
    if directory.is_dir() and not directory.is_symlink():
        shutil.rmtree(directory)
PY
/usr/bin/ditto -c -k --keepParent "$stage_dir/Payload" "$output_path"
/usr/bin/unzip -tq "$output_path"
/usr/bin/shasum -a 256 "$output_path" > "$output_path.sha256"
/usr/bin/du -h "$output_path"
