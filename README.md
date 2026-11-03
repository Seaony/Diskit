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

后续配置阿里云盘时，将 `Config/Secrets.example.xcconfig` 复制为 `Config/Secrets.xcconfig` 后填写；后者被 Git 忽略。目前 M1 提供菜单栏连接管理和系统 SMB 挂载；安卓、GR、网盘与开发工具远端子命令仍待后续里程碑实现。

阶段一只有 SMB 使用系统挂载；其他 Provider 通过连接测试及 `kayoi-dev` 验证。FSKit 与 GR Wi-Fi 不在当前实现范围。

## Windows 共享

添加位置选择 Windows 共享，填写主机、用户名、密码与共享名。“列出共享”使用系统 smbutil，密码通过终端交互输入，不放入命令行或环境变量；保存前另用 NetFS 验证所填密码和共享，在独立路径临时挂载后推出。已有挂载不变，验证失败不会保存。

Windows 需开启文件和打印机共享；微软账户填邮箱与账户密码，不使用 PIN。保存后可挂载、推出、编辑、拖动排序、删除；密码存登录钥匙串，配置不存密码。App 退出保留系统托管的 SMB 挂载。开机启动通过系统登录项控制，需要使用稳定位置的 App。

日志在数据目录的 `Logs/` 内，保留最近 7 天的错误日志。界面和真机验证步骤见验收记录；目前没有真实 Windows 共享的通过结论。
