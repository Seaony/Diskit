# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# S3 审计剩余项实现交接

完成时间：2026-11-04。未提交，未改共享报告，未访问真实账号/服务/Secrets，未运行全仓库测试或构建。

## 当前实现

- 审计1C中“范围读取到文件末尾报错”：S3Provider.swift:201、758，接受服务端将范围截到EOF；416且Content-Range明确起点已到EOF则空流。仍拒绝错起点、错终点、无效范围。测试 AuditRegressionTests.swift:34 `s3RangeAcceptsServerClippingAtEOF`、239 `s3ReadReturnsOnlyRemainingBytesAtEOF`。
- 审计1C中“超过5GB复制失败”：S3Provider.swift:326、359，大于5GiB走UploadPartCopy，最多10000片、每片5GiB，不下载文件；逐片ETag条件校验源，保留内容类型、用户metadata、标签；完成成功后才条件删除源。先完整复制所有对象，再开始删源。失败AbortMultipartUpload，清理失败保留双错误。测试:67 `s3LargeMoveUsesMultipartCopyBeforeDeletingSource`、193 `s3FailedMultipartCopyNeverDeletesSource`，含HTTP200正文Error失败和abort失败，确认不会删源。
- 审计1C中“S3 503不退避”：S3RetryTransport.swift，GET/HEAD/PUT/DELETE的429/503最多3次重试，退避1/2/4秒，支持数值Retry-After最多30秒；发送、上传、读流全覆盖；释放并发额度后等待；睡眠可注入，测试不实际等待。POST不重试，避免重复创建multipart或对完成结果不明的请求盲目重放。网络错误不自动重试。测试:142、151、175、184。
- 审计1C中“目录stat扫整树”：S3Provider.swift:183、607，HEAD不存在后ListObjectsV2 max-keys=1，拿到存在证据即止；pathExists同用此路径。测试:54 `s3DirectoryStatStopsAfterFirstMatchingObject`，服务端IsTruncated=true也只发两请求，不翻页。
- 审计1C低“XML Key首尾空白裁剪”：S3XML.swift:59、65、66，Key/Prefix/ContinuationToken不trim；数字和日期仍trim。测试:41 `s3ListPreservesSignificantXMLWhitespace`。分片值解析同时修复兄弟元素内容拼进ETag及错误XML仍读UploadId问题，测试:228和大对象复制的LastModified在ETag前夹具。
- 审计1C低“递归删除中断删一半”：S3Provider.swift:587、S3PartialDeletionError.swift:5。不能让S3递归操作变成事务；第一次失败即停止，公开已确认删除keys、失败但远端状态未知key、未尝试keys与原始错误；用户文字给确认删除数量/总数，要求刷新核对。不伪装成功，不尝试危险回滚。测试:121 `s3RecursiveDeleteReportsAlreadyDeletedCount`，1/3完成、后续不再请求。
- 与posix_errors协调：S3Provider.swift:155容量请求仍HEAD验证权限，返回nil/nil未知，不显示假0/0。
- 与upload_paths协调：保留multipartAttempt的transport.upload、putConditionally upload参数和makeDirectory send选择；保留其原测试uploadRequests统计。

## 失败与通过证据

初始六项测试在修复前全部失败，9个断言问题：`docs/evidence/v0.2/CURRENT-s3-audit-red.log`（前一次未保护请求索引的试跑被修正后已重跑，不作为最终红测记录）。

最初六项修复后全绿：`docs/evidence/v0.2/CURRENT-s3-audit-green.log`。

最终定向命令：

```
swift test --package-path Packages/S3Drive --filter 's3|range|stat|recursive|xmlAnd|list|truncated|multipart|conditional|pagination|sigV4|signed'
```

`docs/evidence/v0.2/CURRENT-s3-audit-regression.log`：退出0，31个测试通过（参数化子例包括3种读流重试、3种EOF、2种abort结果、原4组SigV4等）；无error或warning。测试运行0.140秒（不含编译）。`git diff --check -- Packages/S3Drive` 退出0。只格式化S3范围文件。

## 官方依据

- https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html — 单次复制5GB上限、超过时分片；200响应也可能带错误。
- https://docs.aws.amazon.com/AmazonS3/latest/API/API_UploadPartCopy.html — copy-source-range、copy-source-if-match、分片响应ETag。
- https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html — max-keys控制返回数量。
- https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html — 503 exponential backoff。
- https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html — Range和Content-Range。
- https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObjectTagging.html — multipart时显式保留标签，需GetObjectTagging权限。
- https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html — If-Match支持、无版本桶永久删除、有版本桶删除标记语义。

## 需用户账号验收/边界

- 各S3兼容服务实际支持UploadPartCopy、条件完成、条件删除、Tagging的差异；没有标签读取权限或标签接口不支持时明确失败保留源，不静默丢标签。
- 真实>5GiB跨服务复制速度和中断恢复；测试仅请求序列与协议夹具，未传真实数据。
- S3递归删除不原子，已确认删除无法回滚；版本桶可按服务端版本恢复，非版本桶不可恢复，界面应沿既有永久删除说明。
- HEAD->完成条件头在忽略If-None-Match的兼容服务仍有外部并发写窗口；支持If-Match的服务可阻止删除已改变源，但不能冒称所有兼容服务都实现条件删除。
- 新增2个L键需后续COPY/I18N统一收录（已消息给root）：删除未完成：已确认删除 %lld / %lld 个对象，失败对象的状态尚未确认。请刷新后检查剩余内容。／复制未完成，清理也失败了。原文件仍保留，请检查目标位置和未完成的分片上传。

喵
