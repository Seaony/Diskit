# 集中验收前交接（不表示运行通过）

实现已交中央集成，编译/测试/截图/性能尚未通过；下列已有局部或静态证据只适用于交接注明的时点。

# PERF05 块流交接

## 实现证据
- `Packages/Core/Sources/Core/HTTPTransport.swift:95` 使用原session创建delegate流，已删除HTTPByteCursor/AsyncBytes逐字节await；send/upload/redirect策略保留。
- `Packages/Core/Sources/Core/HTTPDataStreamDelegate.swift:3` URLSessionDataDelegate直接接收Data，task-specific delegate转发响应/数据/完成/重定向；delegate弱持有流对象。
- `Packages/Core/Sources/Core/HTTPDataStream.swift:5` 常量：64KiB输出块、1MiB暂停、256KiB恢复、4MiB硬上限。小回调合并尾块，避免大量小Data对象撑大队列。
- `HTTPDataStream.swift:105` 超上限显式ENOBUFS，先排完之前接受的字节再抛错，绝不悄悄截断成功。
- `HTTPDataStream.swift:48/80/235/256` 首响应30秒，实际数据60秒空闲期，使用共享DeadlineClock；消费者背压暂停时间排除在网络空闲期外；晚数据不能复活期限。
- `HTTPDataStream.swift:162/194/213/290` 消费取消清缓冲并终止task；正常/异常完成先排完已收数据；body丢弃释放对象并取消task。控制队列在同一锁内顺序入队，避免suspend/resume竞态；计时器weak捕获避免保活。

## 已做检查
- 五个自有文件 `git diff --check` 退出0。
- 未启动编译或测试：遵父代理要求等所有Core接口收齐后集中快检，不抢共享构建目录。
- 新增8个测试函数，`Packages/Core/Tests/CoreTests/HTTPDataStreamTests.swift:52`起：完成/错误保留剩余字节、硬上限、暂停恢复与慢消费者不超时、首响应超时取消底层、真实进展延期/晚数据无效、取消清队列/停止task、丢弃停止task、小回调合并。
- `HTTPTransportTests.swift:53`现以206/429两状态跑真实URLProtocol→dataTask delegate→body链，保留status/headers/error正文，断言字节相同和所有输出块≤64KiB，不固定依赖Foundation回调分块形状。
- 所有新增计时测试用ManualTestClock/TestEvent；URLProtocol严格匹配注册.invalid主机，无真实网络与sleep。
- root建议集中定向过滤 `blockStream|HTTPStreamReadsBoundedChunksAfterHeadersReturn`，并带原 `httpStreamHoldsAllowanceUntilFinishedOrDiscarded` 验证限流外层。

## 性能验收边界
- 应用层常态每流约1MiB队列；允许在途回调余量，上限4MiB（四路16MiB队列载荷），另有最多64KiB消费块/少量队列索引开销。
- 此上限不声称限制Foundation/内核内部缓冲，也不包括进入delegate时系统已分配的当次Data。超过余量明确失败，避免无界内存。
- 未实测吞吐和整应用RSS，不能写PERF05性能达标。root统一验收可用本地fixture大量块持续供给、逐块校验摘要或字节计数，记录wall clock/CPU/峰值RSS，分别单路/四路/慢消费，与原逐字节版本同数据量比较；无需真实账户或外部服务，禁止将整文件收集进Data作为性能测试消费方式。
- Apple依据：本机NSURLSession.h第65–68行块回调、第165行task-specific delegate、第659–662行暂停不超时、第720–726行delegate强持有到完成；官方 https://developer.apple.com/documentation/foundation/urlsessiontask/delegate 与 https://developer.apple.com/documentation/foundation/urlsessiondatadelegate/urlsession(_:datatask:didreceive:) 。
