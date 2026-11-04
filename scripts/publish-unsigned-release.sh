#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
publish=0
if [[ "${1:-}" == '--publish' && $# == 1 ]]; then publish=1
elif [[ $# != 0 ]]; then echo '用法：publish-unsigned-release.sh [--publish]' >&2; exit 1; fi
[[ "$(git branch --show-current)" == master ]] || { echo '只能从 master 准备发行' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo '请先完成分组提交，工作区必须干净' >&2; exit 1; }
version="$(python3 scripts/project-version.py | sed -n '1p')"
build="$(python3 scripts/project-version.py | sed -n '2p')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[1-9][0-9]*$ ]] || exit 1
tag="v$version"
output="$root/build/releases/$tag"
[[ ! -e "$output" ]] || { echo "输出目录已存在：$output" >&2; exit 1; }
work="$(mktemp -d /tmp/kayoi-release.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export KAYOI_BUILD_CONFIG="${KAYOI_BUILD_CONFIG:-Config/Validation.xcconfig}"
make release SIGN_IDENTITY=- SIGN_TIMESTAMP=none
app="$root/build/DerivedData/Build/Products/Release/Kayoi.app"
tools="$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/generate_appcast" ]] || { echo '缺少 Sparkle 工具' >&2; exit 1; }
mkdir -p "$work/updates"
archive="Kayoi-$version-unsigned.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/updates/$archive"
"$tools/generate_appcast" --account "${SPARKLE_ACCOUNT:-com.seaony.Moni}" \
  --download-url-prefix "https://github.com/Seaony/Kayoi/releases/download/$tag/" \
  --link 'https://github.com/Seaony/Kayoi' --maximum-versions 1 --maximum-deltas 0 \
  -o "$work/updates/appcast.xml" "$work/updates"
scripts/validate-release.sh "$app" "$work/updates/appcast.xml" "$work/updates/$archive" "$tools"
mkdir -p "$output"
cp "$work/updates/$archive" "$work/updates/appcast.xml" "$output/"
if [[ "$publish" == 1 ]]; then
  git fetch origin master --quiet
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || { echo 'master尚未与远端一致' >&2; exit 1; }
  if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then echo '远端版本标签已存在' >&2; exit 1; fi
  gh release create "$tag" "$output/$archive" "$output/appcast.xml" --repo Seaony/Kayoi \
    --target "$(git rev-parse HEAD)" --title "Kayoi $version" \
    --notes '此构建使用临时签名，未使用 Apple Developer ID，也未经过 Apple 公证。'
else
  echo "仅准备本地制品，未发布：$output"
fi
