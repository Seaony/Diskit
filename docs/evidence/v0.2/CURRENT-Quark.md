# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 夸克/UC剩余审计处理

- 缓存旧回包：QuarkProvider.swift 11、359，修改代次+目录请求ID；connect/disconnect/变更让旧结果报EAGAIN，旧列表不能重新填入删除项。ProviderConcurrencyTests两个测试通过。
- 哈希阻塞：QuarkProvider.swift 134，Task.detached运行原有分块CryptoKit摘要，父任务取消传递至摘要任务，返回后检查取消和连接；原摘要向量用例保留。未做性能压测。
- format_type：QuarkProvider.swift 118使用远端目标名称扩展；quarkUploadUsesDestinationExtensionForFormat通过。
- 已有目录：QuarkProvider.swift 226报EEXIST，不静默成功；quarkExistingDirectoryReportsConflict通过。
- 目录空页：原total=0空页本来正常，审计表述过宽。新逻辑仅对非零total不一致空页从第一页重读一次，仍不一致报错，不静默漏行；两组回归通过。
- 异步删除/移动：QuarkMutation读data.task_id，QuarkProvider.swift 312按/task等待status2；0/1继续、3/4失败，整轮30秒截止。立即完成/失败和移动后改名顺序测试通过；另补pending0/1→2轮询用例但尚未执行。
- 跨目录改名：目标已有原名但最终名空闲时，临时名称→移动→最终名，按fid仅操作源对象；失败尝试回原目录/原名，恢复也失败时QuarkMoveRecoveryError保留两种错误及临时名。成功、移动失败恢复、最终改名失败先移回、双失败四测试通过。另补最终名已有时不发变更用例未执行。
- 范围下载链接：QuarkProvider.swift 419按fid、大小、更新时间复用URL，401/403清后重取，变更/断开清理；重复范围读只取一次URL回归通过。仍每次取元数据以避免陈旧大小。
- Cookie：QuarkSession.swift 243/255/293，鉴权拒绝提示登录但不删除已保存Cookie；5xx/429不被登录样式正文或Set-Cookie带偏；成功后重置单次通知标志。新恢复/服务错误回归通过，旧四个删除凭据预期已改保留。
- 登录语义：QuarkError.requiresLogin仅loginRequired为true；invalidCookie/invalidResponse不是会话已失效。新增断言通过。

验证：一次定向14测试通过，日志 docs/evidence/v0.2/CURRENT-quark-audit-focused.log；之后仅新增pending轮询和最终名冲突两个测试，留最终统一验证，没全量构建测试、没提交、没真实账号。

依据：官方未登录页面仅返回登录静态资源，未取得已登录业务JS，不能称官方协议验证。参考开源客户端实际实现：https://raw.githubusercontent.com/Cp0204/quark-auto-save/main/quark_auto_save.py 第585–615行（task_id/retry_index/status2），https://raw.githubusercontent.com/alist-org/alist/main/drivers/quark_uc/driver.go 第230–249行（移动与改名分离）。没有调用业务API。UC任务/临时改名/恢复服务端行为和Cookie续期仍需真实账号验收。

新增本地化键：移动失败，恢复原位置也未完成。请刷新目录，检查临时文件“%@”。需主任务统一加入中英catalog。
