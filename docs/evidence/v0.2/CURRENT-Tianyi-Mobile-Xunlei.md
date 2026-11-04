# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 审计 1E 后端处理结果（待统一验收）

本任务仅负责天翼、移动、迅雷，不含 DevTool 和网页登录 UI。没有真实账号、设备或数据 API 调用，没有提交。

## 已保留的既有修复

- 天翼 httpss、加号编码和分页截断：此前 FIX-04 已有回归，当前 TianyiProvider/Session 仍使用 URLComponents/明确翻页，不重复修改。
- 迅雷与移动删除：此前 FIX-10 官网静态请求链已确认回收站；本次保留 /trash 与 recyclebin/batchTrash。
- 天翼暂时刷新错误保留登录：此前 FIX-06/07 跨会话刷新锁与错误分类保留；本次又补并发恢复用例但未重复执行。
- 迅雷/移动网络错误 POSIX：posix_errors 子任务已加 POSIXHTTPTransport、NetworkFailure；本次保留并把 SDK 内层网络错误展开映射。

## 新修复

### 天翼
- TianyiSession.swift:192：先验证新登录的账号容量再持久化。初始网页请求带 Cookie；302 优先解析 Location，可信域限制保留。
- TianyiError.swift:14：验证码/风控明确 verificationRequired，只有 loginRequired 需要重新登录，429/5xx不删凭据。
- TianyiProvider.swift:220：跨目录改名临时唯一名→移动→目标名，避免源目录已存在最终名和目标目录已存在原名两个冲突。失败尝试恢复，恢复失败附最后确认路径及两个错误；不保证断网后的远端实际位置。
- TianyiProvider.swift:336：缓存代次防旧结果回填；同ID矛盾/重复条目及非法元数据明确报错，不静默遗漏。
- TianyiModels.swift:26：缺失/负数文件大小明确失败。
- TianyiProvider.swift:431：process/successedCount实际增加才续60秒；相同轮询状态不续期，完成有失败项不能返回成功，状态2冲突映射EEXIST。
- TianyiMoveRecoveryFailure：传播原始/回滚 LoginRequiredFailure 语义；网络权限不是登录失效。

### 移动
- MobileCloudSession.swift:227：同会话并发401共享一次refresh任务；迟到旧凭据直接复用最新值，callback有30秒截止。服务器429/5xx即使正文带9008也不误刷新。非法响应不再误进refresh分支。
- MobileCloudSession.swift:352、Support.swift:90：仅真实登录拒绝触发重登；验证码/风控先识别，返回verificationRequired/EAGAIN。只有 MobileCloudError.loginRequired 的 requiresLogin=true。
- MobileCloudProvider.swift:253/356：create返回exist=true或复用已经看见的ID时直接报EEXIST，绝不进入清理分支，上传/建目录均覆盖。
- MobileCloudProvider.swift:376：跨目录改名临时唯一名流程；失败重新列目录确认ID位置后恢复。不能恢复时返回 MobileCloudMoveFailure.lastConfirmedPath，不谎称已知实际位置。
- MobileCloudProvider.swift:507：代次及同目录请求ID双检查，迟到目录不能覆盖更新或断开；重复相同ID数据去重、同ID矛盾数据失败；坏条目不部分发布缓存。读文件改为持有同一个解析后的node生成元数据，避免重入后二次缓存取出另一个ID。
- 写入、建目录、删除、移动失败均清相关缓存。
- Support.swift:123：14位 yyyyMMddHHmmss 先按严格北京时间日历解析，不能再当毫秒时间戳；10/13位时间戳继续保留。

### 迅雷
- XunleiSession.swift:139：刷新任务合并+迟到旧凭据复用，30秒截止；验证码/风控、403权限、5xx不误触发登录失效。
- XunleiSession.swift:160：检查命名错误字段，文件名中的unauthorized/token expired不会让登录失效；空白error成功处理。
- XunleiProvider.swift:394：目录代次、重复ID、失败后缓存失效；不静默跳过坏条目。
- XunleiProvider.swift:498：完成轮询按可观察状态推进续期60秒，重复RUNNING不续期。
- XunleiPartFile.swift:4：自身只用128KiB缓冲复制一个临时分片，SDK以.file上传；保留CRC/重试能力，结束失败均清理。代价最多一个分片的临时磁盘占用；不宣称SDK内部内存严格只有128KiB。
- XunleiUpload.swift:170：展开ClientError.innerError，保留超时/取消；本地磁盘错误映射ENOSPC/ENOENT/EACCES。
- 上传进度expected已改完整文件size；迅雷移动接口一次提交父目录和新名称，不存在天翼/移动的中间原名冲突流程。

## 不改变与待用户验收

- 坏条目使目录明确失败而非跳过：RemoteItem目前没有“不可访问/无法解析”的部分结果语义，静默跳过违反用户不丢数据约束；保留明确失败并避免半成品缓存。
- 移动容量单位：没有凭猜测乘1024。只读取官网公开静态 app.56b4a805.js（URL https://yun.139.com/w/static/js/app.56b4a805.js，SHA256 400dacc3a6a6040428f54cb3b23914f3c715cf94223e47e3d2cf0655e370131f，字节偏移99389），接口适配直接传递diskSize/freeDiskSize，无单位转换，但这不足以证明最终单位。真实账号需逐个对比官网总量/可用量和Kayoi显示字节，确认后再改，不调用数据API。
- 天翼真实Cookie/SSO域链、验证码风控、断网后移动和回滚实际位置仍需真实账号验收。
- 迅雷SDK实际上传、断线取消、服务端分片清理仍需真实账号验收。

## 验证

- 合并China新增定向快检：docs/evidence/v0.2/CURRENT-china-remaining-focused.log，23测试函数通过，测试用时0.147秒。涵盖MobileCloudAuditTests当时全部新增及XunleiRemainingTests当时新增。
- 天翼新增定向快检：docs/evidence/v0.2/CURRENT-tianyi-remaining-tests.log，11测试函数通过，测试用时0.278秒。过滤 tianyiLoginValidates|tianyiLoginSends|tianyiVerification|tianyiTaskProgress|tianyiRepeatedTask|tianyiCompletedTask|tianyiRepeatedFile|tianyiDelayedList|tianyiCrossDirectory|malformedTianyi。
- 快检之后仅补：天翼10并发恢复/状态2参数、Mobile刷新callback30秒包装与移动错误协议传播、迅雷SDK内层错误及磁盘错误断言。未重复跑，留最终统一验收。
- git diff --check通过；未跑全包或全量门禁。
