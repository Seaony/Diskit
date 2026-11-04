# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 百度网盘审计修复交接

未提交、未全量构建/测试、未连接真实账号/API、未读 Secrets。保留 upload_paths 的 upload:true 透传；公共查询编码由 root 统一修改 CloudDriveSupport.url。

## 已修改

- BaiduDriveProvider.swift:78/111/288：stat 不再调用未文档化的 method=meta。完整列父目录并精确匹配路径，零条 ENOENT、重复 EEXIST；每次读取最新列表，移除从未读出但持续回填的 downloadLinks，避免旧身份缓存。下载按匹配 fs_id 调用 /rest/2.0/xpan/multimedia?method=filemetas&fsids=[id]&dlink=1，并核对返回 fs_id、path。父目录列表返回越界/非直接子项、缺失 list/errno 成功字段时明确拒绝，不能作为“目标不存在”放行写入。
- BaiduDriveProvider.swift:151/173：上传使用百度网盘组织 SDK 的 precreate → https://d.pcs.baidu.com/rest/2.0/pcs/superfile2 → create，不再调用非该流程要求的 locateupload；method/access_token 均在 URL query，文件正文保留 multipart，移除非文档化 Bearer 认证替代。预创建 return_type=2 完成秒传；空 block_list 不再强制上传第0片；服务要求的片号必须唯一且在范围内；完整读取每个片段，服务器 MD5 必须与本地 CryptoKit 计算一致才继续合并；create 传完整按序 MD5。所有正常上传仍明确走 upload 路径。
- BaiduDriveProvider.swift:310：普通 POST 的 method/opera/access_token 放 query，业务字段放 form body，与官方 SDK 一致。read 的 dlink 经 HTTPS/无URL用户密码校验后，使用同一公共查询编码方法追加 token，字面 + 保持为 %2B。
- BaiduDriveProvider.swift:443：31034 → rateLimited/EAGAIN；官方 SDK 定义 31190 为空间不足，纠正旧 ENOENT → ENOSPC，防止错误地继续创建。BaiduStatus 同时读取 errno/error_code；filemanager 逐项 info.errno 非零会报错，不能只看顶层 errno=0。
- BaiduDriveProvider.swift:429/522：根配置为 / 时路径不拼双斜杠，返回条目仍限制在配置根内。

## 官方证据

百度 union 文档页通过工具读取失败，未调用任何业务接口。使用百度网盘组织公开 SDK 的接口定义与实现核对，没有引入 SDK 依赖或复制其实现：

- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/scene/file_manager.go （fileExists 列父目录匹配）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/download_meta.go （filemetas/fsids/dlink）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/upload_precreate.go （query method、body业务参数、return_type、block_list语义）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/upload_slice.go （d.pcs.baidu.com、superfile2及分片参数）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/upload_create.go （合并时MD5列表）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/client.go （PCS默认主机、query/body分离及error_code格式）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/errors.go （31034频率超限、31190空间不足）
- https://github.com/baidu-netdisk/baidu-drive-sdk-go/blob/main/baidudriver/api/file_manager.go （每文件 info.errno）

## 测试与验证边界

新增 BaiduAuditTests.swift：
- :75 baiduStatUsesParentListAndDoesNotReuseStaleIdentity：严格URL和+编码、连续stat重新匹配身份。
- :103 baiduDownloadsUseFileIDAndRejectMismatchedMetadata：正确fsids请求/内容与错误身份拒绝。
- :140 baiduUploadUsesOfficialWireContractAndValidatesParts：正常片、空片清单、秒传、非法序号、错误MD5；精确主机、query/body、无Bearer、禁止locateupload。
- :192 baiduRateLimitAndDuplicatePathNeverTriggerMutation：31034/-8/31190均不发变更请求。
- :211 baiduMalformedListingCannotAuthorizeCreatingAnExistingPath：畸形列表不能当空目录。

OfficialDriveProvidersTests.swift 只调整百度相关段：read新增父目录查询；上传删locate夹具、使用实际MD5；删除操作assert移至query；刷新用例改名 baiduUploadRetryPreservesMultipartBodyAndUpdatesQueryToken，检查仅token变化、multipart正文与其他query不变。保留所有 uploadRequests 计数；115/123段由另一代理负责。

一次定向快检：`swift test --package-path Packages/CloudDrive --filter baidu`，exit 0，10个函数通过，日志 docs/evidence/v0.2/CURRENT-baidu-audit-focused.log。运行后追加了畸形列表、31190/PCS error_code 与逐项 filemanager 检查，未重复执行，留最终统一验收。当前相关文件 git diff --check 通过。

## root 后续整合

- AppModel.oauthIsConfigured 仍强制 BAIDU_APP_ID 非空；新官方上传流程不需要此值，应移除这条无效门槛。公共 BaiduDriveConfiguration.appID 字段暂保留源码兼容，内部已无使用。
- 真实账号：目录分页、download dlink 权益、秒传/空文件、服务端 rtype=0 冲突行为及各VIP分片大小兼容性需用户验收。不能把替身验证写成服务端已通过；写前存在性检查不提供与外部写入者之间的原子保证。
- 代价：stat/read现在需要列父目录（含分页）以可靠查fs_id；无缓存的行为避免旧路径误指，但大目录查询成本更高。
- 全局“多个上传共用一个进度回调”的协议级审计项未在此单包任务改接口，需要 root 统一决定与覆盖；本组未扩展 RemoteFileProvider 协议。
