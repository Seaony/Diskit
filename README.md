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

后续配置阿里云盘时，将 `Config/Secrets.example.xcconfig` 复制为 `Config/Secrets.xcconfig` 后填写；后者被 Git 忽略。目前 M0 仅提供工程、存储抽象与开发工具命令占位，不支持实际远端操作。

阶段一只有 SMB 使用系统挂载；其他 Provider 通过连接测试及 `kayoi-dev` 验证。FSKit 与 GR Wi-Fi 不在当前实现范围。
