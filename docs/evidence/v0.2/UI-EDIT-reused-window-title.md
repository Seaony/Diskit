# 编辑器复用窗口标题未刷新

修前图另存 `editor-window-title-before/from-discovery-dark-zh.png`。复现路径：同一演示进程打开已保存百度位置编辑→取消→从已发现 Pixel 8 添加；内容已是 USB 手机，但窗口标题仍是旧百度位置的编辑标题。

原因：Scene 的动态 Window 标题在复用窗口时没有同步到实际 NSWindow，而编辑器仅绑定了授权锚点，没有在新草稿出现或名称变化时更新宿主标题。

最小修复：Window Scene 仅提供默认「添加位置」；真实标题由当前 editor.draft 与持久列表是否含此 id 决定。EditorWindowAccessor 获得实际窗口时同步一次，随后观察 editor.windowTitle 变化，仅在标题不同时更新 window.title。既有窗口 id、尺寸、预填、授权锚点与关闭行为不变。

针对性检查：`EditorWindowTitleTests.swift` 覆盖旧编辑窗口改为发现添加、编辑名称变化和同名不重复写入。通过 setter closure 模拟宿主窗口标题属性，没有 UI 自动化或真实应用启动。

- 旧的首次设定、之后缓存行为局部检查退出 1：`FAIL: 复用窗口仍保留旧位置编辑标题`。
- 同步修正后局部检查退出 0：`PASS: 发现入口刷新为添加位置；编辑改名刷新；相同标题不重复写宿主`。
- 局部程序只链接当前 Core 对象文件及标题 helper；相关调用文件语法检查通过，没有全套构建或测试。

待主任务集中构建后重走原 CUA 路径并重截图；测试不代替真实 SwiftUI 复用窗口验收。没有新词条，未提交。


交接现场复核已通过：百度编辑→取消→发现 Pixel 添加，标题正确为“添加位置”。本轮核对既有 UI-EDIT-03-from-discovery-dark-zh.png，与内容一致，未重拍。
