# 验收记录

日期：2026-11-03。环境：macOS 26.5.2（25F84）、Xcode 26.6（17F113）、Swift 6.3.3、XcodeGen 2.46.0。
只记录实际运行的结果；界面与外部设备不由单元测试替代。

## M0 工程骨架

| 标准 | 结果 | 证据 |
| --- | --- | --- |
| 新克隆执行 make gen / make test / make release | 通过 | 新克隆 `/tmp/kayoi-m0-clone.Ki0yAJ` 执行 `make gen && make test && make release`，退出码 0；测试 2/2 通过，Release `BUILD SUCCEEDED`，签名校验通过 |
| Release 签名与 Info.plist | 通过 | `codesign --verify --deep --strict --verbose=2`：`valid on disk`、`satisfies its Designated Requirement`；PlistBuddy：LSMinimumSystemVersion=`26.0`、LSUIElement=`true` |
| kayoi-dev --help 全部子命令 | 通过 | devices、pair、ls、stat、get、put、mkdir、rm、mv、df、cat --range 均列出；M0 执行具体命令返回未实现与非零退出码 |
| StorageLocation / SecretStore 写读删覆盖 | 通过 | `make test`：`Test run with 2 tests in 0 suites passed`；配置使用临时目录，密钥使用真实登录钥匙串随机 service 并清理 |

签名身份为指定的 Apple Development 证书。App 为 arm64 + x86_64，开发工具为本机架构。未启用沙盒、App Group、共享钥匙串、FSKit 或 Developer ID。

## M1 菜单栏与 SMB

实现与自动检查通过；下列真实系统交互需用户验收，未冒充真机通过。

| 标准 | 结果 | 已有证据与待测内容 |
| --- | --- | --- |
| 1. 只有菜单栏图标，面板符合 §5 | 待用户验证 | Release 编译与签名通过；LSUIElement=true；实现 380pt、52pt 行和最大 560pt 面板。未启动或操作界面验收 |
| 2. 空状态、增删改、拖动排序、重启保持 | 待用户验证 | 假实现测试覆盖保存、编辑、排序和重新加载；实际拖动与窗口行为待测 |
| 3. 列共享、挂载、Finder 文件操作、推出 | 待用户验证 | SMB URL、共享列表解析测试通过；接入 smbutil / NetFSMountURLAsync / NSWorkspace。没有 Windows 账号，未进行网络或文件操作 |
| 4. Bonjour SMB 自动发现 | 待用户验证 | NWBrowser 浏览 `_smb._tcp`、NetService 解析地址，代码构建通过；未验证局域网广播 |
| 5. 错误密码明确提示且不能保存 | 待用户验证 | 假实现 authentication 拒绝保存测试通过；实际测试用所填密码新建 NetFS 会话并临时挂载。错误密码、系统已有认证、已有挂载三种真机情形待测 |
| 6. 删除后钥匙串对应条目消失 | 待用户验证 | 假实现验证先推出再删密钥/缓存/配置；真实登录钥匙串读写覆盖删除测试通过。App 连接删除后的 security 命令检查待测 |
| 7. 开机自启开关 | 待用户验证 | 接入 SMAppService.mainApp；未修改本机登录项，未注销重登 |
| 8. SMB 开启自动挂载后重启生效 | 待用户验证 | 假实现验证仅自动挂载开启项、跳过已经挂载的共享；真实重启待测 |

实际命令结果（2026-11-03）：

```text
$ make test
Test testingExistingConnectionDoesNotUnmountIt() passed after 0.008 seconds.
Test loginKeychainLifecycle() passed after 0.035 seconds.
Test run with 13 tests in 0 suites passed after 0.035 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

两次命令退出码均为 0。Xcode 仅报告未链接 AppIntents 的元数据提取提示，没有编译错误。未写 UI 自动化或快照测试。

用户批准的 §6.3 修订：

- 移除列共享命令的 `-A`，因为它只认证而不枚举共享。
- 保存前用 NetFS 和填写的密码进行独立连接测试，在数据目录 ConnectionTests 下的随机路径短暂挂载并推出；不改变已有挂载。
- `smbutil view -f` 通过独立终端输入密码，`-f` 避免直接复用现有会话，但其输出只用于列共享，不充当表单密码验证。

依据：[Apple view.c](https://github.com/apple-oss-distributions/smb/blob/main/smbutil/view.c)、[Apple server.c](https://github.com/apple-oss-distributions/smb/blob/main/lib/smbclient/server.c)、本机 NetFS.h。没有复制 Apple 源代码。

## M2 安卓 USB

实现与自动检查通过；没有连接安卓手机，不提供真机成功或速度结论。

| 标准 | 结果 | 证据 |
| --- | --- | --- |
| 1. 插拔发现与 devices | 待用户验证 | IOKit 匹配通知、描述属性读取及 CLI 已接入；本机 `build/bin/kayoi-dev devices` 退出码 0、输出 0 行，发现 0 台设备 |
| 2. 首次授权与再次连接 | 待用户验证 | 假传输验证 CNXN → AUTH 签名 → 公钥 → CNXN；真实手机授权框及重连待测 |
| 3. 列目录、递归上传、mkdir/mv/rm | 待用户验证 | v1/v2 目录、sync 上传下载、shell 单引号转义和失败退出码测试通过；CLI 已实现递归目录操作，未操作手机 |
| 4. 大于 4 GB 文件双向 SHA-256 | 待用户验证 | v2 解析 5,000,000,000 字节大小通过；v1 用 5 GB 稀疏测试文件验证拒绝上传；没有实际大文件传输或双端哈希结果 |
| 5. USB 3 下载 1 GB ≥20 MB/s | 待用户验证 | 无手机、线缆或实测数据，不估算速度；CLI 输出传输字节和平均 MB/s |
| 6. 拔线报错、面板断开、重新连接 | 待用户验证 | 假传输中断返回错误并关闭会话；Core 测试确认拔线状态不会被迟到的测试结果覆盖；真机拔线和重插待测 |
| 7. adb server 占用提示 | 待用户验证 | IOUSBHost exclusive-access/busy 错误映射到要求的提示；未启动 adb server、未制造真实接口占用 |
| 8. 消息/校验/公钥/sync/shell 单元测试 | 通过 | ADB 12 项测试通过。固定 OKAY 24 字节样例按 AOSP 线上格式手工列出（不是抓包）；官方 adb 公钥格式逐字节比对；Security 签名验签；分块读写与 shell 退出码均有假实现测试 |

命令输出：

```text
$ make test
Test run with 14 tests in 0 suites passed
Test run with 12 tests in 0 suites passed
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ build/bin/kayoi-dev devices
# stdout 为空，退出码 0；wc -l 为 0
```

共 26 项测试。官方对照工具是本机已有的 `/Users/seaony/Library/Android/sdk/platform-tools/adb`，版本 `37.0.1-15733141`；只用 `version` 和离线 `keygen`，没有启动服务或连接设备。

批准的依赖范围调整：BoringSSL 除 SPAKE2 外，也可用于 Android 公钥编码的 n0inv/rr 大整数运算。Security 仍负责 RSA 密钥生成及签名。来源、版本和许可证见 `THIRD_PARTY_NOTICES.md`。

协议说明：AOSP 历史文档的 data_crc32 字段实际使用字节累加和；0x01000001 起允许跳过，magic 仍校验。按实际 AOSP 实现处理，未使用 CRC32 算法。ADB Provider 不声明按范围读取能力；CLI 的 cat --range 顺序读取并截取输出，没有实现可选 dd 优化。

## M3 安卓 Wi-Fi

实现和自动检查通过；无安卓真机，以下均待用户验证。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 无线调试自动发现 | 待用户验证 | 原标准要求手机名，当前只能显示服务名；用户已批准修订为首次显示 ADB 服务名，保存后使用自定义名称。实际局域网发现仍待真机验证。 |
| 2. 配对码配对、手机显示本机 | 待用户验证 | SPAKE2、TLS exporter、HKDF、AES-GCM 和 PeerInfo 假实现互通通过；本机身份由 Security 创建，证书签名由系统信任检查验证通过；未与手机 TLS 互通 |
| 3. Wi-Fi 文件操作及 >4 GB 哈希 | 待用户验证 | 复用 M2 同一 Provider/sync/shell；Network.framework TCP + STLS 动态插入 TLS 1.3 编译通过，无实际传输数据 |
| 4. 端口变化后无需重新配对 | 待用户验证 | 测试用相同 GUID 的新端口替换旧服务，选择新端点；每次建立连接重新 NWBrowser 查当前服务，不保存端口 |
| 5. 同机 USB 优先 | 待用户验证 | 单测精确匹配关联 serial，排除其他 USB 手机；实际选择通过 os.Logger 的 ADBTransport 分类记录，暂无真机日志 |
| 6. 错误配对码提示、可重试 | 待用户验证 | 错误配对码、错误 exporter、密文篡改均拒绝；单测检查“配对码错误”，表单任务结束恢复输入；未操作真实手机界面 |

```text
$ make test
Test run with 15 tests in 0 suites passed
Test run with 26 tests in 0 suites passed
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

合计 41 项测试，命令退出码 0。M3 用两个子代理分别实现配对与发现，主进程负责 TLS/证书/界面/CLI 和整合验证。没有启动本地服务，没有 UI 自动化或快照测试。

SDK 核查：`nw_framer_prepend_application_protocol` 明确支持握手后动态插入 TLS；`SecIdentityCreate` 可直接结合系统生成的私钥和自签证书；无需更换 §6.2 的技术路线。未扩大 BoringSSL 调用范围。

## M4 GR IV USB

实现与自动检查通过；本机无相机，真机未测。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. USB 发现 GR IV | 待用户验证 | ICDeviceBrowser 只发现，不打开会话；接受官方文档中的 RICOH GR 发现名，连接时读取 DeviceInfo 确认 GR IV。CLI devices 退出 0、stdout/stderr 均为空，当前无设备 |
| 2. 两存储/DCIM、JPG/DNG 下载、删除或明确拒绝 | 待用户验证 | 14 项相机测试通过，涵盖真实字段映射、64 位容量、分块/范围读、删除刷新及 EACCES。ICC/GR 的实际 PTP data phase 布局、双存储暴露和删除能力均未实测 |
| 3. put/mkdir/mv 立即只读且不访问相机 | 待用户验证 | Provider 单元测试在连接前后检查 EROFS 且假相机调用次数不变；CLI 在创建 Provider 前直接拒绝这三类命令。真实 CLI 操作待用户用已保存连接验证 |

```text
$ make test
Test run with 16 tests in 0 suites passed after 0.043 seconds.
Test run with 26 tests in 0 suites passed after 0.362 seconds.
Test run with 14 tests in 0 suites passed after 0.008 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ build/bin/kayoi-dev devices
# stdout/stderr 均为空，退出码 0；当前 0 台设备
```

合计 56 项测试。两个子代理分别负责系统适配/Provider 和测试，主进程整合 App、CLI 与验证。

实现依据：本机 ImageCaptureCore SDK 的 contents/ptpObjectHandle/requestReadData/requestDeleteFiles/requestSendPTPCommand。目录沿用 ICC 原始树，仅通过标准 PTP GetStorageIDs/GetStorageInfo/GetObjectInfo 读取缺少的真实元数据；不会用文件总大小伪造容量。GetDeviceInfo 用于连接时确认型号。未知存储类型或无法读取必要字段时明确报错，不猜。

[RICOH 官方 FAQ](https://www.ricoh-imaging.co.jp/english/support/qa/gr-4/) 确认 Mac 使用 Image Capture、设备名为 RICOH GR；其 Windows 段注明不能从电脑删除。Mac 下的实际删除能力未获验证，因此仍按 PLAN.md 在相机拒绝时返回 EACCES，而不承诺一定能删。

## M5 阿里云盘

实现与自动检查通过；client_id/client_secret 尚未申请，没有真实授权或网盘写操作。

| 标准 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 官方授权、回调、昵称和容量 | 待用户验证 | 接入 ASWebAuthenticationSession，校验回调 route/state/code；OAuth/token/account 假实现与回调测试通过。构建产物确认 client_id/client_secret 均未配置，redirect URI 为 kayoi://oauth/aliyun |
| 2. >100分页、Range、>1GB分片及文件操作 | 待用户验证 | 单测覆盖101条分页、206/Content-Range、过期下载/上传链接重取、真实10MiB+17B两片数据、mkdir/move/trash；未上传真实 >1GB 文件或核对网页版 |
| 3. 无效 access_token 自动恢复 | 待用户验证 | 401/AccessTokenInvalid 刷新后仅重试一次，刷新令牌先写入钥匙串；假实现通过，未改真实账号令牌 |
| 4. 撤权后通知与重新登录状态 | 待用户验证 | 官方 PermissionDenied/刷新失败触发失效通知，App 显示重新登录；Core 测试确认错误不会覆盖重登状态。真实检测发生在下一次 App 请求时，未验证系统通知展示 |
| 5. 分页、缓存失效、分片边界单元测试 | 通过 | AliyunDrive 27项测试（OAuth13、文件13、回调1）；覆盖0字节、整片、最后不足一片、完整字节顺序及complete大小校验 |

```text
$ make test
Test run with 19 tests in 0 suites passed after 0.051 seconds.
Test run with 26 tests in 0 suites passed after 0.301 seconds.
Test run with 14 tests in 0 suites passed after 0.007 seconds.
Test run with 27 tests in 0 suites passed after 0.073 seconds.
$ make release
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
$ git check-ignore Config/Secrets.xcconfig
Config/Secrets.xcconfig
```

共 86 项测试。HTTP 的 URLProtocol 测试证明真实 URLSession AsyncBytes 在响应头返回后继续按 64 KiB 输出，不先加载整文件。普通请求与完整下载流共用最多4并发；429优先按官方 x-retry-after 毫秒退避。

配置：App 从本地 xcconfig 构建值授权；授权记录及客户端配置只存 `<UUID>.oauth` 钥匙串项，CLI 可用空配置恢复并刷新。connections.json 仅保存昵称、用户ID和通用连接字段，不存令牌。删除连接同时删对应钥匙串项。

用户已批准并已修订 PLAN.md：同名替换先完成新上传，再回收旧文件；上传失败不回收旧文件；旧文件回收失败或结果未确认时明确报错，不擅自删除新文件或回滚。原目录多份同名则拒绝猜选目标。接口不支持原位覆盖，file_id 会改变；网络中断时不能保证服务端回收未执行。

官方授权要求 style=folder；若返回 folder_id，Provider 将它作为根，绝不越过实际授权目录。跨目录且改名通常使用 move 后 update 两个官方调用；目标目录已有原名时，move 传最终 new_name，避免合法目标名被原名冲突挡住。整体不承诺原子性。来源见 THIRD_PARTY_NOTICES.md。

## M6 夸克

M6 实现与自动验证完成。M3 首次名称差异已获用户批准修订；F18 错误日志缺口已补齐，最终 `make test` 已通过 123 项测试。真机与界面结果仍待用户验证，不宣称全部实测通过。

| 验收 | 结果 | 证据与限制 |
| --- | --- | --- |
| 1. 扫码登录、账号与容量 | 待用户验证 | 非持久化 WKWebView 读取 Cookie，账号与容量验证成功后才保存；手动 Cookie 入口已接入。没有真实扫码结果 |
| 2. 文件操作与 >100MB 上传 | 待用户验证 | 31 项 Quark 测试覆盖分页、Range、分片、哈希、上传完成、同名拒绝及 Cookie 生命周期；未进行真实上传 |
| 3. 删除 Cookie 后通知且不崩溃 | 待用户验证 | 假实现覆盖缺 Cookie、失效通知和 EACCES；系统通知与 UI 尚未实测 |

最终实际执行 `make test`（退出码 0），五包输出分别为 `24 / 26 / 14 / 28 / 31 tests passed`，合计 123 项通过。日志：`/tmp/kayoi-final-test.log`。
`make release` 输出 `** BUILD SUCCEEDED **`，随后签名校验输出 `valid on disk`、`satisfies its Designated Requirement`。日志：`/tmp/kayoi-final-release.log`（退出码 0）；开发工具另经 `codesign --verify --strict --verbose=2 build/bin/kayoi-dev` 校验通过。这些结果只代表自动测试与构建，不代表真实接口通过。

夸克仅参考 OpenList 接口行为，没有复制其代码。用户批准同名上传报错，旧文件不改动。账号接口 uid 字段尚缺真实响应确认；缺失时留空，没有从 Cookie 或昵称伪造 ID，因此 §7 用户 ID 的实际保存仍待核对。

最终核对发现并补齐 F18 日志缺口：连接测试、保存、列共享、推出及前置配对/授权失败接入现有系统日志和七天文本日志。只记录已知错误文案或数字错误码，未知错误不记录原始描述、URL 或 userInfo；回归覆盖错误回调、不额外发送挂载通知及敏感内容过滤。实际系统日志和文件显示仍需用户手验。

SMB 临时挂载点已移出可清理缓存目录，防止清缓存遍历到测试挂载；回归测试修改前失败、修改后通过（`/tmp/kayoi-cache-regression-before.log`、`/tmp/kayoi-cache-regression-after.log`）。此验证仅使用本地临时标记文件，没有真实远端删除操作。

## 待用户验证（按操作顺序）

目前 M1–M6 有待测项目，M0 无待测项。请使用一个专门的测试共享和不重要的文件。

1. **启动和面板（M1-1/2）**：在仓库执行 `open build/DerivedData/Build/Products/Release/Kayoi.app`。确认没有 Dock 图标，菜单栏可打开面板；无连接时显示空状态和添加按钮。分别切换系统浅色/深色；到系统“语言与地区”给 Kayoi 选英文后重启，检查文案与布局。
2. **准备 Windows（M1-3）**：在 Windows 开启文件和打印机共享；新建测试文件夹并共享，给测试账号读写权限，记下 IP、共享名、用户名与密码。微软账户使用邮箱和账户密码，不使用 PIN。
3. **列共享与错误密码（M1-3/5）**：添加 Windows 共享，填入主机、用户名、密码，点“列出共享”。先用错误密码点“测试并保存”，应提示“用户名或密码错误”，列表中不能新增连接；改为正确密码后保存。保存时会临时挂载再推出，此时不得影响已经挂载的共享。随后在系统已有 SMB 认证的情况下再次填写错误密码，确认仍拒绝保存。
4. **Finder 操作（M1-3）**：点击挂载，检查 Finder 的共享位置；拷入测试文件、拷出、新建目录、改名、删除；对照 Windows 目录内容。点击推出，确认 Finder 与面板挂载状态同步消失。
5. **编辑、排序、自动挂载和退出（M1-2/8）**：添加第二条有效连接，编辑名称/颜色，拖动行改变顺序；开启一条连接“打开 App 时自动挂载”，推出它并退出 App，再运行第 1 步命令。确认名称、顺序和开关保持，开启项自动挂载；App 退出不影响已挂载的 SMB 共享。
6. **Bonjour（M1-4）**：在同一局域网另一台 Mac 开启文件共享；用 `dns-sd -B _smb._tcp local.` 确认其正在广播（结束按 Ctrl+C），观察 Kayoi“已发现”，点击添加应预填主机和名称。
7. **删除密钥（M1-6）**：从 `~/Library/Application Support/Kayoi/connections.json` 找到测试连接 UUID，删除该连接。执行 `security find-generic-password -s com.seaony.Kayoi -a '<UUID>.password'`，预期查不到条目；不要使用会输出密码的 `-w` 或 `-g` 参数。
8. **开机自启（M1-7）**：将 Release App 复制到稳定位置（例如 `~/Applications/Kayoi.app`）并从该位置启动；打开设置、开启自动启动，若系统要求则到登录项设置允许。保存其他工作后注销再登录，确认菜单栏出现；关闭开关后重复验证不再启动。
9. **设置附加项（§4.4）**：查看日志目录，检查缓存显示与上限；清空缓存时必须先确认并成功推出已挂载共享。面板关闭时不应继续容量显示轮询。此项为手动检查，未声称通过。

10. **安卓准备与发现（M2-1/2）**：在手机开启开发者选项和 USB 调试，用数据线连接 Mac。先关闭可能占用设备的其它工具；必要时自行执行官方 `adb kill-server`。在 Kayoi“已发现”添加手机，测试并保存，手机弹框时点“允许”。再次测试应不再弹框；CLI 执行 `build/bin/kayoi-dev devices` 应显示同一序列号。拔出后面板应移除发现项。
11. **安卓文件操作（M2-3）**：从 connections.json 找到该连接 UUID，将下面的 `KAYOI_ID` 替换成它。在本地准备只含测试文件的目录（至少含子目录、中文、空格和 emoji 文件名）。执行：

```sh
KAYOI_ID='替换为连接UUID'
build/bin/kayoi-dev ls "$KAYOI_ID" /sdcard/DCIM
build/bin/kayoi-dev mkdir "$KAYOI_ID" /sdcard/KayoiAcceptance
build/bin/kayoi-dev put "$KAYOI_ID" '/本地测试目录' /sdcard/KayoiAcceptance/upload
build/bin/kayoi-dev mv "$KAYOI_ID" /sdcard/KayoiAcceptance/upload /sdcard/KayoiAcceptance/renamed
build/bin/kayoi-dev get "$KAYOI_ID" /sdcard/KayoiAcceptance/renamed '/本地下载目录'
build/bin/kayoi-dev rm -r "$KAYOI_ID" /sdcard/KayoiAcceptance
```

每步等 kayoi-dev 退出后，用官方 adb shell ls 检查手机结果。官方 adb 会启动自己的 server，检查完应执行 adb kill-server 再运行下一条 kayoi-dev，避免同时占用。不要在上述命令中使用重要目录。

12. **大文件哈希和速度（M2-4/5）**：选择一个大于 4 GB 的本地测试文件，记录 `stat -f %z '/本地大文件'` 和 `shasum -a 256 '/本地大文件'`。用 `put` 上传到专门测试目录，再用 `get` 下载到另一个本地文件，比较 SHA-256；退出 kayoi-dev 后用官方 `adb shell sha256sum '/sdcard/测试大文件'` 对照手机哈希。再用 USB 3 线和支持 USB 3 的手机 `get` 一个 1 GB 文件，记录 CLI 最终平均 MB/s、手机型号和线缆信息，目标 ≥20 MB/s。当前没有任何实测数值。
13. **中断和冲突（M2-6/7）**：传输大文件时拔线，确认命令报错退出、App 不崩溃且显示未连接；重插后重新测试。随后由用户启动官方 adb 并保持其占用，尝试 Kayoi 测试连接和 CLI，确认“手机正被其它 adb 程序占用，请先执行 adb kill-server”提示；再执行 adb kill-server 后重试。
14. **ADB 设置（§4.4）**：查看密钥指纹，重启后应保持不变。仅在愿意让全部手机重新授权时点击重新生成密钥并确认；之后手机应重新弹授权框。

15. **无线发现与配对（M3-1/2/6）**：让 Mac 与 Android 11+ 手机处于同一局域网，手机打开“无线调试 → 使用配对码配对设备”。在 Kayoi 添加安卓 Wi-Fi，选择配对服务，先输入错误六位码，确认提示“配对码错误”且能重试；再输入正确码并保存。手机“已配对的设备”应出现本机名称。必要时允许 macOS 的本地网络权限。
16. **无线文件操作（M3-3）**：拔掉 USB，使用 Wi-Fi 连接的 UUID 重复 M2 第 11、12 步，验证目录、中文/空格/emoji、大文件双向 SHA-256。不要沿用 USB 连接 UUID。
17. **端口变化（M3-4）**：关闭再打开手机无线调试，记录手机显示的新连接端口；保持原连接 UUID，在 App 测试连接并用 CLI ls，不能要求重新配对。
18. **USB 优先（M3-5）**：同机 Wi-Fi 可用时重新插上 USB，启动 `log stream --style compact --info --predicate 'subsystem == "com.seaony.Kayoi" AND category == "ADBTransport"'`，然后测试该 Wi-Fi 连接。应出现“连接方式：USB（优先于同机 Wi-Fi）”；拔出 USB 再测应出现“连接方式：Wi-Fi”。结束日志用 Ctrl+C。若 USB 被官方 adb 占用，先自行执行 adb kill-server。
19. **CLI 配对（§3.2）**：可单独执行 `build/bin/kayoi-dev pair '手机IP:配对端口' '六位码'`，成功输出 GUID；该命令只配对，不自动新增保存连接。随后从 App 已发现的连接服务添加，留空配对码，测试并保存。不要混淆手机显示的配对端口和连接端口。

20. **相机发现（M4-1）**：按理光官方 USB 步骤，先关闭相机，用数据线连接 Mac；相机会自动进入回放模式。先确认系统“图像捕捉”能看到 RICOH GR，再退出图像捕捉以避免并行占用。在 Kayoi 的已发现区添加并测试保存；执行 `build/bin/kayoi-dev devices`，记录相机名称和序列号。
21. **两存储、下载与容量（M4-2）**：确保内置存储和 microSD 各有可用于测试的 JPG/DNG。用 GR 连接 UUID 运行 `ls UUID /`、`ls UUID /内置存储/DCIM`、`ls UUID /microSD/DCIM`，再按实际返回路径执行 `stat UUID '/实际照片路径'` 和 `get UUID '/实际照片路径' '/本地下载文件'`。用 `stat -f %z '/本地下载文件'` 比较大小；运行 `df UUID` 记录相机报告的容量。若实际未暴露两个存储或 PTP 元数据返回错误，请保留错误，不能把单存储结果当两存储通过。
22. **删除或拒绝（M4-2）**：只选一张可删除的测试照片，运行 `rm UUID '/测试照片路径'`。成功时检查相机回放中也消失；若相机拒绝，应明确报权限错误而非假成功。不要用重要照片测试。
23. **只读拒绝（M4-3）**：使用 GR UUID 运行 `put UUID '/任意本地测试文件' '/new.JPG'`、`mkdir UUID /new`、`mv UUID '/已有照片路径' '/renamed.JPG'`。三者应立即报“此位置为只读”，不应出现部分上传或相机文件变化。界面仍由用户手动验收。

24. **准备阿里云盘配置（M5-1）**：申请开放平台 client_id/client_secret，登记与 `ALIYUN_REDIRECT_URI` 完全一致的回调地址。填写不入库的 `Config/Secrets.xcconfig`，参考 example 中 `$()` 的 URL 写法；执行 `make test && make release` 后重启 App。不要把凭据提交到 Git 或发到聊天中。
25. **授权和账号（M5-1）**：添加阿里云盘，测试并保存会打开官方授权页，按平台提示选择授权目录。完成后应自动回到 App，显示昵称与容量；若平台要求第三方应用权益，请按平台实际提示核实。
26. **文件与范围读取（M5-2）**：用阿里云盘连接 UUID 对一个超过100项的目录执行 `ls`，核对网页数量；对视频运行 `cat --range 1048576-2097151 UUID '/视频路径' > '/本地片段文件'`，预期片段1MiB。运行 `put` 上传一个 >1GB 测试文件并核对网页版大小，再验证 mkdir、mv、rm，删除项应进回收站。重复上传同名文件，确认新内容可见、旧项进回收站。
27. **令牌刷新（M5-3）**：在“钥匙串访问”中定位 service=com.seaony.Kayoi、account=`<UUID>.oauth` 的测试账号记录，保留 refreshToken 和其他字段，只把 JSON 中 accessToken 改为无效值；用 App 测试或 CLI ls，应自动恢复。不要导出或展示完整凭据记录。
28. **撤销授权（M5-4）**：在阿里云盘网页撤销测试应用授权，然后在 App 点击测试连接。应显示“重新登录”，并在已允许系统通知时收到通知；重新登录应重新走官方授权。没有请求时不承诺即时发现远端撤权。

29. **夸克登录（M6-1）**：添加夸克网盘，确认显示实验性提示，打开扫码页，用手机扫码；保存后核对昵称与容量。再验证手动粘贴 Cookie 入口；不要把 Cookie 发到聊天或提交 Git。检查配置中 userID 与真实账号响应是否一致，缺失时记录为未通过，不能用昵称替代。
30. **夸克文件操作（M6-2）**：用该连接 UUID 执行 `ls UUID /`、`df UUID`；对视频执行 `cat --range 1048576-2097151 UUID '/视频路径' > '/本地片段文件'`，核对 1 MiB。准备不重要且大于 100 MB 的新文件，依次执行 `mkdir UUID /KayoiAcceptance`、`put UUID '/本地文件' /KayoiAcceptance/upload.bin`、`get UUID /KayoiAcceptance/upload.bin '/本地下载文件'`，比较两端 SHA-256。重复 put 同一路径应报同名错误，旧文件内容不变；执行 `mv UUID /KayoiAcceptance/upload.bin /KayoiAcceptance/renamed.bin`、`rm UUID /KayoiAcceptance/renamed.bin`，逐步核对网页版及回收站。
31. **夸克 Cookie 删除（M6-3）**：在钥匙串访问中仅删除测试连接 service=com.seaony.Kayoi、account=`<UUID>.cookie` 的记录，再在 App 点击测试连接；应提示重新登录，在允许通知时收到系统通知，App 不崩溃。重新扫码应恢复。没有发请求时不承诺即时发现失效。

## 未做与风险

- M7、M8 按要求不做；因此只有 SMB 能挂载 Finder，其余类型使用连接测试和开发工具。
- Windows 网络、密码验证、临时挂载与推出尚无实测。假实现只证明应用流程，不证明系统 API 在目标共享上的行为。
- 临时挂载点只用 `rmdir` 删除空目录；推出失败不会递归删除远端内容。若出现错误并留下临时挂载，请保留错误信息后用 Finder 推出对应卷。
- 仅安装了已授权的 XcodeGen，第三方代码仅使用已批准用途的 BoringSSL。未使用 Jev：本阶段是确定性的系统接口与编译检查。
- UI 采用系统字体、控件和 SF Symbols，按 §5 实现；未跑 UI 自动化或快照。未启动本地开发服务。

## M0 命令输出摘录

主目录 `make test`（退出码 0）：

```text
Test configurationLifecycle() passed after 0.001 seconds.
Test loginKeychainLifecycle() passed after 0.044 seconds.
Test run with 2 tests in 0 suites passed after 0.044 seconds.
```

新克隆 `make gen && make test && make release`（退出码 0）：

```text
Created project at /tmp/kayoi-m0-clone.Ki0yAJ/Kayoi.xcodeproj
Test configurationLifecycle() passed after 0.002 seconds.
Test loginKeychainLifecycle() passed after 0.041 seconds.
Test run with 2 tests in 0 suites passed after 0.041 seconds.
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

`PlistBuddy` 读取实际产物：`LSMinimumSystemVersion = 26.0`，`LSUIElement = true`。
`codesign -dv --verbose=2`：`Identifier=com.seaony.Kayoi`，`Format=app bundle with Mach-O universal (x86_64 arm64)`，`Authority=Apple Development: seaony@outlook.com (ZB4G2AWAU9)`。

核对 diff：仅 M0 工程、包空壳、存储与测试、构建说明及验收记录；PLAN.md 原文原样纳入首次提交。未实现 M7/M8、未增加本期之外的产品行为。

## 需求冲突与用户决定

- smbutil 的 `-A` 只做认证而不列共享，已获批准去掉；保存前另用 NetFS 新会话验证所填密码，允许临时挂载后推出，已有挂载不动。
- BoringSSL 用途经批准扩展到 Android 公钥编码 n0inv/rr；密钥生成、签名和 TLS 仍走系统框架。
- 阿里云盘不支持原位覆盖，经批准改为新文件完成后回收旧文件；原目录多份同名报错。
- 夸克同名上传经批准直接报错，不修改旧文件。
- M3 未配对发现拿到的是 ADB 服务名，已获批准首次显示服务名、保存后用自定义名称，并修订 PLAN.md。此前将这个明确差异仅标为待用户验证不准确，现已纠正。
- PLAN.md §6.6 同时要求扫码，又写“不提供手动粘贴 Cookie 以外的其它登录方式”，文字有冲突。实现遵循该段开头及 M6-1 明确要求：扫码为主，手动 Cookie 为备用入口；建议后续将否定句改为“不提供账号密码登录”。

格式检查：Swift 文件已使用 `xcrun swift-format format`。最终 `swift-format lint` 有 17 条命名风格警告（API 字段 snake_case、L 本地化函数及测试名称），没有格式错误；未为消除命名警告重构已完成阶段。`git diff --check` 无输出。

最终核对还修复了阿里云跨目录改名：目标目录已有原名但最终名空闲时，使用官方 move 的 new_name 参数，不修改原有同名文件。新增回归修前失败、修后通过；阿里云包 28 项通过，证据 `/tmp/kayoi-aliyun-move-red.log`、`/tmp/kayoi-aliyun-move-green.log`。真实账号按第 26 步补测 `/A/report.txt → /B/final.txt` 且 `/B/report.txt` 已存在的情形。

## 中英文与系统外观细节（2026-11-03）

本轮保留现有功能和系统跟随方式，没有新增语言/主题选择器，没有新增测试、UI 自动化或快照。

- 通过：现有 `make test` 共 123 项，退出码 0（`/tmp/kayoi-ui-test.log`）。
- 通过：`make release` 输出 `BUILD SUCCEEDED`，签名验证通过（`/tmp/kayoi-ui-release.log`）。
- 通过：英文挂载数量使用 String Catalog 单复数；Release 的 en.lproj/Localizable.stringsdict 已包含 one/other 规则。
- 已修改：行卡片和面板分别使用系统 controlBackgroundColor/windowBackgroundColor；长设备名可查看完整提示，操作按钮保持完整宽度；空状态覆盖手机、电脑、相机、网盘；取消支持 Escape，密钥指纹补充辅助功能标签。
- 待用户验证：退出旧进程后重新启动 Release；分别在中文/英文应用语言下切换系统亮色/暗色，检查菜单栏面板、添加窗口、设置和扫码窗口。使用长连接名称，确认操作按钮可见、悬停能看完整名称；检查键盘 Escape 取消、错误提示可读。未把编译成功视为这四种组合的视觉验收通过。

## 去除应用内玻璃样式（2026-11-03）

用户要求不用液态玻璃，覆盖原 §5 默认 bordered 按钮外观：保留 Button 和既有操作，使用实色填充、细边框和按下状态；窗口容器及扫码弹层指定系统实色背景，表单开关使用 checkbox。保留此前中英文及系统深浅色适配，不修改系统透明度设置。

- 通过：`make release` 退出码 0，`BUILD SUCCEEDED`，App 签名校验通过（`/tmp/kayoi-flat-release.log`）。
- 通过：现有 `make test` 123 项通过（`/tmp/kayoi-flat-test.log`）；未新增测试。
- 待用户验证：退出旧版后打开新版，在亮色和暗色分别检查面板、添加窗口、设置和扫码弹层。确认背景不透底、按钮无玻璃高光，并检查键盘焦点、禁用态和按下反馈。系统窗口边缘与弹出菜单的最终观感尚未实测，不把构建通过作为视觉通过。
- 未提交、未推送。未运行 UI 自动化或快照测试。

## 图标卡片与 SideMount 风格（2026-11-03）

用户明确要求类型选择使用图标卡片并进入下一步，后续指定 SideMount 为主要视觉参考。参考官方配对页及双设备面板的实色背景、绿色主操作、低对比边框与文字层次；未复制其代码或图标资源。

- 主要参考：https://sidemount.app/ 、https://sidemount.app/img/panel-pairing-dark.png 、https://sidemount.app/img/panel-two-phones-light.png 、https://sidemount.app/img/panel-two-phones-dark.png
- 初步参考：https://www.panic.com/transmit/ 、https://culturedcode.com/things/features/ 。最终配色以用户指定的 SideMount 为主。
- 类型选择：由五条长按钮改为三列图标卡片，选中标记与下一步；连接表单增加返回类型选择。均属用户本轮明确要求的选择流程。
- 表单：基本信息、连接信息、连接选项分组；字段标签与输入框上下排列；内容滚动，底部固定操作区。设置页补标题及说明。
- 源码尺寸：旧添加窗口宽460pt，现宽560pt；类型页高500pt，表单高620pt；卡片间距12pt、卡片高128pt、内容外边距24pt。以上为代码尺寸，未经实际截图测量。
- 检查5处 / 修改5处 / 未改0处：类型选择、连接表单、设置、主面板、扫码页。前三处调整布局，后两处仅统一颜色及按钮。实际渲染验证仍缺5处，不能据源码检查认定视觉通过。
- 通过：现有 `make test` 123项，退出码0（`/tmp/kayoi-cards-test.log`）；`make release` 与签名校验通过（`/tmp/kayoi-cards-release.log`）；`git diff --check` 无输出。
- 待用户验证：电脑控制读取 Kayoi 窗口返回 timeoutReached，未取得新版界面截图。请退出旧版后重新打开 Release，检查“添加位置”卡片未选/选中/下一步/上一步，SMB、Android、GR及两种网盘表单，设置页；分别检查中文/英文、深色/浅色、键盘焦点与错误提示。未新增测试、UI自动化或快照测试。
- 未提交、未推送。
