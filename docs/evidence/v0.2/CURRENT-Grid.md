# 集中验收前交接（不表示运行通过）

实现已交中央集成，编译/测试/截图/性能尚未通过；下列已有局部或静态证据只适用于交接注明的时点。

# 网格验收入口

代码检查：`tools/grid-lint.sh`，全 App 87 个 Swift 文件通过（后续代理增加文件后以集中结果为准）。
布局检查：`swift tools/check-layout.swift <截图目录>/*-layout.json`。
应用只在 `DISKIT_DEMO=1 DISKIT_LAYOUT_DIR=<截图目录>` 时写真实帧 JSON。`APP_GRID=1` 额外画 8 pt 网格、区域与内边距、探针及名称。开关集中在 RuntimeOptions；非演示模式忽略开关。
导出页：panel、help、license、editor（后者由编辑器任务接线）。原生 Form/List/Sidebar 不需探针。
示例检查器验证：`/tmp/diskit-grid-valid.json` 2 探针 1 区域通过；`/tmp/diskit-grid-invalid.json` 的 23 pt 左缘同时触发网格、内边距、列对齐失败。
尚未启动应用采集真实帧，因此以上 fixture 仅验证检查器，不证明任何界面已对齐。
预览：PanelPreviews.swift（浅深/空/发现/九态）；PanelBanners.swift（六种错误及深色）；SettingsPreviews.swift（五页浅深、空缓存、许可证浅深）；HelpView.swift（浅深/搜索空）、HelpGuideDetail.swift（浅深）；MenuBarStatusIcon.swift（空/忙/错误）。
DS22：PanelArrival 按 24ms*n/8pt*.7^n 显示发现行，减弱动态直接显示。DS25：Panel 使用 AppModel.undoManager，排序注册逆序操作，undo 生成 redo；编辑器改名/颜色使用 Core.setPresentation 且共享同一个 undoManager。
