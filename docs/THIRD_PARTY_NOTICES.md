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
