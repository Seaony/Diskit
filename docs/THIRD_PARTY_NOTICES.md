# 第三方来源

## BoringSSL

- 来源：https://boringssl.googlesource.com/boringssl
- 固定版本：`629a0ef2e705964bde48ff804ea286a1fd677169`
- 许可证原文：`Packages/ADB/Vendor/BoringSSL/LICENSE`
- 文件清单：同目录 `gen/sources.json`，编译清单 `SOURCES.txt`。
- 只选取 crypto/bcm 的 C/C++ 源码、依赖头文件及生成文件；禁用汇编以统一 arm64/x86_64 构建。未构建 SSL/TLS 实现。
- 调用范围：经用户批准，用于 Android 公钥编码的大整数运算；无线配对使用 SPAKE2。RSA 私钥生成、签名仍使用 Security，TLS 仍使用 Network.framework。

## AOSP ADB（Apache-2.0）

参考时 ADB main 为 `1cf2f017d312f73b3dc53bda85ef2610e35a80e9`，system/core main 为 `a3b721a32242006b59cb12bd62c9133632af3a2d`。

协议实现参考：

- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb.h
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/transport.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/file_sync_protocol.h
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/client/file_sync_client.cpp
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/shell_protocol.h
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/protocol.md
- https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/dev/sync.md

`bridge/AndroidPublicKey.cc` 根据 AOSP `libcrypto_utils/android_pubkey.cpp` 改写，保留版权和许可声明；只调用 BoringSSL 运算，不自行实现密码学原语。
原始来源：https://android.googlesource.com/platform/system/core/+/refs/heads/main/libcrypto_utils/android_pubkey.cpp
Copyright (C) 2016 The Android Open Source Project，Apache License 2.0。
许可证副本：`docs/licenses/Apache-2.0.txt`。原文：https://www.apache.org/licenses/LICENSE-2.0

注意：历史 protocol.md 将消息校验字段写成 data_crc32，但实际 adb.cpp 是字节累加和；transport.cpp 对 0x01000001 及以上版本跳过此校验。代码按实际版本规则处理。

## 测试公钥

`Packages/ADB/Tests/ADBTests/Fixtures/` 中的公钥由本机已有官方 Android Platform-Tools 37.0.1-15733141 的 `adb keygen` 离线生成。
同一个一次性密钥的 PKCS#1 公钥用系统 openssl 导出为 DER，测试把编码结果与官方 adbkey.pub 的 Base64 部分逐字节比较。
临时私钥在生成后删除，不入库；没有启动 adb server，也没有连接真实设备。

## AOSP 无线调试

M3 对照同一固定 ADB 版本的 pairing_auth、pairing_connection、tls/tls_connection.cpp、crypto/x509_generator.cpp、daemon/mdns.cpp、proto/pairing.proto。
SPAKE2 使用 BoringSSL；HKDF-SHA256 和 AES-128-GCM 使用 CryptoKit；证书结构用 DER 编码，RSA 签名由 Security 执行，未实现密码学原语。
AOSP 的 exporter 标签及 SPAKE2 名字包含末尾 NUL，HKDF info 不包含末尾 NUL；帧长度是大端，PeerInfo 为 8192 字节。

## GR IV 元数据

PTP/MTP StorageInfo、DeviceInfo、ObjectInfo 字段顺序参考 AOSP frameworks/av/media/mtp 下对应实现（Apache-2.0）；只用公开 ImageCaptureCore API发送标准只读命令，没有引入第三方相机库。
- https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/mtp/MtpStorageInfo.cpp
- https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/mtp/MtpDeviceInfo.cpp
- https://android.googlesource.com/platform/frameworks/av/+/refs/heads/main/media/mtp/MtpObjectInfo.cpp
实际 ICC/GR 返回仍需要真机验证；测试样例是标准字段，不是 GR 抓包。

## 阿里云盘官方开放平台

仅按官方接口实现，没有复制 SDK 代码：
- OAuth：https://www.yuque.com/aliyundrive/zpfszx/efabcs
- 账号和空间：https://www.yuque.com/aliyundrive/zpfszx/mbb50w
- 上传：https://www.yuque.com/aliyundrive/zpfszx/ezlzok
- 错误和限流：https://www.yuque.com/aliyundrive/zpfszx/rgg2p1qnsfdux61r
- FAQ（不支持原位覆盖）：https://www.yuque.com/aliyundrive/zpfszx/zscu11
官方 Android SDK仅用于交叉核对请求字段：https://github.com/alibaba/aliyunpan-android-sdk

## 夸克网页接口（实验性）

仅参考 OpenList 驱动的 HTTP 接口行为，没有复制其 AGPL-3.0 代码：
- https://github.com/OpenListTeam/OpenList/tree/main/drivers/quark_uc
- https://doc.oplist.org/guide/drivers/quark

账号昵称和未登录响应交叉核对夸克公开网页脚本：
https://g.alicdn.com/quark-cloud-drive/quark-cloud-drive-static-page/0.1.78/js/index.js
用户 ID 字段仍需真实账号响应确认，不从 Cookie 或昵称生成替代值。上传流程使用服务端返回的 OSS 签名与回调，未引入第三方 SDK。

## rclone（MIT）

- 来源：https://github.com/rclone/rclone
- 核对版本：`9751d168bcb5266063738ca964711eae71fe2caa`
- 范围：只参考百度、115、123 和国际网盘驱动的接口行为与错误分类，没有复制代码。
- 许可证：MIT，https://github.com/rclone/rclone/blob/master/COPYING

## 官方网盘接口

仅按各平台公开接口实现，没有复制 SDK 源码：

- 百度网盘开放平台：https://pan.baidu.com/union/doc/
- 115 开放平台：https://open.115.com/doc/
- 123 云盘开放平台：https://www.yuque.com/123pan/developer
- Microsoft Graph 文件接口：https://learn.microsoft.com/graph/api/resources/onedrive
- Google Drive API：https://developers.google.com/workspace/drive/api/reference/rest/v3
- Dropbox API：https://www.dropbox.com/developers/documentation/http/documentation

## 实验性网页网盘

这些实现只参考公开网页和开源驱动的 HTTP 行为，没有复制驱动源码。

- 天翼云盘：
  - 官方能力开放页：https://cloud.189.cn/web/open
  - OpenList `drivers/189pc` 仅用于核对个人云、家庭云、上传和会话行为，不复制 AGPL-3.0 代码：https://github.com/OpenListTeam/OpenList/tree/main/drivers/189pc
  - `suileyan/xpmibackup_sly`（MIT）仅用于核对登录跳转和会话失效行为：https://github.com/suileyan/xpmibackup_sly
- 中国移动云盘：
  - 官方网页：https://yun.139.com/w/
  - `Taizong547/YunpanTingshu`（MIT，commit `3ba2078ac7a86ca54c0d4b0975b0224b5e3cc71c`）仅用于交叉核对签名、路由和列表行为：https://github.com/Taizong547/YunpanTingshu
- 迅雷云盘：
  - 官方网页：https://pan.xunlei.com/
  - 接口行为按当前官方网页脚本核对。上传脚本确认会转入阿里云、腾讯云、华为云或火山云 SDK 分片流程；Diskit 只请求并处理 `PROVIDER_ALIYUN`。
  - 官方 SDK：https://github.com/aliyun/alibabacloud-oss-swift-sdk-v2
  - 固定版本：`0.4.0`，commit `335c1777bf3c4aa86d7212c03e515de53b192418`。
  - 许可证：Apache-2.0，副本为 `docs/licenses/Apache-2.0.txt`。
  - 使用范围：基础 `AlibabaCloudOSS` product 的 OSS multipart、STS 签名和 CRC64 校验；未引入 `AlibabaCloudOSSExtension`，未复制 SDK 源码。
  - SDK 通过 SwiftPM 解析 `swift-crypto` `3.15.1`、`swift-asn1` `1.7.4`（Apache-2.0）和 `XMLCoder` `0.18.2`（MIT）。基础 product 构建使用 Swift Crypto；XMLCoder 由上游包声明为 Extension 依赖。固定版本见 `Packages/ChinaWebDrive/Package.resolved`，XMLCoder 许可证副本为 `docs/licenses/XMLCoder-MIT.txt`。
  - 凭据去向：迅雷登录令牌只发给 `api-pan.xunlei.com`；阿里云临时 Access Key 只允许发往 `*.aliyuncs.com` HTTPS endpoint，不会附到迅雷 CDN 下载请求。
- PikPak：
  - 官方登录与网页入口：https://mypikpak.com/
  - 网页 API 域名为 https://user.mypikpak.com 和 https://api-drive.mypikpak.com。实现未复制第三方驱动代码。
  - rclone 的 PikPak 驱动（MIT）仅用于核对接口行为，未复制代码：https://github.com/rclone/rclone/tree/master/backend/pikpak
- 蓝奏云：
  - 公开分享入口：https://pan.lanzoui.com/
  - OpenList 与 AList 的蓝奏云驱动仅用于核对分享页、密码参数、分页和下载行为，不复制 AGPL-3.0 代码：https://github.com/OpenListTeam/OpenList/tree/main/drivers

## 相机

相机扩展只使用 macOS 的 ImageCaptureCore、IOKit 和 Foundation。PTP 字段布局继续参考 AOSP `frameworks/av/media/mtp`（Apache-2.0）；没有引入第三方相机库。
