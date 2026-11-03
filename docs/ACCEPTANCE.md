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
- 保存前用 NetFS 和填写的密码进行独立连接测试，在缓存目录下的随机路径短暂挂载并推出；不改变已有挂载。
- `smbutil view -f` 通过独立终端输入密码，`-f` 避免直接复用现有会话，但其输出只用于列共享，不充当表单密码验证。

依据：[Apple view.c](https://github.com/apple-oss-distributions/smb/blob/main/smbutil/view.c)、[Apple server.c](https://github.com/apple-oss-distributions/smb/blob/main/lib/smbclient/server.c)、本机 NetFS.h。没有复制 Apple 源代码。

## M2 安卓 USB

未开始。8 条验收尚未执行。

## M3 安卓 Wi-Fi

未开始。6 条验收尚未执行。

## M4 GR IV USB

未开始。3 条验收尚未执行。

## M5 阿里云盘

未开始。5 条验收尚未执行。

## M6 夸克

未开始。3 条验收尚未执行。

## 待用户验证（按操作顺序）

目前仅 M1 有待测项目，M0 无待测项。请使用一个专门的测试共享和不重要的文件。

1. **启动和面板（M1-1/2）**：在仓库执行 `open build/DerivedData/Build/Products/Release/Kayoi.app`。确认没有 Dock 图标，菜单栏可打开面板；无连接时显示空状态和添加按钮。分别切换系统浅色/深色；到系统“语言与地区”给 Kayoi 选英文后重启，检查文案与布局。
2. **准备 Windows（M1-3）**：在 Windows 开启文件和打印机共享；新建测试文件夹并共享，给测试账号读写权限，记下 IP、共享名、用户名与密码。微软账户使用邮箱和账户密码，不使用 PIN。
3. **列共享与错误密码（M1-3/5）**：添加 Windows 共享，填入主机、用户名、密码，点“列出共享”。先用错误密码点“测试并保存”，应提示“用户名或密码错误”，列表中不能新增连接；改为正确密码后保存。保存时会临时挂载再推出，此时不得影响已经挂载的共享。随后在系统已有 SMB 认证的情况下再次填写错误密码，确认仍拒绝保存。
4. **Finder 操作（M1-3）**：点击挂载，检查 Finder 的共享位置；拷入测试文件、拷出、新建目录、改名、删除；对照 Windows 目录内容。点击推出，确认 Finder 与面板挂载状态同步消失。
5. **编辑、排序、自动挂载和退出（M1-2/8）**：添加第二条有效连接，编辑名称/颜色，拖动行改变顺序；开启一条连接“打开 App 时自动挂载”，推出它并退出 App，再运行第 1 步命令。确认名称、顺序和开关保持，开启项自动挂载；App 退出不影响已挂载的 SMB 共享。
6. **Bonjour（M1-4）**：在同一局域网另一台 Mac 开启文件共享；用 `dns-sd -B _smb._tcp local.` 确认其正在广播（结束按 Ctrl+C），观察 Kayoi“已发现”，点击添加应预填主机和名称。
7. **删除密钥（M1-6）**：从 `~/Library/Application Support/Kayoi/connections.json` 找到测试连接 UUID，删除该连接。执行 `security find-generic-password -s com.seaony.Kayoi -a '<UUID>.password'`，预期查不到条目；不要使用会输出密码的 `-w` 或 `-g` 参数。
8. **开机自启（M1-7）**：将 Release App 复制到稳定位置（例如 `~/Applications/Kayoi.app`）并从该位置启动；打开设置、开启自动启动，若系统要求则到登录项设置允许。保存其他工作后注销再登录，确认菜单栏出现；关闭开关后重复验证不再启动。
9. **设置附加项（§4.4）**：查看日志目录，检查缓存显示与上限；清空缓存时必须先确认并成功推出已挂载共享。面板关闭时不应继续容量显示轮询。此项为手动检查，未声称通过。

## 未做与风险

- M2–M6 尚未开始；M7、M8 按要求不做。
- Windows 网络、密码验证、临时挂载与推出尚无实测。假实现只证明应用流程，不证明系统 API 在目标共享上的行为。
- 临时挂载点只用 `rmdir` 删除空目录；推出失败不会递归删除远端内容。若出现错误并留下临时挂载，请保留错误信息后用 Finder 推出对应卷。
- 仅安装了已授权的 XcodeGen，无新增第三方库。未使用 Jev：本阶段是确定性的系统接口与编译检查。
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
