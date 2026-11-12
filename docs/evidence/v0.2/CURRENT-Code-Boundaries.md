# 代码组织与非功能范围的处置理由

## 长文件

OPTIMIZATION明确要求编辑器视图/逻辑拆分、一个主要类型一个文件，但没有设定所有文件必须低于400行。原审计列举长文件是一项可维护性观察，不将它机械转换为全仓按行数拆分。

编辑器已拆出七类表单、类型选择、字段控件、准备步骤，以及校验/授权/配对/演示模型。其他列明provider保留同一服务的文件接口实现；其中分页、路径身份、鉴权、分片与恢复依赖同一actor/session状态，单纯把函数按行数分到文件不能消除业务复杂度，反会扩大内部可见性。PanelView负责一个面板容器，行/动作/横幅/预览已分离；AppModel负责应用服务装配与provider路由，独立系统服务/依赖/演示控制/缓存/操作生命周期已拆。故保留这些单一主要类型的长实现，不宣称全部文件都已短于400行。

当前读取时物理行数：

- `App/ConnectionEditor.swift`：230行。
- `Packages/CloudDrive/Sources/CloudDrive/Drive115Provider.swift`：856行。
- `App/PanelView.swift`：608行。
- `Packages/S3Drive/Sources/S3Drive/S3Provider.swift`：858行。
- `Packages/CloudDrive/Sources/CloudDrive/BaiduDriveProvider.swift`：572行。
- `Packages/TianyiDrive/Sources/TianyiDrive/TianyiSession.swift`：626行。
- `App/AppModel.swift`：729行。

行为证据见FINAL-LOGIC-TEST-INDEX和本次新增定向交接；代码组织理由不是对未测试行为的豁免。

## 非授权diskit链接

PLAN.md:239指定ASWebAuthenticationSession授权回调，PLAN.md:424明确diskit://用途为OAuth回调。阶段一没有其它深链业务或FSKit挂载入口；K-05同时使用各提供方支持的回调方式。保留WebAuthorization会话内接收及OAuthCallback严格验证，不新增打开位置、执行文件操作等深链产品能力。

OAuth以外diskit://链接不受支持，不执行任何外部链接携带的文件/设备操作。它们没有独立业务路由；不把“注册scheme但没有onOpenURL”误写为OAuth授权接不到回调，也不承诺未知链接一定打开指定窗口。真实授权仍按ACCEPTANCE的各平台回调步骤验收。
