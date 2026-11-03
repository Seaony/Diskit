# 第三方来源

## BoringSSL

- 来源：https://boringssl.googlesource.com/boringssl
- 固定版本：`629a0ef2e705964bde48ff804ea286a1fd677169`
- 许可证原文：`Packages/ADB/Vendor/BoringSSL/LICENSE`
- 文件清单：同目录 `gen/sources.json`，编译清单 `SOURCES.txt`。
- 只选取 crypto/bcm 的 C/C++ 源码、依赖头文件及生成文件；禁用汇编以统一 arm64/x86_64 构建。未构建 SSL/TLS 实现。
- 调用范围：经用户批准，用于 Android 公钥编码的大整数运算；后续无线配对还会使用 SPAKE2。RSA 私钥生成、签名仍使用 Security，TLS 仍使用 Network.framework。

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
