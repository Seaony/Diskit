# Kayoi

macOS 菜单栏连接管理工具。最低 macOS 26.0，Swift 6 严格并发检查。
实现范围和验收标准见 [PLAN.md](PLAN.md)，实际结果见 [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)。

## 构建

需要 Xcode 26.6 与 XcodeGen（`brew install xcodegen`）。

```sh
make gen
make test
make release
make dev-tool
build/bin/kayoi-dev --help
open build/DerivedData/Build/Products/Release/Kayoi.app
```

`make build` 构建 Debug；`make format` 使用 Xcode 自带 swift-format。
工程由 `project.yml` 生成，不提交 `.xcodeproj`、构建缓存或本地密钥配置。

阶段一主 App 和开发工具使用本机 `Apple Development: seaony@outlook.com` 身份签名，不需要 Team ID、付费能力或描述文件。可通过 `SIGN_IDENTITY` 指定自己的 Apple Development 身份。钥匙串首次提示访问时，请核对程序后允许；开发工具需要单独允许。测试使用随机 service，结束时删除测试条目。

配置位于 `~/Library/Application Support/Kayoi/connections.json`，缓存位于 `~/Library/Caches/Kayoi/`。密钥仅存传统登录钥匙串，service 为 `com.seaony.Kayoi`，不使用共享访问组或数据保护钥匙串。

后续配置阿里云盘时，将 `Config/Secrets.example.xcconfig` 复制为 `Config/Secrets.xcconfig` 后填写；后者被 Git 忽略。目前已实现菜单栏连接管理、系统 SMB 挂载和安卓 USB 的连接测试及开发工具文件操作；安卓无线调试也已接入；GR IV USB 也已接入；阿里云盘已接入；夸克待后续里程碑。

阶段一只有 SMB 使用系统挂载；其他 Provider 通过连接测试及 `kayoi-dev` 验证。FSKit 与 GR Wi-Fi 不在当前实现范围。

## Windows 共享

添加位置选择 Windows 共享，填写主机、用户名、密码与共享名。“列出共享”使用系统 smbutil，密码通过终端交互输入，不放入命令行或环境变量；保存前另用 NetFS 验证所填密码和共享，在独立路径临时挂载后推出。已有挂载不变，验证失败不会保存。

Windows 需开启文件和打印机共享；微软账户填邮箱与账户密码，不使用 PIN。保存后可挂载、推出、编辑、拖动排序、删除；密码存登录钥匙串，配置不存密码。App 退出保留系统托管的 SMB 挂载。开机启动通过系统登录项控制，需要使用稳定位置的 App。

日志在数据目录的 `Logs/` 内，保留最近 7 天的错误日志。界面和真机验证步骤见验收记录；目前没有真实 Windows 共享的通过结论。

## 安卓 USB

手机开启 USB 调试后，App 发现设备并支持测试连接与保存。阶段一按钮是“测试连接”，不挂载 Finder。首次授权最多等待 60 秒；设置可查看指纹并重新生成密钥（需手机重新授权）。

`build/bin/kayoi-dev devices` 列出发现设备。先在 App 保存连接，再把 connections.json 中的 UUID 传给 `ls/stat/get/put/mkdir/rm/mv/df/cat`，具体用法见 `--help`。get/put 支持递归目录，传输进度输出到 stderr。ADB 根路径映射 /sdcard；存在外置卡时根列表包含“SD 卡”。

没有依赖外部 adb 可执行文件。与官方 adb 不能同时占用手机接口；仅在手动对照验收时交替使用。BoringSSL 版本与 AOSP 来源见第三方说明，测试公钥不含私钥。真实手机、4 GB 哈希和 USB 3 性能尚待验收。

## 安卓无线调试

Android 11+ 手机打开无线调试和“使用配对码配对设备”。在添加窗口选择安卓 Wi-Fi、配对服务和六位码；已配对的连接可留空配对码直接测试。GUID 保存到 connections.json，端口不保存，每次按 GUID 重新发现。两端同机 USB 可用时优先 USB，选择结果记入 ADBTransport 日志。

`kayoi-dev pair host:port 六位码` 只配对并打印 GUID；然后在 App 从已发现的连接服务添加并测试保存。Wi-Fi 文件命令和 USB 相同，使用各自连接 UUID。真实配对、端口切换和传输验收尚待用户完成。

## GR IV USB

通过 ImageCaptureCore 发现、打开和读取相机。目录根按真实存储类型分为“内置存储”和“microSD”，保留原始 DCIM 层级；容量来自相机的标准 PTP 元数据。JPG/DNG 分块读取，不做格式转换。只允许读取和相机支持的照片删除；上传、建目录、移动立即返回只读错误。

Mac 上发现名可能是“RICOH GR”，连接后会核对 DeviceInfo 型号。当前没有 GR IV 真机结果，两个存储区、实际 PTP 返回布局和删除能力须按验收清单验证。

## 阿里云盘

填写本地 `Config/Secrets.xcconfig` 并重新构建，回调地址需与平台登记一致。添加时通过官方 OAuth 页面授权；授权目录就是此连接的根。client_id/client_secret 尚未配置时会明确提示，不假装登录成功。

令牌和刷新所需配置保存在 `<UUID>.oauth` 钥匙串记录，CLI 直接复用。用户信息、完整分页、Range、分片上传、目录/改名/移动和回收站接口均有假实现测试，实际账号行为尚待验收。

官方接口不支持原位覆盖：经批准，同名写入先完成新文件再回收旧文件；失败会报告，可能暂时同名或回收结果未确认，file_id 会改变。已经多份同名时不猜选目标。跨目录改名也不是原子操作。
