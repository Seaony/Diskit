# 日期解析热点复用

对应原审计日期 formatter 每项新建问题：天翼、蓝奏、中国网盘的目录项日期解析。

## 修改与语义

- `Packages/TianyiDrive/Sources/TianyiDrive/TianyiModels.swift:151`：ISO 解析器和 6 种固定 DateFormatter 静态创建一次，Mutex 保护调用。`TianyiDate.parse`（`:164`）保留 ISO 优先、格式顺序、GMT+8 和两种空格归一化。
- `Packages/LanzouDrive/Sources/LanzouDrive/LanzouValue.swift:68`：4 种日期格式和 ISO 解析器固定复用。`parseDate`（`:102`）保持绝对时间优先、GMT+8、referenceDate 参数及昨天/前天/秒分小时天之前的原计算。
- `Packages/ChinaWebDrive/Sources/ChinaWebDrive/Support.swift:39`：严格 14 位紧凑格式、带/不带小数 ISO、3 种回退格式分别固定复用。`parseDate`（`:137`）保留 14 位字符串先严格校验再 round-trip、秒/毫秒数值、空值/坏值回 epoch 和 GMT+8。
- 所有实例数量固定；锁内解析器不向外暴露、不在运行中修改配置，不按输入建立缓存。
- `Packages/Core/Sources/Core/RemoteTimestamp.swift:4` 已使用静态不可变 ISO8601FormatStyle。缺时区分支按传入 TimeZone 构造值类型样式，未逐项创建 DateFormatter，保留动态时区语义，不增设时区缓存。
- 全部三包 DateFormatter/ISO8601DateFormatter 用途已核对。`TianyiSession.httpDate`、`ChinaWebSupport.dateTimestamp` 是请求签名输出，不是目录项解析，本次不改其格式、时区或签名行为。

## 前后基准

这属于构造热点性能问题，没有伪造功能失败。修改前从三个真实解析函数截取独立基准，修改后用同样输入、相同编译优化执行。每种解析器 500 轮 × 4 输入，共 2000 次；包含服务本地时间、ISO、纯日期和无效日期，计时不含编译。前后结果校验和相同。

| 解析器 | 修改前 | 修改后 | 比值（前/后） |
| --- | ---: | ---: | ---: |
| Tianyi | 0.876277458 秒 | 0.275689625 秒 | 3.18 |
| Lanzou | 0.802444333 秒 | 0.279269250 秒 | 2.87 |
| China | 1.311941833 秒 | 0.411236750 秒 | 3.19 |

原始输出：`CURRENT-DateParsing-before.log`、`CURRENT-DateParsing-after.log`。源代码快照：`CURRENT-DateParsing-before.swift.txt`、`CURRENT-DateParsing-after.swift.txt`。复核时复制任一快照为临时 `.swift`，执行 `swiftc -O <临时源文件> -o <临时可执行文件>`，再运行；这是本机微基准，不代表真实服务总吞吐或稳定性能承诺。

## 局部验证

三个包分别运行一次定向测试，全部通过：

- Tianyi：`tianyiSharedDateParsersPreserveFormatsUnderConcurrency`，16 个并发任务覆盖 6 种日期格式、ISO、特殊空格和坏值。
- Lanzou：`lanzouSharedDateParsersPreserveAbsoluteAndRelativeDates`、既有 `relativeFileDatesStayStableWithinSession`，2 个通过。
- China：`chinaSharedDateParsersKeepStrictCompactAndTimezoneRules`、既有 `chinaBusinessErrorsAndMalformedFlexibleValuesRemainExplicit`，2 个通过。

具体命令为 `swift test --package-path Packages/<包> --filter '<上述测试名以 | 连接>'`。完整输出分别为 `CURRENT-DateParsing-TianyiDrive.log`、`CURRENT-DateParsing-LanzouDrive.log`、`CURRENT-DateParsing-ChinaWebDrive.log`。未启动全量回归、真实设备或账号。
