# 网页登录窗口现场验收

使用 `KAYOI_DEMO=1` 的 Debug 应用，构建记录 `build/Validation/build-ui-batched.log`。服务选择夸克，仅离线演示，不访问服务商。

- `UI-WEB-01-loading-light-zh.png`：域名、安全提示、36% 加载进度和取消入口可见。
- `UI-WEB-01-loading-dark-zh.png`：布局可读，但从浅色切换后进度条错误回到系统蓝色；不能判通过，待外观刷新修复后重拍。
- `UI-WEB-02-error-light-zh.png`、`UI-WEB-02-error-dark-zh.png`：加载失败原因、重新加载按钮和其它登录方式入口可见。
- 实际点击“重新加载”，辅助功能树中的失败提示和重试按钮消失，恢复离线登录页；未发出真实网络请求。

截图均位于 `docs/screenshots/v0.2/`。这组记录不代替真实账号登录验证或最终完整测试。


后续修复已通过浅→深→浅复核，采用 UI-WEB-01-loading-fixed-{light,dark,light-return}-zh.png；三图均为对应绿色。本轮核对既有原图，不重拍，不把旧蓝色图算作通过。
