# ChinaWebDrive

B4 的实验性网页接口 Provider，只包含中国移动云盘（139 个人云盘）和迅雷云盘。两个接口都没有面向个人用户、与本实现匹配的稳定官方 SDK；网页改版或登录策略变化时可能随时失效。

## 中国移动云盘

`MobileCloudProvider` 支持浏览、游标分页、容量、HTTP Range、上传分片、新建目录、移动/改名和删除。上传前先查同级目录，发现同名时返回 `EEXIST`，不会覆盖或改名。凭证是网页登录得到的手机号和 `Authorization: Basic` 后面的 token；提供网页 `UD_ID` 对应的 `userDomainID` 后，容量查询使用同一个用户域。

接口依据：

- 当前官方网页入口：<https://yun.139.com/w/>（2026-11-04 核验）
- 当前官方网页脚本：<https://yun.139.com/w/static/js/app.56b4a805.js>（2026-11-04 核验，SHA-256 `400dacc3a6a6040428f54cb3b23914f3c715cf94223e47e3d2cf0655e370131f`）
- 当前官方上传实现脚本：<https://yun.139.com/w/static/js/chunk-vendors.d548cc73.js>（2026-11-04 核验，SHA-256 `085ea981d5fa55b9de5f581b730915247ad95bece752e5fad31f70ae5a8bacaa`）
- 移动云盘开放平台入口：<https://open.yun.139.com>（面向申请 appid、secret key、access token 的开发者，不能直接替代网页登录）
- MIT 参考实现：<https://github.com/Taizong547/YunpanTingshu>，commit `3ba2078ac7a86ca54c0d4b0975b0224b5e3cc71c`。签名、路由和列表行为经过交叉核对；未复制代码。

网页脚本确认了 `file/list`、`file/get`、`file/create`、`file/getUploadUrl`、`file/complete`、`file/getDownloadUrl`、`file/update`、`file/batchMove`、`file/batchDelete` 和 `disk/getPersonalDiskInfo`。脚本的目录创建和本地上传仍使用 `auto_rename`；本 Provider 在发送前检查同名，并验证服务器返回的名字，避免把竞态中的自动改名当成成功。

## 迅雷云盘

`XunleiProvider` 支持浏览、分页、容量、HTTP Range、上传、新建目录、移动/改名和移入回收站。上传请求只声明 `PROVIDER_ALIYUN`，使用官方 `alibabacloud-oss-swift-sdk-v2` `0.4.0` 和迅雷返回的临时 STS 凭据完成 OSS multipart。SDK 启用 CRC64 校验，并要求初始化与完成时禁止覆盖。上传前检查同级同名文件；上传后轮询文件详情，直到迅雷标记完成并核对名字、大小。上传失败会只清理本次新建的迅雷条目，不改已有文件。

接口依据：

- 当前官方网页：<https://pan.xunlei.com/>（2026-11-04 核验）
- 当前官方网页脚本：<https://static-pan.xunlei.com/_nuxt/dist/client/utils-initial.f23af17a7de85831b2fa.js>（SHA-256 `84d082028c7bf392dc93c4a3d9cb31287fb04e86a1b2d2c41c2ac2d40964d180`）、<https://static-pan.xunlei.com/_nuxt/dist/client/103.e8c37844699656bb4674.js>（SHA-256 `c6ce32217f967dcd3e3304e98c33007a95c69c2f11c903df5a39828fc2497646`）、<https://static-pan.xunlei.com/_nuxt/dist/client/utils-drive-upload.01e7eec9b34410de6748.js>（SHA-256 `dba870b7c6ec08827098b4f8b10be5c373701e69bb9574a5d8fb99e820c9f1b8`）（2026-11-04 核验）
- 网页脚本确认 `https://api-pan.xunlei.com/drive/v1/files` 的 `parent_id`、`page_token`、`limit`、`filters` 参数，`files/:id/move` 的 `to.parent_id`/`to.name`，`files:batchDelete`，以及 `Authorization: Token ...`。详情字段 `web_content_link` 和 `medias[].link.url` 用作下载地址。
- 网页上传脚本确认 `UPLOAD_TYPE_RESUMABLE` 和 `PROVIDER_ALIYUN`、`PROVIDER_TENGXUNYUN`、`PROVIDER_HUAWEIYUN`、`PROVIDER_HUOSHANYUN` 分支。未用 OpenList/AList 代码，也没有把它们的上传实现当作规格。
- 官方 SDK：<https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2>，固定 `0.4.0`（commit `335c1777bf3c4aa86d7212c03e515de53b192418`）。只使用基础 `AlibabaCloudOSS` product，没有引入 OSS Extension。

迅雷下载地址可能位于 CDN。下载请求只带浏览器 UA 和 referer，不带 `Authorization`、`Space-Authorization` 或 Cookie。

## 认证刷新

两套 Session 都接受异步 `refresh` 回调。收到 HTTP 401/403 或已核实的登录失效业务码时，只刷新并重试一次；回调失败统一报登录失效。包本身不启动浏览器、不保存密钥；调用方应把刷新结果安全保存。

## 待用户验收

- 用当前账号验证移动云盘网页 token、路由地址、分页和上传完成响应。
- 用当前账号验证迅雷 token、分页、详情下载链接、WebDAV 式路径映射和真实文件上传。
- 在真实网络下验证两个平台的 Range `206`、同名竞态和限流/空间不足错误。
- 准备 0 字节、一个完整分片和末片不足的文件，核对迅雷网页端名称、大小和最终内容。

## 开发检查

```sh
swift-format format --in-place --recursive Sources Tests Package.swift
swift test
```
