# Diskit 发行与更新

## 版本和依赖

唯一版本来源是 `project.yml` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，当前为 0.2.0（2）。每次发行营销版本与构建号都必须递增，不在脚本中另写版本号。

Sparkle 固定为 2.10.1。`Dependencies/Package.resolved` 是生成工程的锁文件，`make gen` 将它复制到被忽略的工程中；ChinaWebDrive 与 DevTool 的包锁文件也保留入库。更新依赖时同步修改这些锁文件并重新验收，不能用删除锁文件绕过解析失败。

## 本地验证

默认 `make gen`、`make test`、`make release` 使用 `Config/Validation.xcconfig`，不包含本机账号配置。`make release` 构建 arm64/x86_64 通用应用，按由内到外顺序逐个签名 Mach-O、XPC、框架和应用，不使用 `--deep`；随后逐个验证签名和应用版本、最低系统与更新配置。

`make release` 用 Developer ID Application（团队 JJJKGPY7T7）签名并强制可信时间戳，时间戳服务不可访问时构建失败，不降级。App 和 FSKit 扩展分别嵌入 `Config/Profiles/` 里的 Developer ID 描述文件，签名脚本按描述文件把权限文件里的团队前缀展开，并核对描述文件和包的 Bundle ID 一致、受限权限都在描述文件里。描述文件不是密钥，安装包里本来就带着；证书续期或权限变化后要在开发者后台重新生成并替换这两个文件。

更新源为 `https://github.com/Seaony/Diskit/releases/latest/download/appcast.xml`。公钥与 Yomi、Moni 一致，来自它们非秘密工程配置。启用 `SURequireSignedFeed` 和其前置条件 `SUVerifyUpdateBeforeExtraction`，每日自动检查；演示模式、测试宿主不会创建或启动 Sparkle 更新器。

首次发布前，后台404保持静默；手动检查显示“还没有可用的更新信息”。不会把签名失败、500或其他网络错误当成尚未发布。

## 一键发布

源码仓库 `Seaony/Diskit-Source` 保持私有，安装包和更新源发布到公开仓库 `Seaony/Diskit`；私有仓库的发布文件需要登录才能下载，别人和 Sparkle 都拿不到。公开仓库原名 `Seaony/Diskit-Releases`，0.2.0 里写的就是这个旧地址，靠 GitHub 改名后的自动跳转继续收到更新；以后不能再新建叫 `Diskit-Releases` 的仓库，否则跳转失效。

发版用所有 App 共用的脚本（全局技能 `mac-release`，用法和失败重跑说明见它的 `SKILL.md`），Diskit 的差异写在 `scripts/release-config.sh`。在干净、已推送的 master 上后台执行 `~/.agents/skills/mac-release/scripts/mac-release 0.5.0`。脚本依次：检查分支、工作区、远端同步、GitHub 登录、Sparkle 密钥、签名证书、公证凭据和版本是否已发布；构建号取上一版 appcast 的构建号加 1，和版本号一起写进 `project.yml`；运行 `make test` 与 `make release`；生成 DMG 并签名、公证、装订，再给 App 装订票据后打 ZIP 和带更新说明的签名 appcast 并验证；最后提交并推送版本号、推送源码标签、同步发布仓库，在发布仓库先建草稿 Release 上传三个文件再正式发布。任何一步失败即停止，未提交的版本号改动会还原；原样重跑会接着上次的进度，已提交的公证不会重新上传。

安装包是带背景和箭头的拖拽安装窗口，用 dmgbuild 打（`uv tool install dmgbuild`），配置在 `scripts/dmg/`：`dmg-settings.py` 定窗口大小和图标位置，`render-background.swift` 画背景（`swift scripts/dmg/render-background.swift scripts/dmg 16A6FC` 生成 `background.png` 和 `background@2x.png`，主色取图标里文件夹的蓝色；改了窗口尺寸或图标位置要两边一起改再重新生成），`render-volume-icon.swift` 用 1024 图标原图生成挂载后的卷图标。只看效果不发版：在仓库根目录执行 `dmgbuild -s scripts/dmg/dmg-settings.py -D app=<Diskit.app 路径> Diskit /tmp/Diskit-preview.dmg`，再打开挂载出来的卷。不要在配置里隐藏 `.app` 扩展名，那样会往 App 包里写入额外信息，签名校验通不过。

更新说明默认列出上个版本以来的提交；想写给用户看的说明时，先提交 `docs/release-notes/v版本号.md`（每行一条“- 说明”），脚本会改用这份。

加 `--dry-run` 完整打包、公证和验证，输出到 `build/releases/v版本号/`，不提交、不推送、不发布。撤回一次发布：`gh release delete v版本号 --repo Seaony/Diskit --yes --cleanup-tag`，再 `git push origin :refs/tags/v版本号`。

Sparkle 签名账户默认 `com.seaony.Moni`，可在 `scripts/release-config.sh` 里用 `SPARKLE_ACCOUNT` 指定现有账户。脚本不导出、不打印私钥、不自动生成替代密钥；没有匹配密钥时失败。验签先确认账户公钥与应用公钥相同，再使用官方 `sign_update --verify` 分别验证 feed 与压缩包，验签成功后才解压检查应用。只存在 `edSignature` 字段不能算验证通过。

默认使用 `Config/Validation.xcconfig` 构建，不含任何开放平台凭据，发行版里官方网盘会显示“此网盘尚未在 Diskit 中启用”。

## Developer ID 与公证

公证凭据存在登录钥匙串里，名字默认 `notary`（可在 `scripts/release-config.sh` 里用 `NOTARY_PROFILE` 指定），用 `xcrun notarytool store-credentials notary` 建一次，App Store Connect API 密钥或 App 专用密码都可以；凭据不写进仓库和命令参数。每次发布只提交一次公证：DMG 签名后提交，苹果连里面的 App 一起认证；通过后 DMG 和 App 各自装订票据，更新用的 ZIP 用装订过的 App 打包。公证没通过时脚本打印苹果返回的日志并停止。

## UPD-07 本地更新演练的约束

规范要求 0.2.0 → 0.2.1 实际发现、下载、安装和重启；本轮用户同时要求只以 `DISKIT_DEMO=1` 启动应用，且 UPD-04 明确演示与测试中不能启动更新器。遵守这两个更严格的隔离要求，本轮不能暗中启用更新器完成真实安装演练，也不会自行启动 HTTP 服务。

待用户允许一次独立隔离演练后：使用临时副本、专用用户偏好域和临时签名密钥，构建两个同 bundle ID 的版本，分别为 0.2.0（2）与 0.2.1（3）；副本使用 loopback HTTP 更新源与临时公钥，临时 ATS 例外仅限 loopback。由用户启动本地临时 HTTP 服务，更新副本仅使用假账号/假设备数据；逐步截图发现、下载、安装、重启后的版本。完成后停止服务并删除副本、临时密钥、偏好域及配置；不修改生产feed、公钥、仓库版本或真实安装。此步骤在获得隔离例外并实际操作前始终记为待验收。
