# 安卓设置无障碍递归崩溃证据

同一序列三次触发：演示启动 → 设置 → 通知 → 存储 → 安卓 → 读取辅助功能树/截图。工具在整组调用失败时隐藏此前图像输出，借助已保存文件时间确认失败发生在安卓页，而非通用页。第三次事先关闭面板，仍触发相同崩溃。

## Kayoi-2026-11-04-202631.ips

Thread stack size exceeded due to excessive recursion

- objc_getAssociatedObject
- _NSAccessibilityOverrideValueForAttribute
- ___NSAccessibilityEntryPointValueForAttribute_block_invoke.772
- NSAccessibilityPerformEntryPointObject
- _NSAccessibilityEntryPointValueForAttribute
- PlatformAccessibilityElementProtocol<>.valueForAttribute<A>(_:asType:)
- AccessibilityNode.resolvedRole(forPlatformElement:)
- AccessibilityNode.labelExposedAs.getter
- AccessibilityNode.labelsToResolve.getter
- AccessibilityNode.accessibilityLabel()
- @objc AccessibilityNode.accessibilityLabel()
- closure #4 in AccessibilityNode.applyProperties(to:)

## Kayoi-2026-11-04-203352.ips

Thread stack size exceeded due to excessive recursion

- objc_getAssociatedObject
- _NSAccessibilityOverrideValueForAttribute
- ___NSAccessibilityEntryPointValueForAttribute_block_invoke.772
- NSAccessibilityPerformEntryPointObject
- _NSAccessibilityEntryPointValueForAttribute
- PlatformAccessibilityElementProtocol<>.valueForAttribute<A>(_:asType:)
- AccessibilityNode.resolvedRole(forPlatformElement:)
- AccessibilityNode.labelExposedAs.getter
- AccessibilityNode.labelsToResolve.getter
- AccessibilityNode.accessibilityLabel()
- @objc AccessibilityNode.accessibilityLabel()
- closure #4 in AccessibilityNode.applyProperties(to:)

## Kayoi-2026-11-04-203553.ips

Thread stack size exceeded due to excessive recursion

- bool objc::DenseMapBase<objc::DenseMap<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>, objc::DenseMapValueInfo<objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>, objc::DenseMapInfo<DisguisedPtr<objc_object>>, objc::detail::DenseMapPair<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>>, DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>, objc::DenseMapValueInfo<objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>, objc::DenseMapInfo<DisguisedPtr<objc_object>>, objc::detail::DenseMapPair<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>>::LookupBucketFor<DisguisedPtr<objc_object>>(DisguisedPtr<objc_object> const&, objc::detail::DenseMapPair<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>> const*&) const
- objc::DenseMapBase<objc::DenseMap<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>, objc::DenseMapValueInfo<objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>, objc::DenseMapInfo<DisguisedPtr<objc_object>>, objc::detail::DenseMapPair<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>>, DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>, objc::DenseMapValueInfo<objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>, objc::DenseMapInfo<DisguisedPtr<objc_object>>, objc::detail::DenseMapPair<DisguisedPtr<objc_object>, objc::SmallDenseMap<void const*, objc::ObjcAssociation, 1u, objc::DenseMapValueInfo<objc::ObjcAssociation>, objc::DenseMapInfo<void const*>, objc::detail::DenseMapPair<void const*, objc::ObjcAssociation>>>>::find(DisguisedPtr<objc_object> const&)
- objc_getAssociatedObject
- _NSAccessibilityOverrideValueForAttribute
- ___NSAccessibilityEntryPointValueForAttribute_block_invoke.772
- NSAccessibilityPerformEntryPointObject
- _NSAccessibilityEntryPointValueForAttribute
- PlatformAccessibilityElementProtocol<>.valueForAttribute<A>(_:asType:)
- AccessibilityNode.resolvedRole(forPlatformElement:)
- AccessibilityNode.labelExposedAs.getter
- AccessibilityNode.labelsToResolve.getter
- AccessibilityNode.accessibilityLabel()

## 单因素修复与复验

SettingsView 安卓页原指纹 Text 同时使用 textSelection(.enabled) 与直接 accessibilityLabel 覆写。改为外层 LabeledContent 提供说明，内部 Text 保留原生选择与朗读；未修改菜单栏或面板。

修改后原完整五页切换、辅助功能读取与截图序列通过；Release 深色中文亦通过。最终稳定性还需连续运行 30 分钟及新报告增量检查。

证据截图：docs/screenshots/v0.2/UI-SET-05-android-light-en.png、UI-SET-05-android-dark-zh.png。
