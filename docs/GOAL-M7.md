# M7 第二步：把 FSKit 接进正式功能

先读 AGENTS.md、PLAN.md（重点 §3.3、§3.4、§4、§6、§7、§8 M7）、docs/SPIKE.md（第一步验证结论，必读），再读 App/、FSExtension/、FSShared/ 和 Packages/*/Sources。
用户已批准按 PLAN M7 第二步开始做。本文件和 PLAN.md 冲突时以本文件为准。

## 已定的事（不要再改方向）

- 付费团队 `JJJKGPY7T7`，`make build` 由 Xcode 自动签名，扩展是 `com.seaony.Diskit.FS`（`FSExtension/`）。
- §7 一次性迁移在这一步做。数据目录迁到 App Group `JJJKGPY7T7.com.seaony.Diskit`，钥匙串迁到共享访问组 `JJJKGPY7T7.com.seaony.Diskit.shared`（data protection keychain）。
- 最低系统版本保持 macOS 26。挂载：27 起用 `FSClient.mountSingleVolume`，26 用 `mount -F -t diskit <URL> <挂载点>`（26 上没实测过，代码要按 SPIKE 的结论写，报告里注明「26 未实测」）。
- `make release` 继续在签名前删掉 `Contents/Extensions`，**不要改发布流程**。正式包怎么带上扩展（Developer ID 加描述文件），以后由用户单独决定。
- GR IV：用户没有相机，这一轮不动 GR，保持现有行为。

## 硬约束

- 每完成下面一个小步就提交并推送到 origin/master（`git push`），**不要攒一大堆再提交**。提交前这一步必须 `make build` 通过，涉及逻辑的要跑相关测试。提交信息是一句简短的中文，不写正文，不提 AI。不新建分支，不强推。
- 不发布、不打 tag、不改 Sparkle 的 appcast。
- UI 按 AGENTS.md：不用液态玻璃，不透明背景，按钮实色填充加细边框，保留深浅色适配。新文案全部进 Localizable.xcstrings，中英文都要有。
- 只用系统框架，新增第三方依赖先停下问。代码注释用简短中文。
- 不删已有功能，不悄悄降级。拿不准就保留原行为，写进报告。
- **用户数据安全**：迁移只复制，确认新位置写入且读回一致后才删旧条目；失败时保留旧数据并提示。在这台机器上第一次跑迁移之前，先把 `~/Library/Application Support/Diskit/` 整个复制到 `build/backup-<时间>/`（build/ 已在 .gitignore 里）。钥匙串旧条目在迁移验证通过之前不删。
- 遵守 SPIKE.md「实现时要注意的事」：回调不能在持锁时调用；列目录不返回 `.`、`..`；扩展里开 USB 需要那条 IOKit 例外权限（已加）；部署目标是 26，用 `FSVolume.Operations` 这一套接口。
- 不准操作用户的 Dia 浏览器（用户自己在用，里面开着别的页面）。自查 App 界面用 `screencapture -l <窗口号>` 只截 Diskit 窗口；需要网页时用无头 Chrome，用完就关。不要模拟鼠标点击，用户可能正在用电脑。
- 碰到需要用户拍板的事（产品行为、取舍），停下写清选项和你的建议，不要自己定。

## 优先级（决定先做什么、做到什么程度）

- **P0**：直接决定用户能不能在 Finder 里真正用上的事。也就是真机上能挂载、浏览、拷进拷出、推出；不丢数据；出了问题能查。所以扩展和主 App 里挂载、读写、断线这些路径都要有日志（os.Logger，category 区分清楚），错误要带上能定位问题的信息。
- **P1**：常见的出错路径，比如扩展没启用、设备拔掉、网络断了、登录过期，要给出能看懂的提示。
- **P2**：罕见边角，比如少见的时序、超大目录、奇怪的文件名变体。只在 M7-REPORT.md 里记一行，**不写代码、不加测试矩阵**。
- 不扩大范围：本文件没写的功能不做。想到值得做的，只在报告里记一行。

## 并行分工

- 能并行的活拆给子代理做，不要一个人从头干到尾。你当主控：拆任务、定接口、合并结果、跑 make build 和 make test、提交推送；子代理不提交、不推送。
- 按文件分工，每个子代理只改自己负责的文件。调研、读代码、写测试、跑单包测试、核对验收也交给子代理并行。
- 只有真正前后依赖的才串行（比如共享接口没定之前，先由主控定好再分出去）。每次拆分时，在汇报里写一句拆成了哪几块。

## 汇报

- 每完成一小步（提交推送之后），用 `cmux agent message --from codex surface:1000070014 "<一两句话：第几步、提交号、怎么验证的、有没有没测的>"` 报给我（Claude，负责审查）。
- 需要用户拍板时，也用同样的方式发给我，写清选项和你的建议，然后停下等回复。

## 小步顺序（每步一个提交）

1. **存储迁移**：`StorageLocation` 和 `SecretStore` 切到 App Group 和共享钥匙串，实现 §7 一次性迁移，写单元测试覆盖成功、部分失败、重复运行这三种情况。`diskit-dev` 也要能继续读到配置和密钥：命令行工具不能嵌描述文件，先查清可行做法（比如把它作为 App 内的辅助程序，或者改读方式）。如果没有不降级的做法，停下来汇报。
2. **扩展分发骨架**：删掉假数据卷，扩展按 URL `diskit-<类型>://<连接ID>` 读取连接配置和密钥，创建对应的 Provider。`FSSupportedSchemes` 覆盖所有要走 FSKit 的类型。实现 §3.4：目录缓存（设备 5 秒、网盘 30 秒，本卷内的写操作让缓存失效）；读（支持按范围读的直接读，不支持的拉整文件到扩展容器缓存，总量上限 5 GB，按最近使用淘汰）；写（写到临时文件，关闭或 fsync 时上传，失败把错误返回给关闭操作）；只读能力返回 `EROFS`；断线返回 `EIO`。
3. **本地覆盖层**：扩展属性和 `.DS_Store`、`.VolumeIcon.icns`、`.Spotlight-V100`、`.fseventsd`、`.Trashes` 存在扩展容器里（按连接 ID 分目录），不写到远端。SPIKE 第 6 条已证明支持扩展属性后不会产生 `._*` 文件。
4. **主 App 挂载和推出**：按系统版本走 `FSClient` 或 `mount -F`；推出用 `FileManager.unmountVolume`。F3 横幅（扩展没启用时显示，点击用 `FSClient.openFileSystemExtensionsSettings()`，26 上用等效的跳转）、F15 扩展状态。非 SMB 行的主按钮改成「挂载 / 推出」，扩展没启用时点挂载就提示并跳转系统设置。「打开 App 时自动挂载」对所有类型生效；退出 App 时推出本 App 挂的全部卷（SMB 除外）；设备消失时主动推出卷。卷名用连接名称。
5. **安卓 USB 和 Wi‑Fi**：按 PLAN M7 第二步验收第 2、3、4 条在真机上测。测试机是 Xiaomi 17，已经插在这台 Mac 上。ADB 钥匙以传统登录钥匙串 `com.seaony.Diskit` 里的 `adb.private-key` 为准（用户平时一直在用、其他手机也授权过的那把），迁移它，不生成新钥匙。Xiaomi 如果因此要重新点一次「允许 USB 调试」，在报告里写一句即可。
6. **阿里云盘、夸克**：按验收第 6、7 条测。没有登录信息就测不了的，写清楚哪条没测、为什么。
7. **其余网盘和对象存储**：已经有 Provider 的类型，逐个接上 FSKit。每类至少验证「能挂载、能浏览」；没有账号测不了的，在报告里列出来。
8. 清理：删掉 `App/FSKitSpike.swift` 的验证入口和 FSShared 里的 Spike 代码，保留 `docs/SPIKE.md`。同时删掉第一步验证时建的测试数据：共享钥匙串里 service 为 `com.seaony.Diskit.spike` 的条目（包括那把测试 ADB 钥匙），以及 App Group 里的 `spike-check.txt`。这些都是验证时临时建的，不是用户数据，第 8 步之前不要动。

## 验收与报告

- 每一步都按 PLAN §8 记录到 docs/ACCEPTANCE.md：通过、不通过、未测，附现象和实测数据，不许只写「已完成」。
- 全部做完后：`make build`、`make test` 全部通过，再用正式模式（不加任何 `DISKIT_DEMO*` 环境变量）后台启动 Debug 构建，等用户验收。
- 最后写 docs/M7-REPORT.md：每一步做了什么、怎么验证的、没做或没测的项目及原因、需要用户决定的事。
