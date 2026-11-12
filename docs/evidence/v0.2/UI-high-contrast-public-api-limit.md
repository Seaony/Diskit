# 增强对比度验收：公开 API 限制与失败证据

## 已存档的修前事实

`high-contrast-before/panel-appearance.json` 和 `settings-appearance.json` 是从 `build/Validation/high-contrast/` 原样复制的失败输出，两者均为 `NSAppearanceNameAqua`、`contrast=standard`，Border 线性 RGB 相同。这些截图不能记作系统增强对比度验收通过。

主任务确认驱动输入为字符串 `contrast="1"`、`appearance="light"`、Debug，且未按外观切换快捷键，因此排除 JSON 布尔转字符串和菜单覆盖作为该次失败的原因。

## 定位结果

公开 AppKit SDK `NSAppearance.h` 第 73–79 行明确说明，四个 accessibilityHighContrast 名称只用于 `bestMatchFromAppearancesWithNames:` 匹配，不能作为 `appearanceNamed:` 的受支持创建参数。原文已存档 `high-contrast-before/NSAppearance-public-header.txt`。

本机无窗口、无 UI 操作的局部探针实际结果：请求 accessibilityHighContrastAqua 返回普通 Aqua，bestMatch 仍为 Aqua；深色同理。使用公开 `performAsCurrentDrawingAppearance` 读取已构建 App 的 Border 资产，所谓高对比请求的 RGB 与相应普通模式相同。代码与原始输出见 `appearance-name-probe.swift` / `.log`。针对性断言 `appearance-assert.swift` 退出 1，原始失败输出见同名 `.log`。

SwiftUI SDK 的公开 `EnvironmentValues.colorSchemeContrast` 只有 getter；带下划线的 setter 不用于本项目。接口片段已存档 `SwiftUI-contrast-public-interface.txt`。[Apple 官方文档](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast)将该值定义为读取当前对比度环境的入口，没有公开应用内强制开启系统增强对比度的方法。

## 处理边界

没有修改系统设置，没有设置私有 Environment 键，没有伪造 JSON，也没有新增自有高对比色板冒充系统验收。主任务决定通过明确获准的临时系统增强对比度切换、截图、恢复完成真实验收。

`DISKIT_DEMO_CONTRAST=1` 当前只能表达测试意图，不能作为系统功能已生效的证据；旧 `DemoAppearance.name` 返回高对比名字的纯映射测试只验证字符串选择，不证明渲染生效。建议后续移除这条不可用的强制分支，或只把该旗标用于校验真实系统环境并明确报告未启用；在主任务确定处理前不扩改演示功能。

本项仍待真实系统增强对比度验收，不能宣称已修复或通过；本轮只做局部 API 检查，没有全量构建、测试或提交。


收尾已删除 DISKIT_DEMO_CONTRAST、强制高对比名称分支和旧名称映射测试。公开 API 无法模拟，需用户在系统设置开启后目检；本轮没有更改系统设置。
