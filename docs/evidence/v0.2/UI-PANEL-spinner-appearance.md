# 原生进度圈动态外观刷新

复现证据：`UI-PANEL-04-connecting-dark-zh.png` 为演示菜单从浅切深，进度圈接近黑色；`UI-PANEL-04-connecting-cold-dark-zh.png` 为冷启动深色，同一位置为较浅灰色。两张截图已逐张查看，支持动态切换未刷新原生控件外观的判断；并不把静态源码当作修后视觉证据。

实现：新增 `App/NativeProgressAppearance.swift` 视图修饰器，仍使用系统 `ProgressView` 与 `.circular`，显式 `.tint(DiskitTheme.primaryText)`；用 SwiftUI 的 colorScheme、colorSchemeContrast 作为局部 identity，切换后重新创建原生进度控件。未自绘动画、未使用计时器、未改全局系统外观。

调用核查：保存行、编辑器、编辑器预览、设置缓存计算/清理、指纹读取/重置、许可证读取、网页登录验证共九条不定进度圈路径全部接入。网页登录确定进度的线性条不改。

依据：[Apple 的 init(tint:) 文档](https://developer.apple.com/documentation/swiftui/circularprogressviewstyle/init%28tint%3A%29)明确推荐使用 tint 修饰器；没有使用弃用的 controlTint 或自造颜色 API。

局部检查：`xcrun swiftc -typecheck App/DiskitTheme.swift App/NativeProgressAppearance.swift` 退出 0；六个调用文件 `swiftc -frontend -parse` 退出 0；逐项搜索确认全部不定 ProgressView 接入。未添加 UI 自动化测试，未运行全套测试/应用构建，未提交。

主任务集中 `make build` 已通过，输出：`build/Validation/build-ui-batched.log`。随后用 Debug 演示模式经 Computer Use 实际复核浅→深→浅，三个状态均显示可见的灰色原生进度圈，切换后保留黑色旧外观的问题已消失。

修后截图：

- `docs/screenshots/v0.2/UI-PANEL-04-connecting-fixed-light-zh.png`
- `docs/screenshots/v0.2/UI-PANEL-04-connecting-fixed-dark-zh.png`
- `docs/screenshots/v0.2/UI-PANEL-04-connecting-fixed-light-return-zh.png`

结论：该面板动态外观缺陷已通过主任务实际目检。此结论只覆盖上述 Debug 演示界面与转换路径；其它界面同类进度圈仍随截图矩阵核对，完整最终构建、测试、覆盖率与签名等门禁尚待统一完成。本次证据更新未额外构建、测试或提交。

## 同类线性进度条补充

主任务后续通过 `UI-WEB-01-loading-light-zh.png` 与 `UI-WEB-01-loading-dark-zh.png` 发现，网页登录线性进度在浅→深后从主题绿色变为系统蓝色。现新增独立 `nativeLinearProgressAppearance()`，保留 `.linear` 与 `DiskitTheme.accent`，按 colorScheme/contrast 重建；没有套用 circular 修饰器。

新增线性浅深预览；`swiftc -typecheck App/DiskitTheme.swift App/NativeProgressAppearance.swift` 和网页登录文件语法检查通过。此追加修复尚待集中重建后重拍网页登录加载的浅→深→浅，不沿用上文圆圈目检结论。
