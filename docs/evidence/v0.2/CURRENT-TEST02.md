# 集中验收前交接（不表示运行通过）

实现已交中央集成，编译/测试/截图/性能尚未通过；下列已有局部或静态证据只适用于交接注明的时点。

# TEST-02 静态交接

本轮所有修改已落盘，未提交。遵守集中验证安排，未启动编译或测试；不能据本报告标为运行验收通过。

## 共用支持

- Packages/Core/Sources/Core/DeadlineClock.swift:3：内部时间源，生产默认ContinuousClock真实计时。
- Packages/Core/Sources/CoreTestSupport/ManualTestClock.swift:4：手动推进时间、可取消sleep、sleep注册事件；只作为测试目标依赖。
- Packages/Core/Sources/CoreTestSupport/TestEvent.swift:4：可取消的事件闸门，无定时轮询。
- HTTPProgressDeadline保留public init(interval:)/recordProgress/run；内部clock注入。HTTPConcurrencyLimit内部clock/observeQueue，CredentialRefreshLock内部clock。

## 覆盖范围

- Core HTTPDeadlineTests:48 metadataDeadlineEndsEvenWhileResponseMakesProgress：本地URLProtocol收到明确chunk事件后推进30秒，验证元数据总截止及URLSession取消。
- :83 uploadProgressExtendsIdleDeadlineButLateProgressDoesNotReviveIt：60秒空闲续期和过期不可复活。
- :109 cancelledProgressDeadlineReleasesClockAndOperationWaiters：取消释放假时钟和操作等待者。
- :127 accountQueueDeadlineDoesNotLoseOrStealAllowance：4个额度满后第5个超时，不偷额度。
- Core HTTPConcurrencyTests：队列事件替代20ms/1ms轮询，完整流读完/丢弃后等待第5请求直接完成。
- Core CredentialRefreshLockTests:79/:118：超时、期限内释放、已过期、取消都用假时钟；保留真实本地子进程非阻塞flock排他性验证。
- Core RecoverableSecretStoreTests：锁等待超时用假时钟，验证pending凭据及owner锁仍在。
- ADB DeadlineTests:8/:47：普通操作不续期，传输有字节续期，迟到字节不复活；分片24字节每次推进100ms，明确验证预算减少2.3秒。
- CameraUSB/RicohGR DeadlineTests:8：共享15秒截止，第一阶段推进8秒，第二阶段推进7秒；过期阶段不启动native调用。CameraCall后续抽取归baidu_audit，须保留内部时间注入。
- Core SMBProcessTests:56：C with_io入口注入now/poll/write，实际Password提示和1字节PTY写入后模拟EAGAIN推进截止，验证ETIMEDOUT和不回显；删除sleep5和真实elapsed断言。生产入口仍真实monotonic/poll/write。
- AliyunDrive/CloudDrive/S3Drive：并发、共享刷新、重试、慢轮询、跨进程协调事件化；有效凭据固定日期，Aliyun now内部注入精确过期断言。
- PikPak/Tianyi/ChinaWebDrive/Lanzou：轮询截止假时钟、并发刷新和迟到响应事件化。PikPak内部now统一token/验证码/下载有效期，生产公开构造器仍Date。
- Quark WebCookiesTests：固定Date并传现有now参数。
- AppOperations/ConnectionRecovery：取消清理和多连接任务进入事件替代长sleep/轮询。
- CacheMaintenanceTests：固定文件新旧时间、日志时间及GMT，内部appendError时区可注入，生产默认.current。

## 静态证据

2026-11-04 最终命令 `git diff --check` 无输出、退出0。
扫描 `rg -n 'Task\.sleep|Thread\.sleep|usleep\(|Date\(\)|ContinuousClock\.now|TimeZone\.current|Calendar\.current|timeIntervalSinceNow' Packages/*/Tests Tests/KayoiTests` 零匹配。
扫描是补充证据，不代替逐文件审查或最终运行。

## 明确边界

- Aliyun separateSessions共享刷新和Cloud跨进程刷新测试已由目录/进入事件决定先后；成功路径仍可能经过CredentialRefreshLock生产10ms非阻塞flock重试。断言不依赖10ms长度；root已明确判定这是被测生产锁IO调度，保留机制，不为测试更换生产锁。夹具没有任意延时、没有以真实耗时作断言，因此不依赖业务时钟的真实等待。
- 正常PTY、Process退出、本地文件事件仍是本地系统I/O集成，不用固定sleep猜测结果。
- ManualTestClock只在初始化取ContinuousClock锚点，所有后续时间由advance推进，无墙钟流逝依赖。
- 最终编译、测试、覆盖率和发布构建由root统一运行；本子任务没有声称通过。
