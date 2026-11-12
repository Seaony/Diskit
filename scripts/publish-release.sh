#!/bin/bash
# 一键发布新版本：scripts/publish-release.sh <版本号> [--dry-run]
# 源码仓库保持私有，安装包和更新源发布到公开的 Seaony/Diskit。
# --dry-run 完整打包、公证和验证，但不提交、不推送、不发布。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

usage() { echo '用法：scripts/publish-release.sh <主.次.修订> [--dry-run]' >&2; exit 1; }
version="${1:-}"
dry_run=0
if [[ $# == 2 && "$2" == '--dry-run' ]]; then dry_run=1; elif [[ $# != 1 ]]; then usage; fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage

release_repo="Seaony/Diskit"
account="${SPARKLE_ACCOUNT:-com.seaony.Moni}"
identity="Developer ID Application: SHEN WANG (JJJKGPY7T7)"
# 公证凭据存在钥匙串里，由 xcrun notarytool store-credentials 建好
notary_profile="${NOTARY_PROFILE:-notary}"
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
# 上次发布中途失败时允许重试：已有标签必须指向当前提交，已有的只能是未完成的草稿
head="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ "$(git rev-parse "$tag^{commit}")" == "$head" ]] || fail "本地标签 $tag 指向别的提交"
fi
remote_tag="$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)"
[[ -z "$remote_tag" || "$remote_tag" == "$head" ]] || fail "远端标签 $tag 指向别的提交"
release_draft="$(gh release view "$tag" --repo "$release_repo" --json isDraft --jq .isDraft 2>/dev/null || true)"
[[ "$release_draft" != false ]] || fail "已发布过：$tag"
security find-generic-password -a "$account" -s https://sparkle-project.org >/dev/null 2>&1 \
  || fail "登录钥匙串里没有 Sparkle 签名密钥：$account"
security find-identity -v -p codesigning | grep -qF "\"$identity\"" || fail "钥匙串里没有签名证书：$identity"
xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
  || fail "钥匙串里没有可用的公证凭据：$notary_profile（用 xcrun notarytool store-credentials 建）"

# 版本号唯一来源是 project.yml；传入的新版本必须更大，构建号自动加 1
current_version="$(python3 scripts/project-version.py | sed -n '1p')"
current_build="$(python3 scripts/project-version.py | sed -n '2p')"
work="$(mktemp -d /tmp/diskit-release.XXXXXX)"
committed=0
cleanup() {
  rm -rf "$work"
  # 试跑或中途失败时，把没提交的版本号改动（含暂存区）还原到开始时的提交
  if [[ "$committed" == 0 ]]; then git checkout "$head" -- project.yml 2>/dev/null || true; fi
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
echo "准备发布 Diskit ${version}（构建号 ${build}）"

output="$root/build/releases/$tag"
rm -rf "$output"
mkdir -p "$output" "$work/updates" "$work/dmg"

make test
export DISKIT_BUILD_CONFIG="${DISKIT_BUILD_CONFIG:-Config/Validation.xcconfig}"
make release RELEASE_IDENTITY="$identity"
app="$root/build/DerivedData/Build/Products/Release/Diskit.app"
tools="$root/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools/generate_appcast" ]] || fail '缺少 Sparkle 工具'

# 提交公证并等结果；没通过就打出苹果给的原因
notarize() {
  local result="$work/notary.json"
  xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait --output-format json > "$result" || true
  local id status
  id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$result" 2>/dev/null || true)"
  status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$result" 2>/dev/null || true)"
  if [[ "$status" != Accepted ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$notary_profile" >&2
    fail "公证没通过：$(basename "$1") ${status:-提交失败}"
  fi
  echo "公证通过：$(basename "$1")"
}

# 只公证一次：苹果会连 DMG 里的 App 一起认证，之后 DMG 和 App 都能装订票据
zip_name="Diskit-$version.zip"
dmg_name="Diskit-$version.dmg"
ditto "$app" "$work/dmg/Diskit.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname Diskit -srcfolder "$work/dmg" -ov -format UDZO "$output/$dmg_name"
codesign --sign "$identity" --timestamp "$output/$dmg_name"
notarize "$output/$dmg_name"
xcrun stapler staple "$output/$dmg_name"
spctl --assess --type open --context context:primary-signature --verbose=2 "$output/$dmg_name"
# 更新用的压缩包取装订过的 App
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$zip_name"

# 更新说明：有手写的 docs/release-notes/v版本号.md 就用它；否则列上个版本以来的提交；第一次发布写固定说明
notes="$work/notes.md"
written_notes="$root/docs/release-notes/$tag.md"
previous_tag="$(git describe --tags --abbrev=0 --exclude "$tag" HEAD 2>/dev/null || true)"
{
  printf '## Diskit %s\n\n' "$version"
  if [[ -f "$written_notes" ]]; then
    cat "$written_notes"
  elif [[ -n "$previous_tag" ]]; then
    git log --no-merges --pretty='- %s' "$previous_tag..HEAD"
  else
    printf -- '- 首个公开版本。\n'
  fi
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
  scripts/sync-release-repo.sh --dry-run
  echo "试跑完成（已公证），未提交、未推送、未发布。制品：$output"
  exit 0
fi

# 对外发布：提交版本号、推送源码标签、在公开仓库创建发布并上传
if [[ -n "$(git status --porcelain project.yml)" ]]; then
  git add project.yml
  git commit -qm "发布 $version"
  committed=1
  git push -q origin master
fi
committed=1
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "Diskit $version"
[[ -n "$remote_tag" ]] || git push -q origin "$tag"
scripts/sync-release-repo.sh
# 上次上传失败留下的草稿先删掉再重建
[[ "$release_draft" == true ]] && gh release delete "$tag" --repo "$release_repo" --yes
gh release create "$tag" --repo "$release_repo" \
  --title "Diskit $version" --notes-file "$notes" \
  "$output/$dmg_name" "$output/$zip_name" "$output/appcast.xml"
echo "已发布：https://github.com/$release_repo/releases/tag/$tag"
echo "制品：$output"
