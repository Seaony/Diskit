# 首轮界面集成验收

仅使用 DISKIT_DEMO=1，Debug 构建；这些是局部证据，不替代完整矩阵与 Release 性能验收。

- 首次启动发现菜单栏标签持续刷新，进程 CPU 100%、RSS 约 8 GB，Computer Use 两次读取超时。采样：build/Validation/demo-hang.sample.txt，主线程集中于 MenuBarExtraHost.requestUpdate → updateButton → setImage。该进程已停止。
- 移除标签 TimelineView 后，同参数启动成功，Computer Use 可读取及操作；一次进程观察 CPU 0.0%、RSS 111840 KiB。这不是五分钟性能测量。
- 面板首次打开滚动位置为 0.157977883，发现区头部被跳过；手动滚回顶部后的截图已保存。初始焦点修复已落盘，尚待重建复验。
- 面板实际布局导出 build/Validation/layout/panel-light-layout.json，检查器通过：62 probes in 22 areas。
- 浅色中文设置五页已经由 Computer Use 逐页点击并检查：标题、正文、按钮无截断，指纹完整，关于页版本 0.2.0 / 构建 2，图标显示正常。其他语言、外观及权限状态待验。

## 截图

- docs/screenshots/v0.2/UI-PANEL-04-mixed-top-light-zh.png
- docs/screenshots/v0.2/UI-SET-01-general-light-zh.png
- docs/screenshots/v0.2/UI-SET-03-notification-light-zh.png
- docs/screenshots/v0.2/UI-SET-04-storage-light-zh.png
- docs/screenshots/v0.2/UI-SET-05-android-light-zh.png
- docs/screenshots/v0.2/UI-SET-06-about-light-zh.png
