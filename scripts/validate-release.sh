#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:?用法：validate-release.sh 应用路径 [appcast路径 压缩包路径 Sparkle工具目录]}"
feed="${2:-}"
archive="${3:-}"
tools="${4:-$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
python3 "$root/scripts/sign-app.py" "$app" --verify
cli="$root/build/bin/diskit-dev"
[[ -x "$cli" ]] || { echo '缺少命令行工具' >&2; exit 1; }
python3 "$root/scripts/package-cli.py" --verify "$root/build/bin"
lipo "$cli" -verify_arch arm64
lipo "$cli" -verify_arch x86_64
codesign --verify --strict --verbose=2 "$cli"
echo '命令行工具：arm64 + x86_64，签名有效'
if [[ -n "$feed" ]]; then
  [[ -x "$tools/sign_update" ]] || { echo '缺少 Sparkle 验签工具' >&2; exit 1; }
  account="${SPARKLE_ACCOUNT:-com.seaony.Moni}"
  public_key="$("$tools/generate_keys" --account "$account" -p)"
  expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")"
  [[ "$public_key" == "$expected_key" ]] || { echo '验签账户公钥与应用不一致' >&2; exit 1; }
  "$tools/sign_update" --account "$account" --verify "$feed"
  signature="$(python3 - "$feed" <<'PY'
import sys, xml.etree.ElementTree as E
root=E.parse(sys.argv[1]).getroot()
items=root.findall('./channel/item')
if len(items)!=1: raise SystemExit('发布验收需要恰好一个版本')
print(items[0].find('enclosure').attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'])
PY
)"
  "$tools/sign_update" --account "$account" --verify "$archive" "$signature"
fi
python3 "$root/scripts/validate-release.py" "$app" "$feed" "$archive"
