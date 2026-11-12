#!/bin/bash
# 把 README、产品图和第三方说明同步到公开的发布仓库 Seaony/Diskit。
# 用法：scripts/sync-release-repo.sh [--dry-run]
# README 里 <!-- source-only -->…<!-- /source-only --> 之间的内容只属于私有源码仓库，同步时删掉；
# <!-- public-only … --> 里的内容在源码仓库里看不到，同步时展开。
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
dry_run=0
if [[ $# == 1 && "$1" == '--dry-run' ]]; then dry_run=1; elif [[ $# != 0 ]]; then
  echo '用法：scripts/sync-release-repo.sh [--dry-run]' >&2; exit 1
fi
release_repo="Seaony/Diskit"
work="$(mktemp -d /tmp/diskit-release-repo.XXXXXX)"
trap 'rm -rf "$work"' EXIT

gh repo clone "$release_repo" "$work/repo" -- --quiet
mkdir -p "$work/repo/docs/assets"
for name in README.md README.zh-CN.md; do
  python3 - "$name" "$work/repo/$name" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
text = re.sub(r'<!-- source-only -->.*?<!-- /source-only -->', '', text, flags=re.S)
text = re.sub(r'<!-- public-only (.*?) -->', r'\1', text, flags=re.S)
if 'source-only' in text or 'public-only' in text:
    raise SystemExit(sys.argv[1] + ' 里的标记没有成对')
text = re.sub(r'\n{3,}', '\n\n', text)
open(sys.argv[2], 'w', encoding='utf-8').write(text)
PY
done
cp docs/assets/icon-512.png docs/assets/product-*.jpg "$work/repo/docs/assets/"
cp docs/THIRD_PARTY_NOTICES.md "$work/repo/docs/"

cd "$work/repo"
git add -A
if git diff --cached --quiet; then
  echo '发布仓库已是最新，无需同步'
  exit 0
fi
git diff --cached --stat
if [[ "$dry_run" == 1 ]]; then
  echo "试跑：以上改动未推送。生成的文件在 $work/repo（脚本结束即删除）"
  exit 0
fi
git commit -qm "同步 README 和产品图"
git push -q origin HEAD
echo "已同步：https://github.com/$release_repo"
