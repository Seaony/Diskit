# Kayoi 0.2 优化验收记录

本报告为进行中的证据账本。未列明通过的项目均未完成，历史 POLISH-REPORT 不作为本轮通过证据。真机、账号及真实菜单栏点击另列入 ACCEPTANCE，不能由替身测试代替。

## 起点

- 分支：master；起点提交 `12c1740` 仅新增 OPTIMIZATION 与 AUDIT 两份文档，`git show --format= --check 12c1740` 通过。
- 构建隔离：默认 `make gen` 使用 `Config/Validation.xcconfig`，没有包含本机密钥配置；真实凭据构建保留显式选择入口，见 README。
- TEST-01（部分）：`memorySecretLifecycle`、`memorySecretsAreIsolatedBetweenRuns` 使用内存存储替代原真实钥匙串测试。其他网络替身及未登记请求拒绝策略仍需逐包核实。

## 阶段进度

1. 基础：进行中；演示模式、应用逻辑测试、覆盖率门禁和资源颜色迁移尚未验收。
2. 不可用类型及数据安全：进行中；FIX-01 至 FIX-05 已修复，FIX-06 刷新和资源失败保护已完成本地回归；FIX-07 进行中，FIX-08 起尚未处理。
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
