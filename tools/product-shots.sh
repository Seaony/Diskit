#!/bin/sh
# 生成 README 产品图：深浅色 × 中英文 4 张，写入 docs/assets。先运行 make build。
set -eu
cd "$(dirname "$0")/.."
app=build/DerivedData/Build/Products/Debug/Diskit.app/Contents/MacOS/Diskit
[ -x "$app" ] || { echo '缺少 Debug 构建，请先运行 make build' >&2; exit 1; }
work=$(mktemp -d /tmp/diskit-product-shots.XXXXXX)
for language in en zh; do
  [ "$language" = en ] && apple=en || apple=zh-Hans
  for appearance in dark light; do
    panel="$work/panel-$appearance-$language.png"
    # 演示模式离屏渲染真实面板，写完图片自动退出
    DISKIT_DEMO=1 DISKIT_DEMO_STATE=showcase DISKIT_DEMO_APPEARANCE=$appearance DISKIT_PRODUCT_SHOT="$panel" \
      "$app" -AppleLanguages "($apple)" >/dev/null 2>&1
    [ -s "$panel" ] || { echo "面板截图失败：$panel" >&2; exit 1; }
    swift tools/product-shot.swift "$panel" docs/assets/icon-512.png "$appearance" "$language" \
      "docs/assets/product-$appearance-$language.jpg"
    echo "docs/assets/product-$appearance-$language.jpg"
  done
done
echo "中间文件：$work"
