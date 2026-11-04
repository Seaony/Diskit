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

需要开放平台凭据时，将 `Config/Secrets.example.xcconfig` 复制为 `Config/Secrets.xcconfig` 后填写；后者被 Git 忽略。目前实现菜单栏连接管理、系统 SMB/WebDAV/NFS、安卓 USB 与无线调试、GR IV 和通用 USB 相机、七种 S3 兼容对象存储、阿里云盘、六个官方网盘、夸克/UC、天翼、移动、迅雷、PikPak 和蓝奏云。真实账号与外部设备仍按验收记录逐项验证。

SMB、HTTP/HTTPS WebDAV 和 NFS 使用 macOS NetFS 挂载到 Finder；其他 Provider 通过连接测试及 `kayoi-dev` 验证。FSKit 与 GR Wi-Fi 不在当前实现范围。

## SMB 共享

添加位置选择 SMB，填写主机、用户名、密码与共享名。“列出共享”使用系统 smbutil，密码通过终端交互输入，不放入命令行或环境变量；保存前另用 NetFS 验证所填密码和共享，在独立路径临时挂载后推出。已有挂载不变，验证失败不会保存。

Windows 需开启文件和打印机共享；微软账户填邮箱与账户密码，不使用 PIN。保存后可挂载、推出、编辑、拖动排序、删除；密码存登录钥匙串，配置不存密码。App 退出保留系统托管的 SMB 挂载。开机启动通过系统登录项控制，需要使用稳定位置的 App。

日志在数据目录的 `Logs/` 内，保留最近 7 天的错误日志。界面和真机验证步骤见验收记录；目前没有真实 Windows 共享的通过结论。

## WebDAV 与 NFS

WebDAV 支持 HTTP、HTTPS 和常见服务预设，使用完整服务器 URL、用户名与密码；NFS 使用服务器地址和导出路径。两者都声明为系统挂载类型，保存前的密码测试会临时挂载到独立路径，成功后推出。

本机对临时 WebDAV 服务的 `mount_webdav` 直接挂载和推出成功，但 `NetFSMountURLAsync` 对该测试服务返回认证错误。实现保留 NetFS 路线，实际坚果云、Nextcloud、ownCloud、群晖、威联通与 NFS 导出仍需用户按验收清单测试。

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

## 相机（USB）

通用相机入口通过 ImageCaptureCore 发现本地 PTP/MTP 相机，过滤 iPhone、iPad 等非相机设备。Provider 暴露相机存储和 DCIM 层级，支持 Range 下载；删除仅在设备声明支持时尝试，上传、建目录和移动返回只读错误。富士、索尼、佳能、尼康等品牌与删除能力仍需真机验收。

## 对象存储

支持 Amazon S3、Cloudflare R2、阿里云 OSS、腾讯云 COS、七牛 Kodo、MinIO 和 Backblaze B2。各预设会填写 endpoint、region 和寻址方式；认证使用系统 CryptoKit 计算 SigV4。支持分页、Range、multipart 上传、递归目录操作、条件冲突和常见 HTTP/XML 错误映射。假实现测试通过，真实存储桶与权限范围待验收。

## 阿里云盘

填写本地 `Config/Secrets.xcconfig` 并重新构建，回调地址需与平台登记一致。添加时通过官方 OAuth 页面授权；授权目录就是此连接的根。client_id/client_secret 尚未配置时会明确提示，不假装登录成功。

令牌和刷新所需配置保存在 `<UUID>.oauth` 钥匙串记录，CLI 直接复用。用户信息、完整分页、Range、分片上传、目录/改名/移动和回收站接口均有假实现测试，实际账号行为尚待验收。

官方接口不支持原位覆盖：经批准，同名写入先完成新文件再回收旧文件；失败会报告，可能暂时同名或回收结果未确认，file_id 会改变。已经多份同名时不猜选目标。跨目录改名也不是原子操作。

## 夸克网盘（实验性）

添加时通过内嵌网页扫码，也可手动粘贴 Cookie；验证账号和容量成功后才存入登录钥匙串 `<UUID>.cookie`。非官方接口可能随时失效，实际账号字段、扫码与大文件传输仍待验收。

同名上传直接报错，旧文件不改动。文件操作使用 kayoi-dev；Cookie 失效后需重新登录。不要将 Cookie 写进配置或提交到 Git。

## 官方开放平台网盘

支持百度网盘、115 网盘、123 云盘、OneDrive、Google Drive 和 Dropbox。授权使用系统浏览器并校验回调 state，令牌保存在登录钥匙串的 `<UUID>.oauth.<kind>` 记录；删除位置时同步删除。连接、分页、Range 下载、上传分片、回收站删除、同名拒绝、401 刷新一次和限流重试均有假实现测试。

- 百度网盘只访问应用专属目录，普通账号可能受下载速度和文件大小限制。
- 123 云盘单文件上限为 10 GB，上传完成轮询最多等待 60 秒。
- OneDrive 大文件使用上传会话；Google Drive 小于或等于 5 MiB 使用 multipart，大文件使用 resumable；Dropbox 大文件使用 upload session。
- 六个平台遇到同名文件都报错，不改动旧文件。

在 `Config/Secrets.xcconfig` 填写各平台 client ID、client secret 和已登记的 `kayoi://oauth/...` 回调地址。百度上传还需要 App ID。凭据缺失时界面只说明“此网盘尚未在 Kayoi 中启用”，不会显示开发字段。真实授权、令牌刷新、网页端结果和回收站仍待用户验收。

## 实验性网页网盘

支持夸克、UC、天翼个人云/家庭云、移动云盘、迅雷、PikPak 和蓝奏云。它们使用网页登录信息或账号密码，接口可能随服务商改版失效；登录信息只存登录钥匙串。蓝奏云只读。迅雷的上传使用官方阿里云 OSS Swift SDK 和迅雷提供的临时 STS 凭据，支持阿里云 OSS 分片；同名上传直接报错，上传失败会清理新建条目，不改旧文件。其余平台的上传、目录操作、同名规则、限流和登录刷新均有假实现覆盖。

真实账号、扫码、网页风控、分片上传和回收站行为仍待验收。不要将 Cookie、访问令牌或账号密码写入配置或提交到 Git。

## 隔离验收构建

`make gen`、`make test`、`make release` 默认使用 `Config/Validation.xcconfig`，不加载本机密钥文件。单元测试的密钥存储只在内存中。真实账号验收由用户另行运行 `make release KAYOI_BUILD_CONFIG=Config/App.xcconfig`；该入口会读取用户本地凭据，不用于自动验收。直接运行 XcodeGen 时也需显式设置 `KAYOI_BUILD_CONFIG`。
