# 编辑器与网页登录交接证据

本页是实现与待验收清单，不表示编译、测试或截图已通过。实现日为 2026-11-04；最终构建与截图由主任务统一执行。

| 编号 | 当前实现与可核对入口 | 仍需验收 |
| --- | --- | --- |
| UI-EDIT-01 | `App/KayoiApp.swift` connection 场景根据持久列表是否包含 id 决定添加/编辑标题；`ConnectionEditorModel.isEditing` 同条件控制上一步。`discoveredDraftIsAdditionAndCanReturnToTypes`、`editingAnExistingShareRemainsEditing` | 发现入口和编辑窗口截图 |
| UI-EDIT-02 | KayoiApp 默认 640×640；ConnectionEditor 最小 560×520；EditorWindowAccessor 在实际窗口注册非演示尺寸保存 | 拖动尺寸、重新打开、两步高度截图 |
| UI-EDIT-03 | `ConnectionTypePicker.swift` 四列 96 高、TypeIcon 40；`ConnectionTypeCatalog.swift` 中文/英文/拼音/首字母；HTTPS WebDAV 合一；方向键、Return、双击 | 全键盘路径与 560 宽截图；`typeSearchSupportsInitialsAndMergesWebDAV` 待运行 |
| UI-EDIT-04 | `ConnectionFormView.swift` 原生 grouped Form，位置/连接/选项，系统挂载类型才展示自动挂载 | 各表单控件右缘、长文与滚动截图 |
| UI-EDIT-05 | `ConnectionEditor.swift` 表头 TypeIcon 48、类型和说明，无重复大标题 | 浅深色截图 |
| UI-EDIT-06 | `EditorTextRow.swift`/`EditorPasswordRow.swift` 失焦标记；`EditorValidation.swift` 必填及 URL；model.canSave/busy/账号状态；底栏缺项说明 | `editorDefersRequiredFieldErrorsUntilBlur`、`editorRejectsUneditedWebDAVTemplate` 待运行 |
| UI-EDIT-07 | `SMBConnectionForm.swift` 注册/访客分段、密码内部眼睛、共享菜单含类型安全的手动选项、列出共享禁用解释 | 访客/账号/已列出菜单截图；真实共享列表需用户验收 |
| UI-EDIT-08 | `WebDAVConnectionForm.swift` 与 `Logic/WebDAVPresets.swift` 七预设、说明、HTTPS 开关和 HTTP 警告；USERNAME 模板阻止保存 | 七服务真实地址与应用密码入口由用户按其部署版本验证 |
| UI-EDIT-09 | `AndroidConnectionForm.swift` 本地化设备名与序列号后四位；空态；`PairingCodeField.swift` 六格、仅 ASCII 数字、粘贴、自动配对；错误清码可重输 | `pairingDigitsRejectsNonASCIIAndLimitsPaste`；真机与键盘截图 |
| UI-EDIT-10 | `CloudConnectionForm.swift` 登录某服务主按钮、账号头像/昵称/已知容量、切换账号；WebAuthorization 临时会话；实验提示；EditorAccountSummary 不把登录冒称连接测试成功 | OAuth 与网页真实切账号和容量；无返回头像时为通用头像，容量缺失明确显示暂不可用 |
| UI-EDIT-11 | `EditorPreparation.swift` 类型准备、Windows 账户密码非 PIN、鸿蒙 NEXT；四品牌说明只提示搜索设置入口 | 各品牌系统版本额外开关未冒写固定要求，列入真机核对，不能声明全部品牌步骤已实机验证 |
| UI-EDIT-12 | model.startSave/pairWirelessDevice/listShares 阶段状态，operations 统一追踪与 cancelWork，网页登录取消 | 授权/配对/保存中取消及恢复截图；事务清理最终测试 |
| UI-EDIT-13 | model.recordError 区分传输/鉴权，底栏重试、适用的重登录、复制；`ConnectionEditorModel+Permissions.swift` 仅发现权限明确拒绝时给系统设置入口 | 鉴权与网络失败、系统权限真实拒绝验收 |
| UI-EDIT-14 | 底栏上一步/取消/测试保存，Return 与 Cmd-Return、Esc | 键盘与长错误布局截图 |
| UI-EDIT-15 | 实际 EditorWindowAccessor 窗口注入授权工厂；蓝奏 clearsSharePassword 只传入事务保存，不提前删钥匙串 | 后台窗口授权与真实钥匙串清除由用户验收 |
| UI-EDIT-16 | 单独 Android/Camera/SMB/WebDAV/NFS/ObjectStorage/Cloud 表单；模型与校验/目录/配对数字进 `App/Logic`；协议注入授权器 | 新模型测试均待最终运行；包缓存不是当前接口，不能把旧缓存 typecheck 当编译结果 |
| UI-WEB-01 | `WebLoginWindowController.swift` 独立 720×640、min560×520、调整尺寸、非演示记尺寸 | 网页窗口全状态截图 |
| UI-WEB-02 | `WebLoginView.swift` 服务说明、域名、进度、加载失败重载；`ServiceWebLogin.swift` 非持久 WK 数据存储 | 官网实际登录页面兼容 |
| UI-WEB-03 | WebLoginState 验证成功结束 continuation 自动关窗；其他登录方式说明及粘贴；demo 原生本地内容，无 WK 请求/真实验证 | 成功、失败、其他方式矩阵；`demoWebLoginNeverRunsRealValidation`、`demoWebLoginErrorReloadStaysLocal`、`closedWebLoginIgnoresLateCredentials` 待跑 |
| FEAT-01 / K-01 | `ConnectionEditorModel+WebLogin.swift` 接入天翼/移动/迅雷与夸克/UC/蓝奏；CookieStore/官网请求凭据观察，验证后落会话，位置保存沿用钥匙串；手动粘贴仍可用 | 真实账号登录不得在本轮自动连接，必须列入 ACCEPTANCE；公开静态脚本证据 `/tmp/kayoi-web-login-evidence.md` |

## 检查记录

- 对编辑器、表单、模型和新增测试执行 `xcrun swiftc -frontend -parse`，退出 0；只表示语法通过。
- 对自有文件执行 `xcrun swift-format format -i`，没有格式化整个仓库。
- 自有跟踪文件 `git diff --check -- App/ConnectionEditor.swift App/KayoiApp.swift App/WebAuthorization.swift App/QuarkLoginView.swift` 退出 0。
- Web 组件较早版本局部 Swift 6 strict-concurrency typecheck 退出 0（`/tmp/kayoi-web-login-typecheck.log`）；后续变化仅语法检查，不把旧结果当最终验收。
- 编辑器类型检查无法用旧缓存证明：DerivedData 中 Swift 6.3.3 模块与当前 6.4.2 不兼容；另一兼容缓存缺最新 Core/ADB/CloudDrive 接口。结果记录 `/tmp/kayoi-editor-typecheck.log`，已停止缓存尝试，最终新构建统一验证。
- 未运行全套测试/构建、未启动应用、未登录真实账号、未连接真机、未提交。
- 新增 `ConnectionEditorModelTests.swift` 八条逻辑测试、`WebLoginCredentialTests.swift` 五条逻辑测试，均待统一执行。测试名与断言是准备好的证据入口，不是通过结果。

## 集中构建前补齐的硬项

### DS-25 保存后的名称与颜色撤销

- `App/Logic/ConnectionPresentationUndo.swift`：保存成功后以旧名称/颜色注册到 `AppModel.undoManager`，撤销调用 `ConnectionManager.setPresentation(id:name:color:)` 真实写入仓库，再注册相反操作支持重做；不会恢复旧参数、钥匙串或旧排序。
- `ConnectionEditorModel.startSave` 的演示与正式成功分支都注册，失败/取消不注册。
- Core 的 `setPresentation` 与 `presentationUndoChangesOnlyNameAndColor` 由面板代理提供；App 新增 `savedPresentationSupportsUndoAndRedoWithoutRestoringConnectionFields` 覆盖共享 UndoManager 的撤销和重做。
- 此处为实现与待跑测试证据，尚未经过菜单实际点击与新构建验证。

### §14.4 独立预览

- 七种独立连接表单、`ConnectionFormView` 各有五状态×浅深色共十个 `#Preview`。
- `ConnectionEditor` 新增五状态×浅深色完整窗口预览，保留原类型选择/编辑预览。
- `ConnectionTypeTile` 默认/选中各浅深色；`ConnectionTypePicker` 全部/空搜索/匹配搜索各浅深色。
- `EditorErrorBanner` 连接错误/需重新登录各浅深色；文本/密码/六格配对/空态组件都有独立浅深预览。
- `WebLoginView` 就绪/空态/加载中/加载失败/验证失败/成功各浅深色；`ServiceWebLogin` 的两个预览明确采用本地包装而非 WK 实例。
- `EditorPreview` 只构造演示 AppModel 与纯本地字段，无授权和保存操作。没有用预览定义代替画布/Computer Use 实际验收。

### §14.3 可稳定停留的演示状态

所有开关只在 `App/Logic/RuntimeOptions.swift` 读取，未设置 `KAYOI_DEMO=1` 时全部忽略：

```sh
KAYOI_DEMO=1 KAYOI_DEMO_EDITOR_TYPE=smb KAYOI_DEMO_EDITOR_STATE=testing
KAYOI_DEMO=1 KAYOI_DEMO_EDITOR_TYPE=googleDrive KAYOI_DEMO_EDITOR_STATE=success
KAYOI_DEMO=1 KAYOI_DEMO_WEB_SERVICE=mobile KAYOI_DEMO_STATE=web-error
```

- `KAYOI_DEMO_EDITOR_TYPE` 接受全部 `ConnectionKind.rawValue`，`KAYOI_DEMO_EDITOR_STATE` 接受 `blank/filled/error/testing/success`；`ConnectionEditorModel+Demo` 直接赋本地状态，不启动 Task、provider、保存或授权，测试和成功状态不会被计时器关闭。
- 网页服务接受 `quark/uc/tianyi/mobile/xunlei/lanzou`；网页状态为 `web-empty/web-loading/web-error/web-validation-error/web-success` 或普通就绪状态。验证失败也已在 WebLoginState 集中设置，不再仅预览可见。
- 启动时自动开相应演示窗口的接线由应用窗口代理负责；主任务需确认最终 KayoiApp 集成。
- `editorDemoSwitchesAreIgnoredOutsideDemo`、`editorDemoRuntimeSupportsEveryTypeAndStableState`、`editorDemoFixturesNeverStartOperationsOrSave` 已新增，待统一测试。
- 编辑器根部 `gridDiagnostics("editor")`，类型格与底栏接入网格区域/探针；系统 Form 仍使用系统布局。
- 新增代码已执行局部 `swiftc -frontend -parse`（退出 0），没有跑全量构建、测试或提交。

## 覆盖率补测与键盘焦点修正

- 针对集中覆盖率中 `ConnectionEditorModel` 142/873、网页登录扩展18/128的缺口，新增 `EditorWorkflowTests.swift`（保存/失败/取消/配对/共享/登录仅验证）、`EditorConfigurationTests.swift`（设备身份、默认值、失焦校验、切换账号、权限隔离）、`EditorProductionLoginTests.swift`（真实编排与本地传输桩）、`EditorLoginFixtures.swift`（全内存传输与provider）。
- 生产分支测试复用统一 `AppModelDependencies`，传入临时目录、内存钥匙串、无延迟假挂载、假HTTP、假provider、停用更新的控制器与全部无副作用系统接口；不调用 `AppModel.start()`，只安装 `configureConnections()`。OAuth只建立不可见窗口作为锚点，授权器立即返回本地构造的匹配state回调。
- 新生产用例覆盖 Google/OneDrive/Dropbox/百度 OAuth 交换及复用、阿里/夸克/UC/PikPak 登录及复用、天翼单/多家庭选择、移动/迅雷/蓝奏凭据验证、缺配置/缺锚点/缺凭据/网络失败时不保存。
- `WebLoginStateTests.swift` 和扩展 `WebLoginCredentialTests.swift` 覆盖去重、最新候选、取消迟到回调、手动与自动失败区别；观察脚本通过系统 JavaScriptCore 执行，浏览器全局对象和原fetch/XHR均为本地模拟。
- UI 单项：`ConnectionTypePicker.swift` 的 ScrollView 在 `.focusable()` 后加 `.focusEffectDisabled()`，只移除整块容器蓝色焦点框，保留格子选择样式与方向键/Return。对应原截图 `UI-EDIT-01-picker-keyboard-light-zh.png`；修后需主任务重截图再独立提交。
- 所有上述文件仅执行语法快检，未自行运行 xcodebuild、App测试或覆盖率；覆盖率改善必须以主任务新输出确认，不能按新增用例数宣称达标。

## Picker 空选择界面修正

对应截图 `docs/screenshots/v0.2/UI-EDIT-02-androidUSB-blank-light-zh.png`：USB、无线配对、理光与通用相机选择器缺少空字符串 tag，空选择时系统只画箭头。现统一提供「选择设备／配对设备／相机」选项；无候选仍使用已有空态及排查说明。家庭、共享空选项分别改为「选择家庭／选择共享」。候选中不含已有选择时，明确显示已保存但未发现的设备，或手动填写的家庭/共享，而不是空白。

本组只改选择器显示及必要词条，保留既有自动选择、发现入口预填和必填校验。已做局部语法检查；待主任务集中重建、重截图后独立提交。

## §14.2 演示采集菜单

- `App/DemoCommands.swift` 的「演示」菜单仅在 `model.options.isDemo` 显示。Control+Option+1/2/3/4/5 分别切空白、填写、错误、测试中、成功；Control+Option+L/D 切浅色/深色。
- `AppModel+DemoControls.swift` 的操作入口再次检查演示模式。外观只设置 `NSApplication.shared.appearance`，不修改系统偏好；RuntimeOptions 原始环境参数不变。
- AppModel 的可观察状态和递增请求号驱动已有编辑器；新编辑器 load 优先使用当前演示状态。`applyRequestedDemoState` 先取消、等待旧本地任务结束，再复用 `applyDemoFixture`，避免旧 defer 清掉新的稳定测试状态；不调用保存、网络或真实账号验证。
- `DemoControlTests.swift` 四条逻辑测试准备覆盖 live 忽略、已有/新窗口状态、取消后重置和外观白名单。只做语法检查，未自行启动 App 或执行全套测试，待集中构建与 CUA 快捷键验收。

## 保存行错误弹层的下一步提示

- `SavedConnectionRow.swift` 原固定「请检查网络和登录信息，然后重试。」现经 `ConnectionFailureAdvice.text(for:)` 按类型显示。USB 提示数据线/解锁/调试授权，无线提示同一 Wi-Fi 与配对，相机提示 USB/存储卡授权和占用应用；共享/对象存储复用 `EditorPreparation` 的协议步骤，网盘保留网络及登录信息检查。
- 未新增词条，全部复用已有类型准备/空态文案。扫描 App 的其余固定网络提示仅余局域网发现错误及其预览，与用途一致，未改动。
- 先把原固定文本提取为可测 helper，新增 `ConnectionFailureAdviceTests.swift`。用当前 Core.o/CoreNative.o 只链接该 helper 的独立逻辑程序，基线退出 1：`FAIL: USB 错误下一步仍指向网络或登录`。
- 修复后同一局部程序编译链接 helper 与 EditorPreparation，退出 0：`PASS: USB/相机下一步不指向网络或登录；无线包含配对；全部类型有下一步`。没有启动 App、运行全量测试或改动真实网络/设备。
- 待截图：保存行 USB、相机、无线错误详情弹层的下一步，确认复用的多行步骤换行与高度；中央测试再跑三个 ConnectionFailureAdviceTests 用例。
