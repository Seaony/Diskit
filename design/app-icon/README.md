# Diskit 应用图标

当前 AppIcon 是小花怪兽从蓝色文件夹里探头的 `folder-peek.png`（2026-11-12 第 1 批 20 张候选里的 06），面板左上角的 BrandLogo 用同一张图。在仓库根目录运行 `swift design/app-icon/export-app-icon.swift`，按 1024 画布、824 圆角主体与投影的规格导出 AppIcon 全部尺寸、`docs/assets/icon-512.png` 和 BrandLogo。

其余 19 张候选和每张的提示词备份在 `candidates-2026-11-12/`，`overview.png` 是总览。上一版图标是 `coral-crown-turtle.png`（小花怪兽原画，菜单栏字形也按它画）。

以下是早期的三个方向，已不再使用：

三个原创方向均使用 1024 画布、同一圆角主体与投影，主题为设备和存储之间往返。

- `01-roundtrip.svg`：上下两条相反方向的通路，轮廓最简，16px 下仍能分辨往返方向。曾选为 AppIcon。
- `02-devices.svg`：Mac 与手机的组合，较直观但 16px 下设备细节较密。
- `03-folder.svg`：文件夹内双向传输，文件语义更强，但小尺寸内层较多。

未采用第三方服务标志。两份未选草案保留，可由用户替换。`export.mjs` 可复现这些草案和对照图，不再写入 AppIcon。

已在浅深色背景上以 16、32、128、512px 制作并目检对照图，选择第一案；这不是实际 Dock 或 Finder 截图，真实应用显示仍待统一 Computer Use 验收。
