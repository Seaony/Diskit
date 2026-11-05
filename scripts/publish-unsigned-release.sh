#!/bin/bash
# 一键发布新版本：scripts/publish-unsigned-release.sh <版本号> [--dry-run]
# 源码仓库保持私有，安装包和更新源发布到公开的 Seaony/Kayoi-Releases。
# --dry-run 只在本地完整打包和验证，不提交、不推送、不发布。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() { echo '用法：scripts/publish-unsigned-release.sh <主.次.修订> [--dry-run]' >&2; exit 1; }
version="${1:-}"
dry_run=0
if [[ $# == 2 && "$2" == '--dry-run' ]]; then dry_run=1; elif [[ $# != 1 ]]; then usage; fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

release_repo="Seaony/Kayoi-Releases"
account="${SPARKLE_ACCOUNT:-com.seaony.Moni}"
tag="v$version"
fail() { echo "$1" >&2; exit 1; }

# 发布前检查：分支、工作区、远端同步、工具、登录、签名密钥、版本是否已存在
[[ "$(git branch --show-current)" == master ]] || fail '只能从 master 发布'
[[ -z "$(git status --porcelain)" ]] || fail '工作区必须干净，请先提交'
for command_name in gh git make xcodebuild ditto hdiutil python3 security; do
  command -v "$command_name" >/dev/null || fail "缺少命令：$command_name"
done
gh auth status >/dev/null 2>&1 || fail 'GitHub CLI 未登录，请先运行 gh auth login'
git fetch origin master --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] || fail 'master 与 origin/master 不一致，请先推送'
gh repo view "$release_repo" >/dev/null 2>&1 || fail "找不到发布仓库：$release_repo"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "本地已有标签：$tag"
git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && fail "远端已有标签：$tag"
gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1 && fail "已发布过：$tag"
security find-generic-password -a "$account" -s https://sparkle-project.org >/dev/null 2>&1 \
  || fail "登录钥匙串里没有 Sparkle 签名密钥：$account"

# 版本号唯一来源是 project.yml；传入的新版本必须更大，构建号自动加 1
current_version="$(python3 scripts/project-version.py | sed -n '1p')"
current_build="$(python3 scripts/project-version.py | sed -n '2p')"
work="$(mktemp -d /tmp/kayoi-release.XXXXXX)"
committed=0
cleanup() {
  rm -rf "$work"
  # 试跑或中途失败时，没提交的版本号改动还原回去
  if [[ "$committed" == 0 ]]; then git checkout -- project.yml 2>/dev/null || true; fi
}
trap cleanup EXIT
if [[ "$version" != "$current_version" ]]; then
  [[ "$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -1)" == "$version" ]] \
    || fail "新版本 $version 必须大于当前版本 $current_version"
  build=$((current_build + 1))
  sed -i '' -E "s/^    MARKETING_VERSION: \"[^\"]+\"/    MARKETING_VERSION: \"$version\"/; s/^    CURRENT_PROJECT_VERSION: \"[^\"]+\"/    CURRENT_PROJECT_VERSION: \"$build\"/" project.yml
  [[ "$(python3 scripts/project-version.py | tr '\n' ' ')" == "$version $build " ]] || fail '写入版本号失败'
else
  build="$current_build"
fi
echo "准备发布 Kayoi ${version}（构建号 ${build}）"

output="$root/build/releases/$tag"
rm -rf "$output"
mkdir -p "$output" "$work/updates" "$work/dmg"

make test
export KAYOI_BUILD_CONFIG="${KAYOI_BUILD_CONFIG:-Config/Validation.xcconfig}"
make release SIGN_IDENTITY=- SIGN_TIMESTAMP=none
app="$root/build/DerivedData/Build/Products/Release/Kayoi.app"
tools="$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/generate_appcast" ]] || fail '缺少 Sparkle 工具'

zip_name="Kayoi-$version-unsigned.zip"
dmg_name="Kayoi-$version-unsigned.dmg"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$zip_name"
ditto "$app" "$work/dmg/Kayoi.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname Kayoi -srcfolder "$work/dmg" -ov -format UDZO "$output/$dmg_name"

# 更新说明：上个版本以来的提交；第一次发布写固定说明
notes="$work/notes.md"
previous_tag="$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)"
{
  printf '## Kayoi %s\n\n' "$version"
  if [[ -n "$previous_tag" ]]; then
    git log --no-merges --pretty='- %s' "$previous_tag..HEAD"
  else
    printf -- '- 首个公开版本。\n'
  fi
  printf '\n> 此构建未使用 Apple Developer ID 签名，也未经过 Apple 公证。首次打开时，macOS 可能阻止运行；请在“系统设置 → 隐私与安全性”中确认打开。\n'
} > "$notes"

# 生成并签名更新源，下载地址指向公开的发布仓库
cp "$output/$zip_name" "$work/updates/$zip_name"
cp "$notes" "$work/updates/${zip_name%.zip}.md"
"$tools/generate_appcast" --account "$account" \
  --download-url-prefix "https://github.com/$release_repo/releases/download/$tag/" \
  --link "https://github.com/$release_repo" --embed-release-notes \
  --maximum-versions 1 --maximum-deltas 0 \
  -o "$work/updates/appcast.xml" "$work/updates"
cp "$work/updates/appcast.xml" "$output/appcast.xml"
scripts/validate-release.sh "$app" "$output/appcast.xml" "$output/$zip_name" "$tools"

if [[ "$dry_run" == 1 ]]; then
  echo "试跑完成，未提交、未推送、未发布。制品：$output"
  exit 0
fi

# 对外发布：提交版本号、推送源码标签、在公开仓库创建发布并上传
if [[ -n "$(git status --porcelain project.yml)" ]]; then
  git add project.yml
  git commit -qm "发布 $version"
  git push -q origin master
fi
committed=1
git tag -a "$tag" -m "Kayoi $version"
git push -q origin "$tag"
gh release create "$tag" --repo "$release_repo" \
  --title "Kayoi $version" --notes-file "$notes" \
  "$output/$dmg_name" "$output/$zip_name" "$output/appcast.xml"
echo "已发布：https://github.com/$release_repo/releases/tag/$tag"
echo "制品：$output"
