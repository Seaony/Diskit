# 上传进度隔离补审

审查依据：`docs/AUDIT-2026-11-04.md:134`（多个上传共用回调）、`:203`（CLI 进度缺失）；`PLAN.md:85` 要求打印进度和平均速度。

## 修复与证据

- `Packages/S3Drive/Tests/S3DriveTests/ProgressIsolationTests.swift:26` 使用两个事件明确阻塞首个上传，再注册第二回调并完成第二上传，最后释放首个上传。没有 sleep、真实网络或账号。
- 修复前首回调 `[]`，第二回调 `[7, 3]`，两个断言失败；修复后分别 `[3]`、`[7]`，单项通过。命令：`swift test --package-path Packages/S3Drive --filter concurrentUploadsKeepTheirInitialProgressCallback`。原始输出：`CURRENT-UploadProgress-before.log`、`CURRENT-UploadProgress-after.log`。
- 14 个可写 Provider 在操作入口、首次 await 前捕获回调：ADB、Aliyun、Quark、PikPak、Tianyi、MobileCloud、Xunlei、Google、OneDrive、Dropbox、Baidu、115、123、S3。例如 `Packages/S3Drive/Sources/S3Drive/S3Provider.swift:233`；S3 分片复制/写入与 115、Dropbox、OneDrive 私有分片函数显式透传同一回调。
- ADB 下载入口捕获后传给独立游标：`Packages/ADB/Sources/ADB/ADBProvider.swift:151`。
- Google 新增小文件完成、服务器确认分片范围及最终完成回调；测试 `googleDriveResumableUploadSplitsAtEightMegabytes`、`googleDriveSmallUploadUsesMultipartEndpoint` 在 `Packages/CloudDrive/Tests/CloudDriveTests/CloudProviderTests.swift:97`、`:124` 增加具体字节断言。
- CLI 绑定 Google：`Packages/DevTool/Sources/DevToolSupport/CLITransfers.swift:34`。全部类型下载在该文件 `:104` 逐块报告；测试 `downloadsReportEachChunkRegardlessOfRangeCapability`（`Packages/DevTool/Tests/DevToolTests/CLITests.swift:320`）覆盖有/无 Range 能力时的 `[1,3,3]`。
- Google 首次定向执行被另一测试文件的嵌套宏编译错误阻挡；该错误已由负责代理修复。Google 与 CLI 新增断言交中央统一验证，不将该次编译失败写为通过。

## 范围与真实验证边界

回调是“操作开始时采用当时注册值”；修改注册值不会改变已经开始的操作。分开的 onProgress 与 write 调用不是跨调用者原子事务，未更改公共 Core 协议。

ADB 明确 `supportsRangeRead=false` 且范围读取抛 unsupported（ADBProvider.swift:6、:152），保持不变。CameraUSB、Ricoh、Lanzou 是只读 Provider，不增加上传能力。规范没有要求持久化上传会话或跨启动断点续传；现有分片/308 游标处理保留。范围读取不能视为跨启动恢复能力。

实际服务是否支持 Range、分片故障后的远端状态、真实吞吐与字节进度，需要真实账号或设备验收；本轮均未连接。未推送、发布或运行 UI 自动化。
