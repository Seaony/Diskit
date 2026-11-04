# Kayoi 0.2 优化验收记录

本报告为进行中的证据账本。未列明通过的项目均未完成，历史 POLISH-REPORT 不作为本轮通过证据。真机、账号及真实菜单栏点击另列入 ACCEPTANCE，不能由替身测试代替。

## 起点

- 分支：master；起点提交 `12c1740` 仅新增 OPTIMIZATION 与 AUDIT 两份文档，`git show --format= --check 12c1740` 通过。
- 构建隔离：默认 `make gen` 使用 `Config/Validation.xcconfig`，没有包含本机密钥配置；真实凭据构建保留显式选择入口，见 README。
- TEST-01（部分）：`memorySecretLifecycle`、`memorySecretsAreIsolatedBetweenRuns` 使用内存存储替代原真实钥匙串测试。其他网络替身及未登记请求拒绝策略仍需逐包核实。

## 阶段进度

1. 基础：进行中；演示模式、应用逻辑测试、覆盖率门禁和资源颜色迁移尚未验收。
2. 不可用类型及数据安全：进行中；FIX-01 至 FIX-05 已修复，FIX-06 刷新和资源失败保护已完成本地回归；FIX-07 本地并发与失败保存验收通过，真实账号另待用户验收；FIX-08 已修复并完成本地回归；FIX-09 移动冲突与上传临时文件替换已完成本地回归（系统命令并发边界见下文）；FIX-10 回收站请求已按官网静态客户端核对并完成本地回归；FIX-11 范围、验证页识别和精确大小已完成本地回归。
3. 其余缺陷：进行中；FIX-12 删除配置顺序与 FIX-13 编辑旧卷处理已修复，FIX-14 迟到回调清理已修复并通过本地门禁；FIX-15 地址匹配已通过本地回归及门禁，FIX-16 分页编码、官方签名示例及写前同名检查已通过本地门禁；FIX-17 的共享额度与 S3 接入已通过本地门禁，CloudDrive 接入已通过本地门禁，应用层会话复用待处理；FIX-18 起尚未处理。
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

## FIX-01：Google Drive 请求与容量解码

- 修复（审查 1C 严重第 1、2 条）：`Packages/CloudDrive/Sources/CloudDrive/GoogleDriveProvider.swift:15`、`:28`、`:39` 的连接、容量、账号请求统一通过查询项传入 `fields`，不再把问号编码进路径；`:380` 将容量字符串严格解析为非负 Int64，不经过浮点数、不把坏值当 0。
- 先失败后修复：`googleAboutUsesExactDocumentedURLAndStringQuota` 首先因错误 URL 得到 404；仅修地址后再次以 `DecodingError.typeMismatch` 失败；修正容量后通过。替身按完整 URL 匹配，其他地址返回 404，流请求直接失败，不访问网络。证据：`Packages/CloudDrive/Tests/CloudDriveTests/GoogleRequestTests.swift:51`、`docs/evidence/v0.2/FIX-01-regression.log`。
- `googleQuotaRejectsMalformedByteCounts` 覆盖非数字、Int64 溢出及负数；有效响应验证 Int64 最大值和大容量精确值。CloudDrive 包 37 项通过。
- 依据：[Google about.get](https://developers.google.com/workspace/drive/api/reference/rest/v3/about/get) 与 [About 结构](https://developers.google.com/workspace/drive/api/reference/rest/v3/about)。未登录或连接真实账号。无限容量未给 limit 的显示问题仍归审查 1C 容量条目处理，本项不宣称 Google 全流程验收完成。

- FIX-01 完整门禁通过：应用逻辑 9 项、包测试 246 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-01-gates.log`。

## FIX-02：Dropbox 昵称、路径和请求头

- 修复（审查 1C 严重第 3–6 条）：`Packages/CloudDrive/Sources/CloudDrive/DropboxProvider.swift:322` 显式解码 `display_name`；`:268` 将根目录转换为空字符串；`:286` 解析结构化 `path/not_found` 并映射 ENOENT；`:257` 对内容上传和下载的请求头统一转义 DEL 与全部非 ASCII UTF-16 单元，保留表情代理对。
- 先失败后修复：`dropboxProfileDecodesDocumentedDisplayName`、`dropboxRootUsesEmptyPath`、`dropboxMissingDestinationAllowsMove`、`dropboxContentHeadersRoundTripUnicodeAndDEL` 分别失败于缺失字段、400、EIO、非法头，修复后均通过；`dropboxUnknownLookupFailureNeverMoves` 从始至终确认未知错误不能被当成不存在。证据：`Packages/CloudDrive/Tests/CloudDriveTests/DropboxRequestTests.swift:77` 起五项测试、`docs/evidence/v0.2/FIX-02-regression.log`。
- 审查指出的旧测试需要澄清：`OfficialDriveProvidersTests.swift:593` 给的是 `{"error":{}}`，不是明确的 `path/not_found`；保留其 EIO 断言可防止未知错误触发写操作。新测试补上官方结构的“目标不存在后成功移动”路径，没有把所有 409 都当成不存在。
- 依据：[官方账号结构](https://github.com/dropbox/dropbox-api-spec/blob/main/users.stone)、[官方文件接口结构](https://github.com/dropbox/dropbox-api-spec/blob/main/files.stone)、[请求头 JSON 编码要求](https://docs.dropboxapi.com/dropbox-api/docs/technical-reference/json-encoding)。只使用本地替身，真实账号授权、文件操作和回收站结果仍待用户验收。

- FIX-02 完整门禁通过：应用逻辑 9 项、包测试 251 项；发布构建和签名校验通过，证据 `docs/evidence/v0.2/FIX-02-gates.log`。

## FIX-03：OneDrive 路径构造

- 修复审查 1C 重复编码问题，并核实修正同一构造器中缺少 `/v1.0`、根路径斜线的问题；无操作后缀的文件元数据地址采用官方文档形式，内容和子目录操作保留 `:/content`、`:/children` 分隔。源码：`Packages/CloudDrive/Sources/CloudDrive/OneDriveProvider.swift` 的 `itemURL`、`endpoint`、`encodedPath`。
- `oneDrivePathsEncodeEachSegmentOnce` 以六组独立输入检查中文、空格、加号、井号、表情和字面 `%20`；替身按官方完整地址匹配，未登记地址返回 404。验证连接、元数据路径往返、子目录和下载地址，且文件名不能变成 query 或 fragment。证据：`Packages/CloudDrive/Tests/CloudDriveTests/OneDrivePathTests.swift:43`、`docs/evidence/v0.2/FIX-03-regression.log`，修复前各组失败、最终 CloudDrive 43 项通过。
- 依据：[Microsoft 路径寻址与编码](https://learn.microsoft.com/en-us/graph/onedrive-addressing-driveitems)、[获取文件元数据](https://learn.microsoft.com/en-us/graph/api/driveitem-get?view=graph-rest-1.0)。未访问真实账号。跨目录移动的 `parentReference.path` 问题属于审查其余条目，尚未处理，不将本次编码修复当作移动全流程通过。

- FIX-03 完整门禁通过：应用逻辑 9 项、包测试 252 项；发布构建和签名校验通过，证据 `docs/evidence/v0.2/FIX-03-gates.log`。

## FIX-04：天翼下载链接、加号与分页

- 修复审查 1E 下载协议、文件名加号及分页截断：`TianyiProvider.swift:92` 只将 HTTP 升级为 HTTPS，已有 HTTPS 保持不变；`TianyiSession.swift:468`、`:557` 将查询和表单中的加号编码为 `%2B`；`TianyiProvider.swift:316` 起在服务报告仍有条目时继续翻页，未提供总数时继续到空页，声明仍有条目却返回空页则报错。
- 失败回归：`rangeReadUsesShortLivedURLAndValidatesContentRange` 增加 HTTPS 输入，原先抛 invalidResponse；`signedRequestsPreservePlusInQueryAndFormValues` 原先观察到查询与正文均为 `a+b`；`partialPagesContinueUntilReportedCountIsComplete` 原先只返回三项中的第一项。修复后通过；新增 `missingPageFailsInsteadOfReturningPartialDirectory`、`pagesWithoutCountContinueUntilEmptyPage` 验证不静默返回部分目录。证据：`Packages/TianyiDrive/Tests/TianyiDriveTests/TianyiDriveTests.swift:233`、`:704`、`:720`、`:742`、`:761` 和 `docs/evidence/v0.2/FIX-04-regression.log`。
- 分页 count 的历史定义参考[天翼开放平台文件列表文档](https://id.dlife.cn/html/api_detail_135.html)。当前个人/家庭接口的真实分页边界与签名下载链接仍待用户账号验收，不把替身结果作为线上通过。
- 完整门禁通过：应用逻辑 9 项、包测试 256 项，发布构建及签名校验通过；证据 `docs/evidence/v0.2/FIX-04-gates.log`。

## FIX-05：毫秒时间和固定时区

- 修复审查 1C 带毫秒时间退回 1970 的问题：`Packages/Core/Sources/Core/RemoteTimestamp.swift:3` 使用系统 ISO8601 格式策略统一解析有/无小数秒、有/无时区的日期；不依赖本机时区。Google、OneDrive、Dropbox 及 S3 的原单独解析入口全部接入。
- 公共 CloudDrive 入口保留原有无时区日期按东八区解释的约定，并补上空格分隔的毫秒格式：`CloudDriveSupport.swift:293`。Google、OneDrive、Dropbox、S3 的无时区兜底为 UTC；显式时区始终优先。
- 先失败后修复：`cloudTimestampsPreserveMillisecondsAndDefaultTimeZone` 六组样例原有四组失败，`officialProviderFileDatesPreserveMilliseconds` 三类 Provider × 两种时区格式原有六组失败，`s3ObjectDatesPreserveMilliseconds` 两组原均失败；修复后通过。证据：`Packages/CloudDrive/Tests/CloudDriveTests/TimestampTests.swift:15`、`:33`、`Packages/S3Drive/Tests/S3DriveTests/TimestampTests.swift:7`、`docs/evidence/v0.2/FIX-05-regression.log`。
- Core 的 `remoteTimestampKeepsFractionAndUsesUTCByDefault`、`remoteTimestampPreservesExplicitZoneAndRejectsInvalidInput` 另外验证默认时区、显式时区优先和非法输入。所有预期均为固定 Unix 时间，不等待真实时间、不修改系统时区。

- FIX-05 完整门禁通过：应用逻辑 9 项、包测试 261 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-05-gates.log`。

## FIX-06：刷新失败保护（阿里云盘、PikPak 部分）

- 修复审查 1D 的刷新异常一律作废登录：`AliyunOAuth.swift:256`、`PikPakSession.swift:262` 仅在明确的 loginRequired 错误时标记失效，其余错误原样返回，保持存储记录不变。刷新端点明确返回 `invalid_grant`（阿里亦保留已有 `RefreshTokenExpired` 处理）时才进入该分支；HTTP 状态本身不等于刷新令牌被拒绝。
- 先失败后修复：`oauthTransientRefreshFailurePreservesLogin`、`pikPakTransientRefreshFailurePreservesLogin` 各覆盖断网、429、500、无明确拒绝原因的 401，原来四组全部改变凭据且 hasToken 为 false，修复后保持原字节和可重试状态。对应 `oauthExplicitInvalidGrantRequiresNewLogin`、`pikPakExplicitInvalidGrantRequiresNewLogin` 验证明确信息仍要求重新登录。证据：`docs/evidence/v0.2/FIX-06-aliyun-pikpak-regression.log`。
- `oauthRefreshRecoversAfterTemporaryFailureWithoutLogin`、`pikPakRefreshRecoversAfterTemporaryFailureWithoutLogin` 实际完成 500 → 新令牌 → 请求成功的替身流程，确认下一次重试不需要再次登录。测试不等待重试时长，429 使用超过自动等待上限的响应头直接返回可重试错误。
- 完整门禁通过：应用逻辑 9 项、包测试 267 项；发布构建和签名校验通过。证据 `docs/evidence/v0.2/FIX-06-aliyun-pikpak-gates.log`。
- FIX-06 尚未整体通过：公共 OAuth 和天翼恢复路径仍待修复；跨进程并发刷新与密钥写入失败另由 FIX-07 处理。真实账号服务端错误码仍需账号验收，本轮未连接账号。

## FIX-06：公共 OAuth 与天翼恢复

- `OAuthSession.swift:332` 优先把 429、5xx 归为暂时错误；没有明确拒绝码的 401 不再删除凭据；明确 `invalid_grant` 也能在 HTTP 200 业务失败响应中识别。`commonOAuthTransientRefreshPreservesLogin` 和 `commonOAuthExplicitInvalidGrantInvalidatesLogin` 修复前分别发现丢登录与漏识别，修复后通过。
- `TianyiSession.swift:417` 起只在明确拒绝授权时作废记录；`:444` 不再吞掉网络、限流、服务故障并盲目切换备用登录；`:465` 集中判断恢复端点的明确拒绝码。成功恢复后若资源请求仍鉴权失败，保留新会话，不删除整份账号信息。
- 天翼 `tianyiTransientRestorationPreservesLogin` 覆盖断网、429、500、无明确原因的 401，原来均删除记录，修复后保留原字节；`tianyiExplicitInvalidGrantInvalidatesLogin` 保留明确拒绝后的重新登录行为。`tianyiRestorationRecoversAfterServerFailure` 与 `commonOAuthRefreshRecoversAfterServerFailure` 验证失败后下一次成功恢复。证据：`docs/evidence/v0.2/FIX-06-oauth-tianyi-regression.log`。
- 旧天翼测试把家庭 SessionKey 失败和无明确原因的 401 固定成删除整份账号，已修正为 `familySessionKeyFailurePreservesRecoverableLogin`、`authenticationFailureWithoutExplicitRejectionPreservesStoredCookieSession`。这类资源/会话错误并不能证明 Cookie 与刷新凭据都已失效。
- 完整门禁通过：应用逻辑 9 项、包测试 273 项；发布构建、签名校验通过。证据 `docs/evidence/v0.2/FIX-06-oauth-tianyi-gates.log`。
- 四套恢复路径的暂时故障矩阵现已覆盖。仍需追踪资源请求二次鉴权失败时其他驱动主动 invalidate 的路径，以及 FIX-07 的并发刷新/多进程与存储失败；FIX-06 暂不标为全链路通过。

## FIX-06：资源二次鉴权失败保护

- 移除公共 OAuth 普通/流式请求、百度三条重试路径、115 与 123 业务鉴权重试、阿里云盘普通/流式请求、PikPak 重试中的资源失败作废凭据行为。请求仍报错，不把错误改成成功，但不删除或标记刚刷新的账号信息。阿里云盘 `PermissionDenied` 归为 EACCES，不再推断为授权撤销。
- 失败回归：`commonOAuthSecondResourceRejectionPreservesNewToken`（普通与流式）、`baiduPreservesLoginAfterASecondUnauthorizedResponse`、`driveBusinessAuthFailurePreservesRefreshedLogin`（115/123 × HTTP/业务失败）、`oauthSecondUnauthorizedResponseStopsAndNeedsLogin`、`oauthPermissionFailurePreservesLoginWithoutInvalidation`、`pikPakSecondResourceRejectionPreservesRefreshedLogin`，修复前均观察到凭据被删或作废；修复后保留轮换后的刷新令牌。证据：`docs/evidence/v0.2/FIX-06-resource-auth-regression.log`。阿里权限失败另覆盖普通与流式分支，确认不发送登录失效通知。
- 四套会话的暂时恢复失败与后续资源拒绝现已有回归；明确刷新拒绝的已有测试保持通过。当前源码仅保留缺少可用凭据或明确刷新拒绝时的失效处理，以及显式 invalidate 接口。跨会话/多进程竞争和存储失败仍由 FIX-07 处理，真实服务码需账号验收。
- 完整门禁通过：应用逻辑 9 项、包测试 276 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-06-resource-auth-gates.log`。

## FIX-07：同会话迟到的旧令牌 401（部分）

- `OAuthSession.swift:179`、`:190` 保留每次实际发出的令牌，在 `:234` 刷新入口比较当前令牌；当其他请求已经刷新时，迟到的旧令牌 401 直接复用新令牌，不再强制刷新第二次。
- `tenDelayedUnauthorizedRequestsShareOneRefresh`（`OAuthSessionTests.swift:398`）通过 continuation 精确安排 10 个旧令牌请求：先放行一个 401，等待新令牌请求成功后才返回余下 9 个 401。普通和流式两种方式修复前均发生重复刷新，修复后均只刷新一次、10 个请求全部成功；不靠 sleep 或真实时钟制造竞态。证据 `docs/evidence/v0.2/FIX-07-delayed-401-regression.log`。
- 完整门禁通过：应用逻辑 9 项、包测试 277 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-delayed-401-gates.log`。
- FIX-07 尚未通过：本提交不证明不同会话/不同进程只刷新一次，也不证明存储新令牌失败后的保留与恢复；独立业务鉴权驱动的显式刷新入口也仍需接入拒绝令牌比较。上述项目继续处理，不能据本测试宣称并发刷新整体完成。

## FIX-07：新凭据写入失败后的重试（部分）

- `Packages/Core/Sources/Core/RecoverableSecretStore.swift:5` 在底层写入失败时保留内存中的待保存值并返回原错误；下次读取先重试保存，成功后清除待写值，不缓存正常读取。四套授权/恢复会话使用该存储包装；公共 OAuth 和天翼写入前清理旧的内存缓存，避免绕过补写直接继续使用。没有新增明文落盘位置，没有访问真实钥匙串。
- 先失败后修复：`commonOAuthRetriesPersistingRotatedTokenBeforeRefreshingAgain`、`aliyunRetriesPersistingRotatedTokenBeforeRefreshingAgain`、`pikPakRetriesPersistingRotatedTokenBeforeRefreshingAgain` 原来重用已轮换失效的旧刷新令牌而再次要求登录；`tianyiRetriesPersistingRecoveredSessionBeforeUsingIt` 原来只继续使用内存新会话、底层仍是旧记录。现在四项均在存储恢复后补写成功，刷新/恢复请求只发生一次。证据 `docs/evidence/v0.2/FIX-07-persist-regression.log`。
- Core 的 `failedSecretWriteRemainsPendingUntilSaved` 验证持续写入失败会继续报错、旧存储不被误改、恢复后保存新值；`explicitDeletionClearsPendingWriteOnlyAfterSuccess` 验证显式删除失败不会丢弃待写值，成功删除后不会复活。
- 完整门禁通过：应用逻辑 9 项、包测试 283 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-persist-gates.log`。
- 边界：待写值保存在当前进程内存，进程退出后的恢复不作保证；跨会话与跨进程刷新协调仍未完成，不能将本次存储恢复测试作为 FIX-07 整体通过。

## FIX-07：独立业务鉴权入口与百度上传重试（部分）

- `Packages/CloudDrive/Sources/CloudDrive/OAuthSession.swift:217` 接受被拒绝的实际令牌；百度三处重试（`BaiduDriveProvider.swift:328`、`:340`、`:353`）、115（`Drive115Provider.swift:410`）、123（`Drive123Provider.swift:304`）均传入原请求中的令牌，复用其他请求已取得的新值。
- `OfficialDriveProvidersTests.swift:881` 的 `providerLateRejectionReusesAlreadyRefreshedToken` 在原请求返回 401 前确定性完成另一次刷新。百度、115、123 三组修复前都重复刷新，修复后只刷新一次且连接成功。不是靠等待时间碰运气，也未连接实际账号。
- 同时处理审查 1C 的百度 multipart 重试正文损坏：`OAuthRequestToken.swift:4` 只替换已有认证字段，不把 multipart 或任意 UTF-8 文件当表单。`baiduUploadRetryPreservesMultipartBodyAndUpdatesBearer`（`OfficialDriveProvidersTests.swift:822`）修复前观察到正文由 233 字节变为 176 字节、旧认证头未更新、URL 被额外添加令牌；修复后正文与 URL 均保持原样，认证头更新为新令牌。
- `OAuthRequestTokenTests.swift:6`、`:25` 额外验证表单加号解析、百分号编码、空字段和无关参数保持，以及 JSON、multipart、二进制正文不被解释为认证字段。失败与通过证据：`docs/evidence/v0.2/FIX-07-explicit-regression.log`。
- 本次仍只证明同一会话内的重试行为。不同会话与 App/命令行跨进程刷新协调继续处理，FIX-07 尚未整体通过。
- 完整提交门禁通过：应用逻辑 9 项、包测试 287 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-explicit-gates.log`。仅存在已有的 AppIntents 元数据跳过提示。

## FIX-07：其他会话更新、删除凭据后的可见性（部分）

- `Packages/CloudDrive/Sources/CloudDrive/OAuthSession.swift:402` 不再用永久内存缓存替代存储读取；`Packages/TianyiDrive/Sources/TianyiDrive/TianyiSession.swift:516` 和 `:202` 同样每次从存储取得当前会话。移除相应缓存字段和赋值，仍保留 `RecoverableSecretStore` 的失败写入补存机制。
- `commonOAuthObservesCredentialsChangedByAnotherSession`（`OAuthSessionTests.swift:444`）创建两个共用存储的真实授权会话：第一个已读旧令牌，第二个完成刷新后，第一个必须看到新访问令牌与新刷新令牌；第二个删除凭据后，第一个不能继续认证。修复前四条断言失败，修复后通过。
- `tianyiObservesCredentialsChangedOutsideTheSession`（`TianyiDriveTests.swift:869`）验证已连接的会话在存储替换后发出新的 SessionKey，存储删除后直接返回未授权且不再发网络请求。修复前仍使用旧密钥并在删除后继续请求，修复后通过。两包全量测试也通过；证据 `docs/evidence/v0.2/FIX-07-storage-reload-regression.log`。
- 已检查同类路径：阿里云盘 `AliyunOAuth.swift:210`、PikPak `PikPakSession.swift:171` 原本每次读取存储，无该永久凭据缓存，未做无关改动。
- 这些测试证明存储改变后的可见性，不证明并发刷新互斥或跨进程完整行为。FIX-07 仍未整体通过；下一步仍需在读取、刷新、持久化的整个区间进行账号级协调。
- 完整提交门禁通过：应用逻辑 9 项、包测试 289 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-storage-reload-gates.log`。

## FIX-07：账号刷新文件锁与公共授权接入（部分）

- `Packages/Core/Sources/Core/CredentialRefreshLock.swift:7` 使用系统 `flock` 的非阻塞独占锁，在异步等待时释放执行线程；取消或失败关闭描述符，正常释放可重复调用，拒绝最终路径为符号链接。锁文件内容为空；文件名使用系统 CryptoKit 的 SHA-256 派生，不包含原始账号键或令牌，没有手写密码学。
- `Storage.swift:63` 为真实钥匙串的服务名与账号键生成稳定锁路径，放在应用数据目录以免清理缓存时破坏互斥；`MemorySecretStore.swift:11` 使用随机实例标识与临时目录；存储包装透传路径（`RecoverableSecretStore.swift:11`）。其他存储默认按类型及键在临时目录协调。测试只计算真实存储的路径，未打开真实钥匙串或创建真实存储目录。
- `OAuthSession.swift:246` 在持锁期间重新读取当前记录、判断是否已有新令牌、执行刷新并保存；明确刷新拒绝导致的失效处理也在锁内。等待期间其他会话已保存新值时，普通过期刷新与显式强制刷新均复用新值。
- `separateOAuthSessionsReuseRefreshCompletedWhileTheyWait`（`OAuthSessionTests.swift:518`）用读取观察点确定第二个会话已读到过期记录，才放行第一个会话的刷新响应；修复前重复刷新并返回另一份令牌，修复后普通与强制刷新两组均只刷新一次。`tenDelayedUnauthorizedRequestsShareOneRefresh`（`:400`）扩展为同会话/十个独立会话 × 普通/流式四组，十个请求均成功且只刷新一次。证据 `docs/evidence/v0.2/FIX-07-refresh-lock-regression.log`。
- `CredentialRefreshLockTests.swift:19` 启动独立 Python 子进程尝试同文件的系统锁，父进程持锁时退出 7，释放后退出 0；`:31` 验证等待可取消且不释放别人的锁；`:43` 验证符号链接不改写目标；`:55` 验证存储实例、服务与账号的锁路径隔离。
- 首次完整门禁发现 ADB 测试进程崩溃。一次 HEAD 对照通过，当前源码增量复测仍崩溃；系统栈落在旧测试模块的 SecretStore 协议见证调用。清理包缓存后当前源码 26 项通过，与新增协议方法后旧测试产物未重编译相符。证据 `docs/evidence/v0.2/FIX-07-refresh-lock-build-cache.log`；未把失败门禁计为通过，未修改无关包。
- 边界：独立进程证据目前证明系统锁互斥，不等于 App 与命令行完整刷新流程验收。阿里云盘、PikPak、天翼仍待接入；保存失败的待写值仍需跨会话协调。FIX-07 尚未整体通过。
- 清理构建缓存后的完整提交门禁通过：应用逻辑 9 项、包测试 294 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-refresh-lock-gates.log`。

## FIX-07：阿里云盘、PikPak 与天翼接入刷新锁（部分）

- `Packages/AliyunDrive/Sources/AliyunDrive/AliyunOAuth.swift:244`、`Packages/PikPakDrive/Sources/PikPakDrive/PikPakSession.swift:204` 在取得账号文件锁后重读凭据；其他会话已刷新时直接复用新记录。刷新、保存及明确拒绝后的失效处理均在持锁期间完成。PikPak 原本在共享任务结束之后保存，现移入持锁任务，避免锁先释放而记录尚未保存。
- `Packages/TianyiDrive/Sources/TianyiDrive/TianyiSession.swift:430` 在锁内比较当前记录与失败请求实际使用的记录。不同则复用当前记录，相同才恢复；保存成功后释放锁，资源重试在锁外执行。恢复过程的明确拒绝也在锁内处理。
- 失败回归：`aliyunSeparateSessionsShareRefresh`（`OAuthTests.swift:449`）、`pikPakSeparateSessionsShareRefresh`（`PikPakTests.swift:517`）、`tianyiSeparateSessionsShareRestoration`（`TianyiDriveTests.swift:885`）均先确认第二个会话已读取或发出旧凭据请求，才放行第一次刷新响应；三项修复前均发生两次刷新/恢复，修复后仅一次且两个调用均成功。随后扩展为同一会话与独立会话两组。证据 `docs/evidence/v0.2/FIX-07-provider-locks-regression.log`、`docs/evidence/v0.2/FIX-07-provider-locks-gates.log`。
- 完整门禁通过：应用逻辑 9 项、包测试 297 项，发布构建和签名校验通过。四套会话均已接入账号文件锁；本轮未连接真实设备、网盘、账号或钥匙串。
- FIX-07 尚未整体通过：待保存的新凭据目前仍属于各存储包装实例，需要继续处理跨会话共享及其持锁生命周期；独立进程的完整授权替身流程也仍待补证据。

## FIX-07：待保存凭据共享与失败期间持锁（部分）

- `Packages/Core/Sources/Core/RecoverableSecretStore.swift:13` 按存储身份与账号对应的锁路径共享待保存值；条目持有底层存储，避免类实例地址复用后误认账号。`Storage.swift:50` 的默认类存储身份包含实例标识，内存存储原有随机身份与钥匙串的稳定服务身份不变。嵌套包装展开到同一底层存储，避免重入共享互斥锁。
- 四套会话均改用包装的 `acquireRefreshLock`、`releaseRefreshLock`（`RecoverableSecretStore.swift:23`、`:29`）。保存失败时条目保留文件锁；另一会话读取或等待锁时先重试补存。仍无法保存就返回存储错误，不使用旧刷新令牌；补存或显式删除成功后才释放保留的锁。凭据仍只暂存当前进程内存，锁文件不保存凭据。
- 四项既有持久化失败测试新增 `newSession: true`：公共授权、阿里、PikPak 修复前抛 loginRequired，天翼修复前重复恢复；修复后新旧会话两组均能补存且只刷新/恢复一次。`failedWriteIsSharedBetweenStoreWrappers`（`RecoverableSecretStoreTests.swift:52`）修复前新包装读到旧值且未报保存错误，修复后通过。证据 `docs/evidence/v0.2/FIX-07-shared-pending-regression.log`。
- `pendingSecretRetainsProcessLockUntilSavedOrDeleted`（`:66`）用独立子进程验证失败期间不能取得锁，补存/删除成功后可以；`refreshWaiterRetriesPendingWriteAndReportsStorageFailure`（`:89`）验证等待者不会绕过补存错误，存储恢复后可补存并取得锁；`pendingSecretsDoNotCrossStoreInstancesOrAccountKeys`（`:108`）覆盖不同实例、不同账号及嵌套包装。
- 追踪显式删除发现连接管理器原先直接删底层记录，遗留待保存值会被后续读取复活。`ConnectionManager.swift:191` 的删除入口改用同一恢复包装；`deletingConnectionClearsPendingRefreshedCredentials`（`ConnectionTests.swift:557`）在阿里专用键与公共授权键两组中先复现删除后重新写回，修复后保持删除。
- 边界：进程异常退出后的内存恢复不作保证；没有为此另建明文凭据文件。独立进程的完整授权替身流程仍待补充，当前证据不等同于真实 App/命令行账号验收。FIX-07 尚未整体通过。
- 完整提交门禁通过：应用逻辑 9 项、包测试 302 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-shared-pending-gates.log`。


## FIX-07：独立进程完整授权流程与本地验收结论

- `Packages/CloudDrive/Tests/CloudDriveTests/ProcessRefreshTests.swift:75` 启动两个独立测试进程，各自创建实际 OAuthSession，共享临时文件存储和账号锁。传输替身在两进程都读过旧凭据后才允许刷新完成；两进程完成资源请求并保留登录，父进程断言刷新事件恰好一次，最终访问令牌与刷新令牌均为新值。
- 请求全部进入 `ProcessRefreshHTTP`（`:43`），只接受 `refresh.invalid` 的两条已登记路径，不建立网络连接；磁盘文件仅包含固定假令牌，测试结束删除临时目录。测试运行器通过继承的测试环境加载测试 bundle，没有启动 Kayoi 应用、真实命令行或设备发现。
- 负向对照仅在测试存储中临时把共享锁路径拆成每进程独立路径：同一测试观察到两次刷新及一个子进程 loginRequired，退出 1；随后恢复共享路径。证据 `docs/evidence/v0.2/FIX-07-process-refresh.log`，证明测试能发现进程间没有共享锁的问题。
- 本地验收结论：十个并发 401 的单次刷新、四套会话的共享刷新、不同进程的互斥与凭据可见性、保存失败的保留/补存/持锁、显式删除待保存凭据均已有相应回归和证据。FIX-07 本地验收通过；前文各“部分”记录描述对应历史提交，不覆盖本节新增证据。实际 App 与 kayoi-dev 的账号授权、系统钥匙串交互仍列入 ACCEPTANCE 待用户验收。
- 进程异常退出会丢失尚未写入钥匙串的内存值，这是当前失败保留机制的明确边界；未通过另建明文凭据文件规避系统存储失败。刷新任务的统一等待期限另随 FIX-18 核查。
- 本次完整提交门禁通过：应用逻辑 9 项、包测试 303 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-07-process-gates.log`。


## FIX-08：普通文件错误保留连接，传输故障重建会话

- `Packages/ADB/Sources/ADB/ADBSession.swift:181` 根据底层传输/协议是否已失败决定处理方式：普通服务错误关闭当前服务流后复用连接，底层读写失败或取消关闭整条传输。接收空数据视为断线，损坏的协议帧不继续复用。
- `ADBSync.swift:138` 统一处理 stat、list、上传、下载初始化及 shell 错误；下载游标同样保留能正常关闭服务流的连接，不再因为权限拒绝就报废整条会话。原错误仍返回调用方，没有改成假成功。
- `ADBSync.swift:107` 在连接失败或断开后使用会话工厂创建新传输；工厂暂时失败可再次重试，旧传输和旧 SD 卡路径不会沿用。`ADBProviderFactory.swift:11` 每次重建重新选择同机 USB 或解析无线端点；直接 USB 构造路径（`ADBSync.swift:101`）同样重新发现设备。只注入单个会话而不提供工厂的调用者不能凭空重建传输；实际生产入口均提供工厂。
- `missingPathDoesNotDiscardADBConnection`（`ProtocolTests.swift:316`）在 v1/v2 两种协议中先返回 ENOENT，再列目录。修复前连接被关闭且第二次操作 notConnected；修复后正常。`adbCanReconnectAfterTransportFailure`（`:343`）先复现关闭后重连失败，再通过新增工厂注入新假传输，覆盖断线、EIO、ETIMEDOUT × 工厂首次成功/失败共六组，最终列目录成功。
- `ordinaryADBServiceErrorsAllowTheNextOperation`（`:379`）覆盖列表、下载、上传、shell 权限错误和未知 shell 退出错误五组；错误后下一次列目录成功，底层连接未关闭。与底层 EIO 重建测试共同证明不单凭错误码区分文件错误和传输故障。证据 `docs/evidence/v0.2/FIX-08-regression.log`。
- 本地回归通过，未连接设备。USB 重插、无线端口改变、真实手机授权提示仍列入 ACCEPTANCE 待用户验收。
- 完整提交门禁通过：应用逻辑 9 项、包测试 306 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-08-gates.log`。


## FIX-09：移动目标冲突处理（部分）

- `Packages/ADB/Sources/ADB/ADBSync.swift:304` 移动前检查目标文件、目录及悬空链接；存在则返回 EEXIST。实际移动使用 `mv -nT --`，防止普通同名覆盖或移入目录；命令返回后仍检查源路径，避免将 `-n` 的跳过当成成功。shell 对本段脚本的完整冲突消息映射为 EEXIST，不凭文件名中的零散文字推断冲突。
- 命令选择依据：[Toybox 官方 mv 实现](https://github.com/landley/toybox/blob/master/toys/posix/cp.c) 的 `-n`、`-T` 定义与跳过行为。其内部仍是存在性检查后调用 rename，不能据此宣称跨进程原子拒绝覆盖；本次没有虚构这种保证。
- `adbMoveRejectsExistingTargetsWithoutChangingSource`（`MoveSafetyTests.swift:94`）覆盖已有普通文件、目录、悬空链接及进入 mv 时出现的新目标。假传输把实际发出的 shell 脚本放到本地临时目录执行，mv 替身模拟不覆盖时返回 0 的行为；修复前静默覆盖/移入、源路径消失，修复后 EEXIST 且源与目标保留。
- `adbMoveQuotesPathsAndMovesToExactMissingTarget`（`:124`）验证中文、emoji、空格、引号及命令替换字符保持原义，成功后仅精确目标存在，没有执行文件名中的命令。所有 shell 测试的工作目录及文件操作都在临时目录，未调用设备 shell。失败与通过证据：`docs/evidence/v0.2/FIX-09-move-regression.log`。
- FIX-09 尚未整体通过：上传仍需改为同目录临时文件完成后替换目标；真实设备的命令选项支持与并发外部改动行为另需用户验收。不支持选项时返回错误，不回退到无保护的普通 mv。
- 本组完整提交门禁通过：应用逻辑 9 项、包测试 308 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-09-move-gates.log`。


## FIX-09：上传完成后替换目标与中断保护

- `Packages/ADB/Sources/ADB/ADBSync.swift:262` 将 SEND/SND2 目标改为最终目标同目录下的随机 `.kayoi-upload-*.tmp` 文件。收到上传完成确认并关闭传输服务后，检查取消，再通过 `mv -T --` 替换精确目标（`:298`）；不先删除或截断原文件，不把临时文件移入目标目录。
- 上传或提交失败时（`:300`），保留原错误，连接仍可用则尝试删除本次临时文件；清理结束前保持操作占用状态，清理本身失败也更新会话状态。传输断开或取消后无法访问设备时可能遗留临时文件，不能据本地测试宣称断线时也已清理。
- `executeShell`（`:352`）复用新版命令通道，并为旧版设备命令通道增加随机结束标记和退出状态解析；命令在子 shell 中执行，内部 exit 不会跳过状态报告。旧、新传输协议均使用同一安全提交顺序，未以直接覆盖作为兼容回退。
- `adbFailedUploadKeepsOriginal`（`UploadSafetyTests.swift:8`）覆盖旧/新协议 × 传输中断、服务端空间不足、提交权限错误六组。修复前原文件均被写坏，部分情况甚至未报告错误；修复后断言具体错误、实际发送一次数据、原文件逐字节不变，连接可用的失败场景无临时文件残留。
- `adbUploadPublishesOnlyAfterCompletion`（`:37`）覆盖旧/新协议 × 零字节/非空文件，检查实际命令记录中 DONE 早于提交、临时路径不同于目标、最终内容与清理结果正确。`adbCancellationBeforePublishKeepsOriginal`（`:61`）在最后一块进度回调取消上传，确认不会发出提交命令；`adbUploadNeverMovesTemporaryFileInsideTargetDirectory`（`:81`）确认目录目标不接收临时文件。证据 `docs/evidence/v0.2/FIX-09-upload-regression.log`。
- 原分包线协议测试已补上必需的提交/清理命令响应；移动冲突和带特殊字符路径的测试同时扩展到旧、新命令通道。所有文件操作在本地临时目录，未连接手机。
- FIX-09 指定的本地上传保护与普通移动冲突流程已验证。系统 mv 对外部进程同时改动目标的并发窗口仍按上一节如实保留，不宣称原子拒绝覆盖；真实设备文件系统、命令选项和断线残留清理另待用户验收。
- 最终版本完整提交门禁通过：应用逻辑 9 项、包测试 312 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-09-upload-gates.log`。


## FIX-10：迅雷与移动云盘使用官网回收站请求

- 从两站无需登录的官网 HTML 定位静态资源，核对了页面删除提示、动作编号和请求封装，没有连接真实账号或调用数据 API。来源 URL、SHA-256 与字节定位见 `docs/evidence/v0.2/FIX-10-public-client.md`，不凭接口名称猜测删除语义。
- 迅雷官网将 `trashFile` 与永久批量删除分开；`XunleiProvider.swift:502` 改为 PATCH files/{id}/trash，空对象正文。上传失败、创建冲突的清理入口（`:519`）也走回收站，源码中不再调用 files:batchDelete。
- 移动官网普通删除提示可恢复，对应动作 201 → recyclebin/batchTrash；回收站“永久删除”对应 202 → file/batchDelete。虽然适配层将后者命名为 logicalDelete，页面调用链证实不能据此保留旧实现。`MobileCloudProvider.swift:352` 和 `:399` 的删除及清理均改为 recyclebin/batchTrash，fileIds 保持准确目标。
- `cloudRemovalUsesRecoverableEndpoint`（`ChinaWebDriveTests.swift:641`）覆盖两个平台 × 文件/目录四组；替身按具体方法与路径匹配，未登记路径返回 404。修复前两平台均请求错误端点而失败；修复后方法、路径、正文正确，非递归删除非空目录仍先拒绝。`trashFailureNeverFallsBackToPermanentDeletion`（`:671`）确认回收站端点拒绝后不会改发永久删除。
- 原迅雷测试曾将 batchDelete 固定为“回收站”预期，现更正为官网契约；移动 `mobileCloudMkdirMoveAndDeleteUseDocumentedOperations` 实际没调用删除，已更名为 `mobileCloudMkdirAndMoveUseDocumentedOperations`，并另补真实调用 remove 的测试，处理审查中关于移动云盘删除测试覆盖的失实记录。`mobileCloudUploadFailureTrashesOnlyTheNewFile`（`:688`）另复现并修复失败清理的永久删除。证据 `docs/evidence/v0.2/FIX-10-regression.log`。
- 本轮只发送回收站请求，不在失败后自动改为永久删除，因此无需引入永久删除确认入口。真实账号中可见、可恢复及平台保留期限仍为待用户验收；不能将替身请求通过写成服务端已验证。
- 完整提交门禁通过：应用逻辑 9 项、包测试 315 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-10-gates.log`。


## FIX-11：范围读取依据实际响应并检查正文长度（部分）

- `Packages/LanzouDrive/Sources/LanzouDrive/LanzouProvider.swift:74` 不再按页面解析出的大小裁剪或跳过范围请求；实际请求保留调用方范围。`LanzouSession.swift:239` 改为检查 Content-Range 自洽性：起点匹配、末端未超过请求，短范围只在响应明确到达文件末尾时接受，不要求总长度等于页面估算值。
- `LanzouDownloadBody.swift:3` 逐块核对实际下载字节数；少字节在结束时报错，多字节在交付超量块之前报错，取消保持取消错误。范围请求按 Content-Range 推导长度；完整下载按响应 Content-Length 校验，两个长度头不一致直接拒绝。
- `lanzouRangeUsesResponseTotalInsteadOfPageSize`（`LanzouDriveTests.swift:363`）三组分别覆盖超过页面大小、实际总量不同及文件末尾短范围；修复前空返回或误报 invalidResponse，修复后数据与原始 Range 请求均正确。`lanzouRejectsIncorrectRangeBodyLength`（`:392`）原先将 3/11 字节正文冒充声明的 10 字节，修复后均拒绝。证据 `docs/evidence/v0.2/FIX-11-range-regression.log`。
- 原范围成功测试的替身也错误地只返回 3 字节，现更正为实际 10 字节。`lanzouRejectsInconsistentContentRanges`（`:414`）覆盖八种边界错误；`lanzouChecksDeclaredDownloadLength`（`:419`）检查完整下载不足及范围长度头冲突。
- 完整提交门禁通过：应用逻辑 9 项、包测试 319 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-11-range-gates.log`。
- FIX-11 尚未整体通过：列表/属性仍需取得精确大小，响应类型和 HTML 验证页识别仍待处理；本组不能证明完整下载不会误存验证页。本轮只使用假传输。


## FIX-11：下载响应类型与 HTML 验证页识别（部分）

- `Packages/LanzouDrive/Sources/LanzouDrive/LanzouSession.swift:216` 解析 Content-Disposition 的实际类型，不把文件名中含 attachment 当作附件。没有明确附件声明的 text/html、application/xhtml+xml 下载响应直接返回已有的 antiBotChallenge 错误，不交付页面正文。
- `LanzouDownloadBody.swift:35` 在完整下载或从零开始的范围中，对首段最多 512 字节检查 HTML 开头，处理 UTF-8 BOM、空白和标签跨分块；已识别的页面在交付任何正文前拒绝。非零偏移范围不按文件开头解释，明确声明为附件的 HTML 文件保持可下载。此为有界类型/内容检查，不声称识别任意伪装内容。
- `lanzouRejectsVerificationPagesBeforeYieldingBytes`（`LanzouDriveTests.swift:448`）覆盖 HTML、XHTML、缺少类型、二进制类型和带 attachment 字样的 inline 响应 × 1/7 字节分块。修复前十组都被交付为正常文件；修复后均报 antiBotChallenge 且调用方收到 0 字节。
- `lanzouKeepsAttachmentHTMLAndBinaryContent`（`:475`）确认 HTML 附件及 2048 字节二进制文件逐字节不变；`lanzouDoesNotSniffHTMLInsideNonzeroRange`（`:501`）确认文件中间的 HTML 样式片段不会被误认成页面。证据 `docs/evidence/v0.2/FIX-11-html-regression.log`。
- 完整提交门禁通过：应用逻辑 9 项、包测试 322 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-11-html-gates.log`。
- FIX-11 尚未整体通过：列表/属性的精确大小仍需修复。本轮没有访问真实分享链接或账号，也不将替身识别结果写成真实风控页面验收通过。


## FIX-11：精确大小元数据与本地验收结论

- `Packages/LanzouDrive/Sources/LanzouDrive/LanzouValue.swift:68` 只把明确的整数字节值作为精确大小；KB/MB 显示文字、小数、布尔值、非法值和溢出值不再转换或填 0。`LanzouEntry.size` 使用可选值表示尚未确认，分享页面完全停止从正文猜测大小，避免文件名数字被误读。
- `LanzouProvider.swift:162` 在生成公开文件信息前，为没有精确大小的文件解析下载地址并查询长度。`LanzouSession.swift:265` 优先 HEAD；缺少长度或明确不支持 HEAD 时发 bytes=0-0 范围查询，取 Content-Range 总量。忽略范围但返回完整 Content-Length 的响应可提供大小；bytes */0 可确认空文件。不能取得精确值则报错，不返回假 0 或估算值。
- 元数据和下载共用请求头与类型检查（`LanzouSession.swift:222`、`:247`），不把账号 Cookie 发给下载站点；HTML 验证响应或压缩传输长度不能当成原文件字节数。范围回退只读取响应头，不遍历正文；已核对 Core 的 HTTPByteCursor 在释放时取消底层任务。
- `lanzouResolvesRoundedMetadataFromDownloadResponse`（`LanzouDriveTests.swift:529`）先复现页面约 1 MB 却被解析成文件名中的 2026 字节；修复后 HEAD 与范围回退两组均返回 1,100,003 字节，随后 stat 复用缓存、不重复请求。`lanzouAccountRoundedSizeUsesMetadataWithoutLeakingLoginCookie`（`:577`）覆盖账号文件及 Cookie 隔离。
- `lanzouSizeParserAcceptsOnlyExactByteCounts`（`:566`）验证合法字节值与估算/溢出/布尔值的区别；`lanzouMetadataRequiresAnAuthoritativeLength`（`:607`）覆盖空文件、未知总量、HTML、非法长度、忽略范围、压缩响应和缺失长度七组。原分页夹具改为明确字节值，估算大小由独立用例覆盖。证据 `docs/evidence/v0.2/FIX-11-size-regression.log`。
- 代价：无精确大小的文件需要额外元数据请求，当前按列表顺序执行；缓存后的单文件属性读取复用结果。没有用减少请求为理由继续报告估算值，也没有静默跳过失败条目。
- FIX-11 指定的三类本地行为现已验证：精确大小、按实际响应读取范围、验证页拒绝。真实分享/账号、下载站点 HEAD 与范围支持仍待用户验收。本轮未访问真实账号或分享链接。
- 完整提交门禁通过：应用逻辑 9 项、包测试 326 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-11-size-gates.log`。


## FIX-12：先保存删除后的配置，再清理凭据和缓存

- `Packages/Core/Sources/Core/ConnectionManager.swift:194` 先原子保存删除后的列表，成功后立即同步内存列表和状态，再执行凭据与缓存清理。配置保存失败时不会调用任何凭据删除，也不会删除缓存。已挂载卷仍先尝试推出，推出失败保留位置；推出成功但保存失败时状态如实为断开。
- `removalSaveFailurePreservesCredentialsAndCache`（`ConnectionTests.swift:587`）覆盖 SMB、阿里、夸克、UC、百度、115、123、OneDrive、Google、Dropbox、PikPak、天翼十二类位置。通过临时目录中的配置路径冲突制造保存失败，检查删除调用为零、密码/授权记录与缓存字节保留，恢复配置路径后原位置仍在。修复前凭据和缓存已丢失，修复后全部通过。
- `removalCleanupFailureKeepsPublishedConfigurationConsistent`（`:625`）验证新顺序下的后续凭据清理失败：错误仍抛出，磁盘和内存均保持已经保存的位置删除状态，未清理的凭据仍在；底层恢复后，用原位置再次调用后端删除接口可完成清理。已有推出失败、正常删除与待保存授权清理测试继续通过。证据 `docs/evidence/v0.2/FIX-12-regression.log`。
- 已检查面板调用方：错误仍展示，不会吞掉清理失败。后续弹窗与错误文案验收仍需区分“配置保存失败”和“配置已移除但清理失败”；目前沿用通用删除失败标题，未新增界面重试入口，本提交不冒充该界面问题已解决。
- 完整提交门禁通过：应用逻辑 9 项、包测试 328 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-12-gates.log`。全部测试使用临时配置、内存凭据和假挂载服务。


## FIX-13：编辑已挂载地址先推出旧卷

- `Packages/Core/Sources/Core/ConnectionManager.swift:100` 在新地址验证通过后，按已保存的旧配置找到旧卷；系统挂载地址改变时先推出，再写入新凭据和配置。推出成功立即记录断开状态，后续刷新不会将主动推出误报为意外断开。推出失败时保存中止，旧配置、旧凭据和旧卷不变。
- `editingMountedAddressEjectsBeforeSaving`（`ConnectionTests.swift:669`）覆盖 SMB、WebDAV、HTTPS WebDAV、NFS × 推出成功/失败八组。推出回调直接检查磁盘仍是旧地址、凭据仍是旧值；完成后检查实际假卷表及通知。修复前旧卷遗留、未调用推出、旧地址被覆盖且出现错误通知，修复后均通过。
- 假挂载服务现按创建挂载时的地址匹配，避免仅凭位置 ID 把旧卷误当成新地址的卷。`editingOnlyMountedNameKeepsVolume`（`:709`）确认名称、颜色变化不触发推出；`mountedEditSaveFailureRestoresCredentialsWithoutFalseDisconnectNotice`（`:723`）确认推出后配置保存失败仍保留旧配置并恢复旧凭据，状态为实际断开且无错误通知。
- 完整提交门禁通过：应用逻辑 9 项、包测试 331 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-13-regression.log`、`docs/evidence/v0.2/FIX-13-gates.log`。只使用假挂载和临时目录，真实系统卷操作仍待用户验收。


## FIX-14：超时或取消后的迟到挂载清理

- `Packages/Core/Sources/Core/SMB.swift:237` 在请求已经失败结束后，处理迟到的成功回调，逐个推出其返回的全部卷；正常交付的卷不受后续失败影响。`:294` 在首次失败结束时记录放弃状态，保留原超时或取消错误，不重复恢复 continuation。
- `MountRequestTests.swift:7` 的 `lateSuccessfulMountIsEjectedAfterAbandonment` 覆盖超时与取消两组：修复前清理记录为空，修复后两个返回路径均被推出。`:25` 的 `deliveredMountIsNotEjectedByLaterFailure` 确认正常交付不受影响；`:37` 的 `lateMountCleanupFailureDoesNotSkipOtherMounts` 确认一个卷被系统拒绝推出后仍继续处理其他卷，且记录具体失败。
- 生产清理复用已有系统推出操作；失败写入隐私保护的系统日志（`:223`），不强制推出占用卷。系统拒绝推出时不能保证无残留，真实卷的超时、取消和占用行为留待用户验收。
- 已核对本机 SDK 的 `NetFS.framework/Headers/NetFS.h:323` 附近回调与取消说明：取消尚未完成的请求后不再提交回调；本修复针对成功已经发生、回调处理迟到的情形，不假设每次取消都产生回调。
- 测试只注入内存清理记录，不调用 NetFS 或访问真实卷。回归证据 `docs/evidence/v0.2/FIX-14-regression.log`；完整提交门禁通过：应用逻辑 9 项、包测试 334 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-14-gates.log`。工具链恢复后重编现有 BoringSSL 产生整数转换警告，未作为本项改动处理。


## FIX-15：挂载地址编码与规范化

- `Packages/Core/Sources/Core/SMB.swift:96` 修复大写协议前缀被重复补前缀的问题；`:135` 明确将路径转换为 NFC 后比较。主机名继续忽略大小写，路径保留大小写；原 NFS 的 host:/path 形式不是 URL，保留其中字面百分号。
- 审查第 1B 节关于“没做解码、大小写统一”的表述过宽：原 `URLComponents.path`/`URL.path` 已做一次标准 URL 解码，主机名已有 lowercased，Swift 字符串相等本身也接受 Unicode 等价写法。没有增加手动二次解码，避免将名为 Photos%20 的共享错认成 Photos 加空格。
- `Packages/Core/Tests/CoreTests/MountAddressTests.swift:7` 的 `mountTableMatchesEncodedChineseShare` 先复现大写协议与编码中文名称匹配失败；`mountTableMatchesWebDAVAndRawNFS` 同样复现 HTTPS 前缀问题，并检查原始 NFS 路径、错误主机、错误文件系统。`mountTableMatchesCanonicalUnicode` 与 `mountTableDecodesExactlyOnceAndPreservesPathCase` 覆盖组合字符和百分号、路径大小写不混淆。
- 追加 `mountTableMatchesUppercaseSavedScheme`，复现并修正保存地址本身使用大写协议名时的反向匹配失败；两边协议名均忽略大小写。完整提交门禁通过：应用逻辑 9 项、包测试 339 项，发布构建与签名校验通过。证据 `docs/evidence/v0.2/FIX-15-regression.log`、`docs/evidence/v0.2/FIX-15-gates.log`；真实系统挂载表格式另待用户验收。


## FIX-16：S3 查询编码与官方签名示例（部分）

- `Packages/S3Drive/Sources/S3Drive/S3Provider.swift:490` 只计算一次规范查询串，同时用于签名和实际 URL 的 percentEncodedQuery（`:511`）；不再让 URLComponents 另行编码并保留加号、斜杠和问号。无查询参数时仍没有问号，空参数值保留等号。
- `paginationUsesCanonicalEncodedQueryOnTheWire`（`S3ProviderTests.swift:421`）在路径寻址和虚拟主机寻址两组中，返回含加号、斜杠、等号、中文、空格、百分号和问号的分页 token；断言实际请求的完整编码查询串和解码后 token。修复前实际 URL 中的 +、/、? 未编码，两组共四项断言失败；修复后通过。
- `sigV4MatchesAllOfficialSingleChunkExamples`（`:444`）逐个比较 AWS 官方单块载荷页面的全部四个示例：范围 GET、带正文和存储级别的 PUT、空值 lifecycle 查询、List Objects 查询。固定公开示例日期和凭据，比较完整 Authorization 值、实际编码路径与查询串，不只检查签名头存在。四组均通过，没有发出网络请求。
- 参考 [AWS 官方单块载荷签名示例](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html)，对应 Examples: Signature Calculations 下四节；示例值直接来自文档，不由被测代码生成预期值。签名运算仍调用 CryptoKit 的 SHA256 与 HMAC，没有新增密码学实现或依赖。方法只开放模块内测试访问并允许指定日期，生产默认当前时间，公共 API 未增加测试参数。
- 更正审查第 2 节 B2 对上一轮报告的质疑：原测试只验证 Authorization 中有 Credential，本轮才加入实际官方签名值比对。此处“全部”限定为 Kayoi 所用单块载荷签名页四个示例，不冒称分块签名或预签名 URL 已验收。
- 核心回归证据 `docs/evidence/v0.2/FIX-16-query-regression.log`；完整提交门禁通过：应用逻辑 9 项、包测试 341 项，发布构建与签名校验通过；证据 `docs/evidence/v0.2/FIX-16-query-gates.log`。FIX-16 尚未整体通过：不支持条件写入的服务仍需增加 HEAD 同名检查。


## FIX-16：S3 写入前检查同名对象

- `Packages/S3Drive/Sources/S3Drive/S3Provider.swift:403` 每次普通 PUT（包括空文件、目录标记与冲突重试）前先 HEAD 精确对象键；`:341` 在发起分片前检查，`:380` 在分片完成前再次检查。已有对象报 EEXIST，HEAD 的权限或服务错误原样失败，不把“检查不了”当作不存在。全部写入仍保留原条件头，没有无条件覆盖回退。
- 无法可靠识别一个服务是否静默忽略 If-None-Match，因此所有服务都执行检查，不维护猜测性的服务白名单。代价为普通写入至少多一次 HEAD、分片至少多两次 HEAD；缺少对象读取权限时也不能绕过检查写入。
- `s3RejectsExistingObjectWhenServiceIgnoresConditions`（`WriteSafetyTests.swift:66`）覆盖普通文件、空文件、分片和目录标记四组。替身实际忽略条件头并修改内存对象，修复前原内容被替换且未报错；修复后每组只发一次 HEAD，原内容不变。`s3PreflightFailureNeverWrites`（`:86`）验证 403/500 均不发写请求。
- `s3MultipartChecksAgainBeforePublishing`（`:97`）在上传分片期间模拟其他写入者创建目标，修复前完成请求覆盖其内容，修复后保留它并中止分片；`s3MissingObjectIsWrittenWithConditions`（`:112`）确认四类正常创建的内容、顺序与最终条件头。`conditionalPutRetryChecksForNewObject`（`S3ProviderTests.swift:499`）确认 409 后重试先重新 HEAD，新对象已出现则不再 PUT。旧分片边界及重试测试补齐 HEAD 响应，分片大小和重试语义不变。
- 已检查同类路径：move 在复制前已有 pathExists 检查目标对象及后代，继续保留；分片 PUT 仅写未发布分片，不用目标对象 HEAD 阻挡每个分片。无真实设备、账号或存储请求，回归证据 `docs/evidence/v0.2/FIX-16-safety-regression.log`。
- 限制：对于忽略条件头的服务，HEAD 与随后写入之间仍有外部并发窗口；本实现满足写前检查，不声称跨进程/服务端原子拒绝覆盖。实际服务的条件请求支持、分片中止结果另待用户验收。
- 完整提交门禁通过：应用逻辑 9 项、包测试 346 项，发布构建与签名校验通过；证据 `docs/evidence/v0.2/FIX-16-safety-gates.log`。FIX-16 三部分本地验收通过，真实服务与并发边界按上述限制另待用户验收。


## FIX-17：共享请求额度与 S3 接入（部分）

- `Packages/Core/Sources/Core/HTTPConcurrencyLimit.swift:22` 将同一额度组限制为最多四个请求，排队取消会移除等待者，获得额度后发现取消则归还。`:12` 的账号注册表使用弱引用，不把已经无人使用的额度对象永久保留；不同账号互不共用。
- `LimitedHTTPTransport`（`:57`）对完整请求在返回或错误时归还额度；流式响应通过 `LimitedHTTPCursor`（`:95`）持有到读完、读取错误或响应被丢弃，不在收到响应头时提早放行第五个下载，也不创建脱离消费速度的无限缓存任务。
- `Packages/S3Drive/Sources/S3Drive/S3Provider.swift:127` 将全部请求接入同一包装层，账号范围为规范化主机、有效端口和访问标识，不按桶拆分；密钥不进入注册键，不输出账号标识。多个 provider 即使持有不同底层 transport，也共享该账号额度。
- `s3AccountLimitsRequestsAcrossProviders`（`ConcurrencyTests.swift:21`）发起十六个并行容量请求，分别覆盖单 provider、同账号两个桶、等价端点写法三组。原实现前两组超过四个；初版共享键也在主机大小写/显式 443/尾斜杠组失败，修正后全部通过，并检查未退化成串行、十六次请求全部完成。
- Core 回归：`sharedHTTPAllowanceHasAccountIdentityAndReleasesUnusedEntries`（`HTTPConcurrencyTests.swift:30`）验证身份与回收；`cancelledHTTPWaiterDoesNotConsumeAllowance`（`:40`）验证取消后继续使用；`httpAllowanceSurvivesResponseAndStreamErrors`（`:60`）验证连续八次完整请求/流读取失败不漏额度；`httpStreamHoldsAllowanceUntilFinishedOrDiscarded`（`:78`）确认四个未消费流会阻挡第五个请求，读完或丢弃其中一个后第五个继续。
- 所有传输均为内存替身，无真实账号或网络请求。证据 `docs/evidence/v0.2/FIX-17-s3-regression.log`；完整提交门禁通过：应用逻辑 9 项、包测试 351 项，发布构建及签名校验通过，证据 `docs/evidence/v0.2/FIX-17-s3-gates.log`。
- FIX-17 尚未整体通过：CloudDrive 的授权及直传路径还未接入；AppModel 每次创建会话的问题仍需修复。本组共享的是请求额度，不把它冒称为应用层已经复用会话；跨进程刷新锁与本进程请求额度是不同约束。


## FIX-17：CloudDrive 授权与直接传输共用额度（部分）

- `Packages/CloudDrive/Sources/CloudDrive/OAuthSession.swift:117` 按凭据存储命名空间及凭据键取得共享额度，与刷新锁使用同一账号记录边界；不同会话引用同一凭据记录时共用，测试的独立内存存储不会互相干扰。令牌交换、刷新、普通授权请求、授权下载均经受限 transport。
- `OAuthSession.limited`（`:123`）让百度（`BaiduDriveProvider.swift:32`）、115（`Drive115Provider.swift:23`）、123（`Drive123Provider.swift:22`）和 OneDrive（`OneDriveProvider.swift:20`）的直接请求也共用相同额度，包括上传分块、直链下载和失败清理。Google、Dropbox 的网络请求原本全部经 OAuthSession，未另加一层重复占用。
- `cloudProvidersShareAccountRequestAllowance`（`ConcurrencyTests.swift:38`）对六种 provider 各创建两个独立会话并发调用十六次资料查询，替身严格匹配主机和路径；修复前六组峰值均为 16，修复后均不超过 4，全部返回正确资料且不退化为串行。`oneDriveDirectUploadsShareOAuthAccountAllowance`（`:184`）额外对十二个 provider 强制走上传会话直传，未包装入口时峰值 12，修复后不超过 4；正文正确且不向上传地址添加 OAuth Authorization。
- `rejectedStreamReleasesAllowanceBeforeRefresh`（`:125`）验证三个未消费下载加一个 401：接入额度但保留旧控制流时，401 流占满最后额度，刷新调用为零；`:207` 将拒绝响应的生命周期限定在刷新之前后，其他下载尚未释放时即可刷新并完成重试。没有把“限流通过”当作刷新路径已安全。
- 原 `tenDelayedUnauthorizedRequestsShareOneRefresh` 夹具等十个请求同时到达才返回第一个 401，与四并发上限互相等待。已改为每满四个返回一个迟到拒绝，保留余下拒绝直到新令牌请求；更名 `tenConcurrentRequestsShareOneRefreshWithDelayedRejections`（`OAuthSessionTests.swift:402`）。仍覆盖普通/流式 × 单/多会话，十个操作全部成功且只刷新一次，实际旧令牌请求数允许 4 至 10，避免要求队列中的请求也必须用旧令牌。首次完整包运行因此手动中止，没有计为通过；修正后完整包通过。
- 回归证据 `docs/evidence/v0.2/FIX-17-cloud-regression.log`；完整提交门禁通过：应用逻辑 9 项、包测试 354 项，发布构建和签名校验通过；证据 `docs/evidence/v0.2/FIX-17-cloud-gates.log`。全部测试为内存凭据、临时文件与假传输，没有访问真实网盘。
- FIX-17 仍未整体通过：本组补齐 CloudDrive 请求额度；AppModel 的会话实例复用，以及阿里等既有单会话限制的复用问题仍待处理。
