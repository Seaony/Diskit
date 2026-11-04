# 自建对象存储 HTTP 协议一致性

依据 `docs/AUDIT-2026-11-04.md:204`：前端允许保存 HTTP MinIO，但 S3 connect 只接受 HTTPS。

## 复现与修正

`Packages/S3Drive/Tests/S3DriveTests/EndpointProtocolTests.swift:9` 的 HTTP/HTTPS 同端点参数测试，先确认 HTTP 在 connect 抛 EINVAL，而 HTTPS 正常；同文件 `:25` 同时暴露了后端未拒绝 URL 内嵌账号密码。失败原始输出 `CURRENT-S3HTTP-before.log`。

`Packages/S3Drive/Sources/S3Drive/S3EndpointPolicy.swift:4` 为前后端共用规则：HTTPS 可用，HTTP 仅接受未限定主机名、.local、本地 IPv4 私有/回环/link-local、本地 IPv6 ULA/link-local/回环。公网域名和公网 IP 仍要求 HTTPS。拒绝其他协议、URL 内嵌凭据，以及不能和 ATS CIDR 声明可靠对应的非标准 IPv4 数字表示。

后端 `S3Provider.swift:148`、前端 `App/Logic/EditorValidation.swift:67` 共用该规则，避免保存后才失败。`S3Provider.swift:131` 的并发账号端口默认值区分 HTTP 80 与 HTTPS 443。预设仍生成 HTTPS；其他网盘的 URL 限制未修改。新增提示中英翻译已写入 App/Localizable.xcstrings。

## ATS 范围

Apple 官方说明 macOS 14 起 IP 默认不再享有 ATS 放行，并支持按 IP/CIDR 配置例外；DNS 例外与 IP 例外不互相替代。依据：[NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)、[NSExceptionDomains](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)。

`project.yml:117` 仅声明本地网络，以及 10/8、172.16/12、192.168/16、127/8、169.254/16、fc00::/7、fe80::/10、::1 的 HTTP 例外。没有 NSAllowsArbitraryLoads、WebContent/Media 全局例外，没有降低公网 TLS。自建服务若使用完整公网域名，即使解析到私有 IP，仍需 HTTPS；可使用本地名称/.local/局域网 IP 访问 HTTP。

## 验证

- `swift test --package-path Packages/S3Drive --filter 's3CustomMinIOEndpointPreservesExplicitProtocol|s3RejectsUnsupportedOrEmbeddedCredentialEndpoints|s3EndpointPolicy'`：4 个测试函数、27 组参数案例通过。证明 HTTP 请求协议、Host:port、AWS4 签名保留，及本地地址允许/公网拒绝。输出 `CURRENT-S3HTTP-after.log`。
- 中间发现 Network.IPv4Address 会接受数字地址形式，已补标准点分十进制检查；最终上述回归通过，不隐去该修正。
- `make gen` 通过，输出 `CURRENT-S3HTTP-gen.log`。
- `python3 -m unittest discover -s scripts/tests -p test_local_network_policy.py`：读取实际生成 build/Info.plist，验证例外集合、私有范围、公网地址不被覆盖、无全局 ATS 放行；1 个测试通过。输出 `CURRENT-S3HTTP-ATS.log`。
- App 测试 `objectStorageEditorMatchesBackendLocalHTTPPolicy`（`Tests/KayoiTests/EditorConfigurationTests.swift:156`）已补 S3/MinIO 前端边界，按主任务协调留统一 App 验证，不另起 xcodebuild。
- 本次 strings 快检暴露同期 HelpGuide 的旧/新删除提示键尚未同步，已交文案负责人集中合并；不是此次新增提示键。原输出 `CURRENT-S3HTTP-strings.log`，不能写为检查通过。
- `git diff --check` 通过。未连接真实 MinIO、账号或设备，未开启本地服务；ATS 实际运行及真实菜单点击留用户验收，mock 通过不等于真实网络已验证。
