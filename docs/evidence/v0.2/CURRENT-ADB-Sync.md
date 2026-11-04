# 审计交接与保留理由

下文旧行号和阶段覆盖率只属当时；最终结果以FINAL证据为准。Camera候选豁免已退回，最终不豁免相机文件。

# ADB 剩余业务审计证据

本批只修改 ADBSync.swift、独立 SyncAuditTests.swift，以及 ProtocolTests.swift 的旧 v1 LIST 假传输夹具。未连接真实设备、网络账号或钥匙串；未提交、未构建、未运行测试（父任务要求共享 Core 稳定后统一运行）。

- ADBSync.swift:260 上传读取真实 contentModificationDate，DONE 写原始秒数；小于 1970 或超 UInt32 时明确 EOVERFLOW，不写成当前时间。测试 adbUploadRetainsOriginalModificationTime。
- ADBSync.swift:350 df 解析 Available 列，保留 total/used 并传 available；SpaceInfo 对显式 available 的支持由 posix_errors 改。测试 adbAvailableSpaceExcludesReservedBlocks。
- ADBSync.swift:66 所有路径属于虚拟内部存储根，/sdcard 与 /storage 不再绕过根映射，同名真实目录可达；外置存储仅 /SD 卡 前缀映射。若内部真实 SD 卡 与虚拟入口同名，根 list 抛 EEXIST，不返回错误指向的条目。测试 adbVirtualPathsCannotEscapeInternalRoot、adbSDCardAliasRejectsRealDirectoryCollision。
- ADBSync.swift:172、208、355 v1 STAT/LIST 非目录通过 shell stat -c %s 补查 64 位大小。拒绝命令失败、负值、溢出与畸形输出；不展示截断值。代价是老协议每个非目录一次 shell 往返。测试 adbLegacyStatRecoversSizeAboveFourGiB（wire 低 32 位，实际 5,000,000,000）及调整 listingV1AndV2DecodeDirectoryEntries v1 夹具。Toybox 官方源码 https://raw.githubusercontent.com/landley/toybox/master/toys/other/stat.c 的 %s 为字节，使用 long long 输出 st_size。老厂商 stat 可用性待真机验证；缺少命令时明确失败。
- ADBSync.swift:243、477 下载按实际读到字节发布进度；测试 adbDownloadReportsActualReceivedBytes，两次 [3,6]。
- ADBSync.swift:390 shell v2 exit 必须恰好 1 字节（父代理已改，本批新增回归）；测试 adbEmptyShellExitFailsImmediately，零长度直接协议错误，不读到超时。另给 shell v2 总 stdout+stderr 限制 1 MiB，避免大量小包绕过单包上限。
- ADBSession.swift 已有公钥发送后 ETIMEDOUT→unauthorized（device_timeouts 实现）；本批测试 adbAuthorizationTimeoutAsksForPhoneApproval，用内存密钥和立即超时假传输，无真实等待。

## 保留且给出理由

- 单通道忙时 EBUSY：未消费完或未释放下载流可能无限持有服务；将其他请求无界排队会隐藏调用错误并无限等待。当前业务没有并发浏览需要，明确忙错误保留，未假称支持并行。
- 非 UTF-8 或远端 stat 失败的目录条目：RemoteItem 没有原始字节路径或逐项错误表示。跳过会丢文件，替换字符会指向另一文件，故整次操作显式失败并保留错误；不伪造空列表。目录中合法条目没有被静默丢弃。
- NFC 不统一远端路径：Android 远端区分原始字节，规范化会把不同真实文件合并或操作错文件，故保留原始 Unicode。
- 64 KiB 同步帧吞吐：当前符合 ADB sync 数据帧上限；20 MB/s 属真实设备/USB/文件系统性能验收，禁止在无真机证据下承诺达标。

## 已执行静态检查

`xcrun swiftc -frontend -parse Packages/ADB/Sources/ADB/ADBSync.swift Packages/ADB/Tests/ADBTests/SyncAuditTests.swift Packages/ADB/Tests/ADBTests/ProtocolTests.swift` exit 0。
`git diff --check -- Packages/ADB/Sources/ADB/ADBSync.swift Packages/ADB/Tests/ADBTests/SyncAuditTests.swift Packages/ADB/Tests/ADBTests/ProtocolTests.swift` exit 0。
以上仅语法/空白检查，不是测试通过证据。八个新增测试待最终统一执行。

## FEAT-08 文件迁移

后续代码组织调整将 ADBProvider 与其私有 ADBReadCursor 从 ADBSync.swift 移至同目录 ADBProvider.swift。ADBSync.swift 保留协议编解码；本报告此前 Provider 行号需按同名方法在 ADBProvider.swift 核对，行为及SyncAuditTests/ProtocolTests断言未更改。
