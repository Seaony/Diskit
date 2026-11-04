# 面板拖动源隐藏、会话收尾与焦点继承

修前证据另存 `panel-drag-before/icon-result-dark-en.png`（拖图标后源行隐藏且未排序）与 `text-baseline-dark-en.png`（拖文本未启动拖动）。不把后续同名覆盖截图当修前证据。

## 拖动生命周期

原代码先调用 `changed?(id)`，SwiftUI 随即将包含源 NSView 的整行 height 设为 0、opacity 设为 0，然后才调用 `beginDraggingSession`。同时整行有 minimumDistance=0 的 SwiftUI DragGesture，只为按下态但与 AppKit 源竞争事件。

第一轮定位版本保留源行尺寸并淡化到 0.45，但主任务真实拖动仍未排序、源状态未自动复位，见 `panel-drag-before/second-attempt-dark-en.png`。因此「先发布源状态／高度归零／竞争手势」只能列为源码风险，不能认定为现场失败的充分根因；保留尺寸也不满足 UI-PANEL-09，已撤回此临时方案。

当前版本恢复原位置收拢，并将 NSDraggingSource 分离成 PanelView 持有的稳定 NSObject；会话期间显式保留来源，结束回调释放。图标仍接收鼠标事件，但由稳定的 window.contentView 启动原生拖动，初始图像坐标转换到该宿主坐标系。prepare 不发布源，willBegin 才发布，因此行可以按规格收拢而不移除会话来源对象。源行移出层级不再提前结束会话，真正 endedAt 统一复位。既有 drop→move→仓库持久化与减弱动态效果分支保留；没有定时器或菜单排序替代。

仅 KAYOI_DEMO=1 临时记录 `KayoiDemoDrag` 日志：mouseDown/mouseDragged/mouseUp、willBegin、ended（含 operation）、validateDrop/dropEntered/dropExited/performDrop，每条附 NSEvent.pressedMouseButtons；不记录账号、标题、凭据或文件内容。由主任务新一次实际拖动判断是否收到鼠标释放与原生终态回调，诊断完成后移除此日志。

`PanelDragStateTests` 针对性状态测试：开始前不能发布源，开始后才发布，完成/取消/源移除及重复结束均清空。局部独立程序修前退出 1「原生拖动会话开始前已发布源行隐藏状态」，修后退出 0「会话开始后才发布源；完成/取消/移除均终态复位」。

## 行与子按钮焦点

行保留 focusable/focused 键盘路径，但禁用额外矩形系统焦点效果，沿用自画圆角选中边框。Test Connection、错误详情与复制详情按钮各自 FocusState，显式传给按钮样式；不再把父行继承来的 isFocused 当作按钮本身焦点。其它场景按钮不传覆盖值，仍保留原有继承行为。

`ControlFocusTests` 的局部程序修前退出 1「行焦点泄漏为子按钮焦点」，修后退出 0「组合行子控件只跟随自身焦点；普通控件仍保留原生继承焦点」。

AppKit 拖动源、两种按钮样式和对应纯逻辑已局部 swiftc typecheck；保存行语法、范围差异检查通过。没有 UI 自动化、CUA 操作、全量测试/构建或提交。

待主任务集中构建后实际拖 Qiniu 图标到百度，核对真实落点排序、成功和 Escape/拖出窗口取消后的源行复位、复制/主按钮 Tab 焦点及无额外矩形焦点框。纯逻辑检查不等于拖动端到端验收通过。


稳定来源版本局部检查：PanelDragHandle 与 PanelDragState 的 `swiftc -typecheck` 退出 0；PanelView/SavedConnectionRow 语法检查和范围差异检查通过；纯状态程序仍通过启动前不发布、终态清理。没有启动 App 或操作 CUA，真实排序及取消仍待下一次诊断。


收尾结论：两次实拖仍未收到 performDrop，第二次 ended operation=0；未通过，日志见 FINISH-drag-attempt-{1,2}.log。诊断代码已删除，后续按 ACCEPTANCE 人工验收。
