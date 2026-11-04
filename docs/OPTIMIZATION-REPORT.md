# Kayoi 0.2 优化验收记录

本报告为进行中的证据账本。未列明通过的项目均未完成，历史 POLISH-REPORT 不作为本轮通过证据。真机、账号及真实菜单栏点击另列入 ACCEPTANCE，不能由替身测试代替。

## 起点

- 分支：master；起点提交 `12c1740` 仅新增 OPTIMIZATION 与 AUDIT 两份文档，`git show --format= --check 12c1740` 通过。
- 构建隔离：默认 `make gen` 使用 `Config/Validation.xcconfig`，没有包含本机密钥配置；真实凭据构建保留显式选择入口，见 README。
- TEST-01（部分）：`memorySecretLifecycle`、`memorySecretsAreIsolatedBetweenRuns` 使用内存存储替代原真实钥匙串测试。其他网络替身及未登记请求拒绝策略仍需逐包核实。

## 阶段进度

1. 基础：进行中；演示模式、应用逻辑测试、覆盖率门禁和资源颜色迁移尚未验收。
2. 不可用类型及数据安全：未开始。
3. 其余缺陷：未开始。
4. 设计基准：未开始。
5. 逐界面：未开始。
6. 图标：未开始。
7. 功能完善：未开始。
8. 文案与多语言：未开始。
9. 适配、无障碍、性能：未开始。
10. 自动更新与发布脚本：未开始。
11. 全量验收：未开始。

## 基础隔离门禁

- `git diff --check && make gen && make test` 通过；12 包共 244 项通过，证据：`docs/evidence/v0.2/foundation-isolation-test.log`。
- `make release` 退出码 0，签名校验通过，证据：`docs/evidence/v0.2/foundation-isolation-release.log`。尚未启动应用；不作为演示或界面验收。
- 源码：`Packages/Core/Sources/Core/MemorySecretStore.swift:5`，`Packages/Core/Tests/CoreTests/StorageTests.swift:24`，`Makefile:2`，`project.yml:30`。

## 应用逻辑测试与覆盖率入口

- `KayoiTests` 为不宿主主应用的单元测试目标，源码范围暂为 `App/Logic`；现有视图中尚未拆出的业务逻辑仍未覆盖，不能视为 App 覆盖率验收通过。
- `demoRequiresExplicitOptIn`、`demoOptionsSelectIsolatedScenario` 验证只有显式演示开关才启用隔离场景、面板窗口与伪语言。生产启动不受截图环境变量影响。源码：`App/Logic/RuntimeOptions.swift:3`、`Tests/KayoiTests/RuntimeOptionsTests.swift:3`。
- `make coverage` 逐包统计自有 Sources（包含未覆盖行，不计测试及依赖），对缺失测试目标、零行或低于 §13 门槛均失败；暂不配置系统薄封装例外。DevTool 尚无测试，预期不通过。输出位于 `build/Coverage/summary.txt`，基础测量已结束：包合计 69.69%，未达标，退出码非零；输出摘录 `docs/evidence/v0.2/coverage-baseline.log`。该基线的 App 9 行仅为开关解析，随后已将 AppModel 纳入统计，不能据该 100% 宣称 App 全部逻辑达标。
- 门禁通过：应用逻辑 2 项、包测试 244 项，发布构建与签名校验通过；输出摘录 `docs/evidence/v0.2/foundation-test-target.log`。

## 演示基础（FEAT-06，部分）

- `App/Logic/DemoFixtures.swift` 提供固定身份的 20 行、九类状态、长名称及全部类型补充场景；`DemoMountService` 仅在内存中登记挂载，不创建卷、不读系统挂载表。
- `AppModel` 在构造时选择临时配置、内存密钥及独立设置域，启动演示时提前返回，不注册真实发现、通知观察或自动挂载。保存与配对分流至假操作；设置指纹为固定样例，演示不生成真实密钥、不修改登录项、不请求系统通知。
- 测试：`appDemoStartsWithIsolatedServicesAndStorage`、`emptyDemoDoesNotShowDiscoveredDevices`、`demoFixturesCoverStatesAndKeepStableIdentities`、`demoMountLifecycleUsesOnlyMemory`、`demoAppearanceNeverChangesProduction`。
- 电脑控制基线：打开演示面板、添加类型页、设置页；点击模拟通知后显示“系统通知已允许”，没有系统授权弹窗。初始截图 `docs/screenshots/v0.2/FEAT-06-panel-baseline-dark-zh.png` 仅记录旧布局，不作为 §14.3 最终验收通过证据。
- 此次发现并修正：演示发现的主机与无线 GUID 不再和保存样例重合；混合状态只让系统共享呈现挂载状态，只让手机呈现 USB 授权状态。
- 尚未验收：完整假网页登录、伪语言、取消进度及全部截图矩阵。它们随逐界面实现继续补齐，当前 FEAT-06 不标为通过。

### 演示入口复核

- 当前源码证据：`AppModel.swift:27` 在构造时隔离存储，`:96` 在启动时分流，`:319` 拒绝演示模式取得真实 Provider；`App/Logic/DemoMountService.swift:29` 只更新内存挂载字典。
- `Tests/KayoiTests/DemoCancellationTests.swift:5` 的 `cancelDemoAuthorizationNeverStartsConnection` 修复前观察到 `calls = 1`、状态变为 `tested`，修复后要求调用次数为 0 且恢复 `disconnected`。旧临时失败日志已不在当前环境，以上为先前实际失败输出摘录；本轮重新执行完整门禁验证最终代码。
- 电脑控制已点击“取消”，无障碍树确认同一行变为“未连接 / 测试连接”：`docs/evidence/v0.2/demo-cancel-ax.txt`；截图 `docs/screenshots/v0.2/FEAT-06-panel-cancel-light-zh.png`。此结论只覆盖演示等待授权状态，真实异步连接的取消仍需后续完善。
- 五类发现均可见：`docs/screenshots/v0.2/FEAT-06-panel-discovered-light-zh.png`。这些是基础可操作性证据，旧布局的对齐、控件状态及最终矩阵仍未验收。

- 重新执行门禁通过：`git diff --check && make gen && make test && make release`，应用逻辑 8 项、包测试 244 项；发布构建及签名校验通过。输出摘录：`docs/evidence/v0.2/demo-foundation-gates.log`。

## 主题资源迁移（DS-11，基础部分）

- `App/KayoiTheme.swift:3` 的六个主题色已改读 `App/Assets.xcassets`，不再在主题代码中散写十六进制。每个色集包含浅色、深色及对应增强对比度四个不透明变体。
- `Tests/KayoiTests/ThemeAssetTests.swift:4` 的 `themeAssetsHaveOpaqueLightDarkAndHighContrastVariants` 检查六个实际使用的色集、全部四种组合及合法不透明颜色。Xcode 资源编译和完整门禁通过，应用逻辑 9 项、包 244 项；证据 `docs/evidence/v0.2/color-assets-gates.log`。
- 电脑控制观察演示空面板，确认深浅色主题资源正常解析、背景仍不透明：`docs/screenshots/v0.2/DS-11-panel-empty-light-zh.png`、`DS-11-panel-empty-dark-zh.png`。这些截图仍显示待修复的重复添加按钮和旧布局，不作为最终界面验收通过。
- 未覆盖：其他视图中散落的状态色与位置色会在 §3 设计基准阶段统一；DS-13 全部对比度组合尚未达标，增强对比度实际界面矩阵仍待后续验收。
