# Diskit 类型图标

生产资源包含 28 个原创位置类型图形和 1 个空状态图形。当前 `ConnectionKind` 有 29 个值，`webdavHTTPS` 与 `webdav` 共用图形；没有因为旧文档的计数遗漏类型。图库同时展示文件夹、邮件、下载三个技能参考图标，共 32 格，参考图标不导入应用资源。

图形源在 `src/icons.js` 的 Diskit 区段。颜色、描边、渐变和分层仍由原版 `src/engine.js` 生成；该文件未修改。这里按原生应用需要交付静态图标，不运行图标悬停脚本。

所有网盘采用原创云与文件夹，标记使用简单几何字形。对象存储采用原创储物桶。Kodo 和 MinIO 在小尺寸图标内分别缩写为 K、M，完整服务名始终由界面文字显示，避免在 24pt 内塞入过小字样。

## 导出

在仓库根目录执行：

```sh
scripts/export-icons.sh
```

也可只检查或导出一个图形：

```sh
node design/icons/scripts/check.mjs --native --only androidUSB --with 文件夹,邮件,下载 --out /tmp/diskit-icon-check
node design/icons/scripts/export.mjs --native --only androidUSB --accent '#427FE5' --out /tmp/diskit-icons
```

Dia 不提供本工具所需的 headless DOM 导出接口，所以本地 `--native` 模式用最小 SVG DOM 适配器执行原引擎，不启动其他浏览器。CoreSVG 不支持 feMerge，导出阶段将它转换为同样前后顺序的 feComposite over，不改变图形或原引擎；已通过实际 AppKit 离屏渲染及全部资产 actool 检查。SVG 光栅预览由本机已捆绑的 `sharp` 完成；XML 解析使用已捆绑的 `xml-js`。这两个仅为开发工具，不进入应用，也不需要安装新依赖。非默认环境可用 `DISKIT_NODE_MODULES` 指向已有工具模块目录。

原始浏览器导出与检查入口仍保留，显式指定可用的 Dia 导出环境后可调用；当前静态产物采用 `--native` 路径。没有把静态预览当成实际应用或 Dock 截图。

## 资源与接口

- `manifest.json` 是类型默认色、八色值和合并别名的清单。
- 每个图形导出八色，每色包含浅色与深色 SVG，共 232 个 imageset / 464 个 SVG。
- imageset 开启 `preserves-vector-representation`，深色通过 luminosity appearance 自动切换。
- `TypeIcon(kind:color:size:)`：颜色为 nil 时采用类型默认色；已发现位置传 `gray`。
- `EmptyLocationIcon(size:)`：空状态，默认 64pt。
- 组件不重复朗读图形，调用方必须保留服务名称或对应无障碍文字。

静态检查覆盖 24、28、56 像素、七种技能色板、浅黄色强调色与浅深背景。截图和 `checks.json` 位于 `docs/screenshots/v0.2/icons/`。最终 28/40/48/64pt 应用内排版、运行时外观切换、Dock/Finder 显示由统一 Computer Use 验收完成。

`LICENSE` 与复制的工具文件版权声明保留；没有复制技能说明文档。
