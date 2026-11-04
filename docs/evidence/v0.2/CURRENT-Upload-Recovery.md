# 六平台上传恢复交接（非最终全量）

最后一次20函数定向通过，不能替代当前全部代码的统一回归；百度/123任务ID失效的未知协议明确保留。

# CloudDrive 上传会话恢复核对

范围：`docs/AUDIT-2026-11-04.md:200`（PLAN §6.5 上传链接过期重取与续传）；CloudDrive 的六个 Provider：Google、OneDrive、Dropbox、百度、115、123。该补充属于 OPTIMIZATION §5.1 的剩余审计条目；不是持久化跨应用重启的传输队列。

## Dropbox

- 原缺陷：start后append/finish返回409 not_found直接失败；incorrect_offset不处理；append响应丢失后直接失败。
- 修复：`Packages/CloudDrive/Sources/CloudDrive/DropboxProvider.swift:204` sessionUpload只读本地分块；过期最多重建一次，从0重传，新会话仍使用mode=add、autorename=false、strict_conflict=true。append/finish依官方结构解析not_found/lookup_failed；correct_offset校验数值、范围及本次最多发送位置，seek后续传；网络丢响应/超时重发同游标，由服务端incorrect_offset确认实际位置，恢复合计最多3次；closed不重建，保留已提交远端文件。
- 失败基线：`docs/evidence/v0.2/CURRENT-Dropbox-upload-before-excerpt.log`，原实现6函数/8问题，包含原有正常分片用例通过及新增恢复路径失败。
- 修后局部：`/tmp/kayoi-upload-recovery-tests.log`，16函数通过（与Google/OneDrive共用定向过滤，不是全量）。
- 测试：`DropboxUploadRecoveryTests.swift:56` append/finish过期重建且提交不覆盖；`:79` 两阶段按服务端offset读对应字节；`:96` 丢响应同游标再发并按确认位置续传；`:114` 负数/越界offset拒绝；`:128` 重复过期只重建一次；`:141` 重复incorrect_offset次数有界；`:154` closed不新建文件。
- 官方协议证据：[Upload Session Start](https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/upload-session-start)（会话有效期7天，过期not_found）；[UploadSessionAppendError](https://opensource.dropbox.com/SwiftyDropbox/api-docs/latest/Classes/Files/UploadSessionAppendError.html)（correct_offset用于恢复丢失响应）；[官方API规格](https://github.com/dropbox/dropbox-api-spec/blob/main/files.stone)。
- 需真实账号验收：服务器实际过期/关闭时返回结构、上传后内容与原文件哈希一致、账户权限/配额、最终冲突行为。替身能证明客户端发出的游标、分块内容、请求次数、严格新增参数及错误分支，无法证明服务端在真实账户上的存储效果。不得把服务端会话删除后的数据恢复称为旧分片续传；该分支按文档重开上传。

以下为其余五类的完整补充证据。

## Google Drive

- `GoogleDriveProvider.swift:257` 的resumableWrite：网络丢响应或5xx先发空PUT、Content-Range bytes */size查询已提交位置，依据308 Range继续；404重建前再查同名冲突，已完成文件保留；恢复最多3次，连续零进展最多3次，非末片200/201视为协议错误。恢复时进度不倒退。
- `UploadSessionRecoveryTests.swift:69` 4场景：会话过期、丢响应状态查询、服务器失败后查询、最终响应丢失后的完成状态；`:93` 6场景：反复过期、已有同名文件、取消、无进展、非法范围、提前成功。既有Google308完整/缺Range测试一并通过。
- 官方：[Manage uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads)。有效会话可按服务端offset续传；失效404只能重建从0上传，不宣称保留已失效分片。

## OneDrive

- `OneDriveProvider.swift:162` sessionWrite：416/5xx或网络中断先GET uploadURL，解析nextExpectedRanges再seek续传；404至多重建2次，先查目标同名，createUploadSession仍conflictBehavior=fail。状态/无进展恢复最多3次；5xx生产指数等待，测试注入即时sleep。短读/越界/非末片完成均报错；失败清理当前session；进度不倒退。
- `OneDriveUploadSessionRecoveryTests.swift:86` 4种恢复场景；`:104` 4种失败/边界场景，含停滞有界且不覆盖。原320KiB分片、内存限制、账号并发限额用例一并通过。
- 官方：[Create upload session](https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0)。uploadURL请求不附带OAuth头。

## 115

- `Drive115Provider.swift:311` sendUploadRequest：仅HTTP403且OSS XML Code为SecurityTokenExpired时重新取STS、重签并重试当前步骤一次；InvalidSecurityToken/AccessDenied不误判过期。单PUT(:326)、multipart初始化/part/complete(:342)共用此路径，保留uploadID、已完成片和片号。
- `UploadExpiryRecoveryTests.swift:39` 四阶段过期重签；`:86` 重签仍过期有界、权限错误不重试。修前6问题日志 `docs/evidence/v0.2/CURRENT-Upload-expiry-before-excerpt.log`；修后4函数11参数场景通过 `/tmp/kayoi-upload-expiry-green.log`。
- 官方：[OSS HTTP403说明](https://help.aliyun.com/en/oss/user-guide/http-403-error-code)。真实STS签名接受、账户下回调、完成后的文件内容仍须账号验收。

## 百度与123

- 已存在固定上传端点的access_token刷新，本次无必要生产改动。新增`UploadExpiryRecoveryTests.swift:114` drive123ExpiredAccessTokenRetriesSameSliceWithoutRestarting；`:147` baiduExpiredAccessTokenRetriesSamePartWithoutRestarting。各验证HTTP401和业务鉴权失败：刷新后保留原preuploadID/uploadID、片号和正文，不重建任务、不重传成功片。
- **需账号/官方资料验证，未宣称已覆盖**：uploadID/preuploadID本身失效时是否允许恢复、确切错误码、服务端是否保留片。百度官方 https://pan.baidu.com/union/doc/3ksg0s9r7 与123官方知识库 https://123yunpan.yuque.com/org-wiki-123yunpan-muaork/cr6ced 本次工具不可读取，不能猜错误码/重建规则；盲目重create会有重复文件风险。替身仅能验证已知协议下的客户端行为，不能证明真实服务保留分片或恢复任务能力。

## 最后局部验收

- `docs/evidence/v0.2/CURRENT-Upload-Recovery-tests-excerpt.log`：包含全部上述最后改动的定向运行，20个测试函数全部通过，exit0；未跑全量构建/回归，未提交。
- `git diff --check`：无输出，exit0。
- 中间复核发现Dropbox重试请求JSON字典字段顺序不稳定，测试已改为比较解码对象语义，保留同游标/正文验证，最后20函数运行通过。
- 真实Google/OneDrive/Dropbox会话生命周期、真实115STS续期、百度/123任务ID过期，以及上传结束远端文件哈希/冲突行为全部写入用户账号验收。没有连接任何真实服务或账号。
