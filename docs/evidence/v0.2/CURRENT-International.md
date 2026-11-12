# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 国际网盘审计修复交付

## 已修改

- Google重名、斜杠、点名称和保留前缀：`GoogleDriveProvider.swift:52` 全量取完分页后决定显示路径。普通唯一名称保留原路径；特殊名称以 `~diskit~` + Base64URL文件ID作为虚拟路径段，`RemoteItem.name`仍是原名，不过滤文件。所有条目另保留ID访问别名，因此原重名项变为唯一项后旧身份路径仍有效。冷路径在`:320`重新列父目录取得身份映射，不按任意ID直接越过父目录；`:100`的stat保留调用路径。删除按准确ID，跨目录移动ID路径时保留原始名称。
- Google缓存：列表记录变更代次，写入/建目录/删除/移动及断开清理路径缓存，旧列表返回不回填已经失效的缓存；列表刷新同时清理该父目录的旧子路径。
- Google查询加号：`:396` 通过URLComponents建查询后仅将裸加号改成%2B，查询往返值不变。
- Google改名：`:220` 同父目录时不发送addParents/removeParents，跨目录才修改父ID。
- Google308续传：`:248` 根据服务端Range确认位置继续，不再假设完整分块已收到；无Range重发未确认字节，倒退/超过发送范围的确认报错，无确认进展60秒超时。大文件改用FileHandle按8MiB读取，不再建立全文件Data；现有上传true分类保留。
- OneDrive移动：`OneDriveProvider.swift:233` 跨目录查询真实父目录ID，根目录也取实际ID，发送parentReference.id；同目录只改name。
- OneDrive内存：`:132` 直接上传上限8MiB（不突破调用方更小阈值），超过后走已有分片会话，每块读取不超过配置chunkSize；小文件使用mappedIfSafe。代价是8–250MiB文件多创建一次上传会话。
- OneDrive412：`:308`映射EEXIST，公共CloudDriveSupport.mapHTTP也单独映射412，409维持原细分策略。
- Google/OneDrive/Dropbox容量：接入Core可选SpaceInfo，缺total/usage/allocated保持nil，不造0或负可用量。
- Dropbox已存在的display_name、根目录空串、精确not_found、ASCII参数头及现有对应回归已核对，不重复重写。

## 测试与验证

新增 `Packages/CloudDrive/Tests/CloudDriveTests/InternationalDriveAuditTests.swift`。

一次定向快检退出0，11个测试函数通过，日志 `docs/evidence/v0.2/CURRENT-international-audit-focused.log`：
- googleListingPreservesEveryUnusualNameWithStableIdentity
- googleIdentityPathCannotEscapeItsListedParent
- googleSameFolderRenameOmitsParentMutationAndEncodesPlus
- googleResumableUploadUsesAcknowledgedBytes（有Range/无Range两组）
- oneDriveMoveUsesParentIDAndRenameAvoidsParentChange（子目录/根目录/同目录三组）
- oneDrivePreconditionFailureIsNameConflict
- internationalDriveMissingQuotaIsUnknownInsteadOfZero
- oneDriveBoundsDirectUploadMemoryEvenBelowServiceLimit
- 原有googleDriveResumableUploadSplitsAtEightMegabytes、googleDriveSmallUploadUsesMultipartEndpoint、oneDriveUploadSessionSplitsAtThreeHundredTwentyKiB。

原Google分片夹具308没有Range却期待整块已收到，与官方语义冲突，现补正确Range，原分块大小断言保留；新增无Range场景明确验证从0重发。

快检之后补充两个测试（尚未执行，留最终统一验证）：googleMovingIdentityPathKeepsOriginalRemoteName、googleIdentityPathRemainsUsableWhenDuplicateDisappears。后者对应补充的“每个条目保留稳定ID访问别名”代码；不能把前次11项通过记成最终版本全部通过。限定文件diff check通过。未全包测试、未构建发布、未提交。

## 官方依据

- https://developers.google.com/workspace/drive/api/guides/manage-uploads ：308要按Range确认范围，无Range表示尚无确认字节；200/201表示完成。
- https://developers.google.com/workspace/drive/api/reference/rest/v3/about ：storageQuota.limit在无限存储时省略。
- https://learn.microsoft.com/en-us/graph/api/driveitem-move?view=graph-rest-1.0 ：parentReference使用实际id，移到根目录也不能用字符串root替代实际ID。

## 整合与待验收

- `RemoteItem.path` 是可操作身份，name是展示名称。DevTool ls目前只打印name，请整合时对路径末段与name不同的条目额外输出实际path，保证用户能发现别名。root已收到提醒。
- 真实Google重复名/斜杠名、跨目录移动及分片断网恢复；OneDrive根目录移动和上传会话；三家未知/无限配额的真实返回仍待账号验收。本轮没有访问账号或真实接口。
- 此子任务未实现所有网络中断自动续传；已修的是明确分片308确认语义，通用安全重试由其他任务负责。未虚称全部网络恢复行为通过。
