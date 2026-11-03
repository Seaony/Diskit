# 验收记录

日期：2026-11-03。环境：macOS 26.5.2（25F84）、Xcode 26.6（17F113）、Swift 6.3.3、XcodeGen 2.46.0。
只记录实际运行的结果；界面与外部设备不由单元测试替代。

## M0 工程骨架

| 标准 | 结果 | 证据 |
| --- | --- | --- |
| 新克隆执行 make gen / make test / make release | 通过 | 新克隆 `/tmp/kayoi-m0-clone.Ki0yAJ` 执行 `make gen && make test && make release`，退出码 0；测试 2/2 通过，Release `BUILD SUCCEEDED`，签名校验通过 |
| Release 签名与 Info.plist | 通过 | `codesign --verify --deep --strict --verbose=2`：`valid on disk`、`satisfies its Designated Requirement`；PlistBuddy：LSMinimumSystemVersion=`26.0`、LSUIElement=`true` |
| kayoi-dev --help 全部子命令 | 通过 | devices、pair、ls、stat、get、put、mkdir、rm、mv、df、cat --range 均列出；M0 执行具体命令返回未实现与非零退出码 |
| StorageLocation / SecretStore 写读删覆盖 | 通过 | `make test`：`Test run with 2 tests in 0 suites passed`；配置使用临时目录，密钥使用真实登录钥匙串随机 service 并清理 |

签名身份为指定的 Apple Development 证书。App 为 arm64 + x86_64，开发工具为本机架构。未启用沙盒、App Group、共享钥匙串、FSKit 或 Developer ID。

## M1 菜单栏与 SMB

停止于实现前的接口核查；8 条功能验收均未执行，未提交 M1 实现。

PLAN.md §6.3 指定 `/usr/bin/smbutil view -A //user@host` 用于列共享，但实际参数不支持该目标：

```text
$ /usr/bin/smbutil help view
usage: smbutil view [connection options] //[domain;][user[:password]@]server
where options are:
    -A    authorize only
```

Apple 源码 `smbutil/view.c`：104–106 行把 `-A` 解析为 `kSMBOptionSessionOnly`；151–154 行在该模式认证成功后直接跳到函数末尾；共享枚举调用在 157 行，因此不会执行。
来源：https://github.com/apple-oss-distributions/smb/blob/main/smbutil/view.c

建议只修订 §6.3 的列共享命令，移除 `-A`；密码仍通过交互输入，不进命令行参数，挂载仍使用 NetFSMountURLAsync。此修订尚未执行，等待用户决定。没有 Windows 账号，未声称完成远端实测。

## M2 安卓 USB

未开始。8 条验收尚未执行。

## M3 安卓 Wi-Fi

未开始。6 条验收尚未执行。

## M4 GR IV USB

未开始。3 条验收尚未执行。

## M5 阿里云盘

未开始。5 条验收尚未执行。

## M6 夸克

未开始。3 条验收尚未执行。

## 待用户验证

M0 无待用户验证项。当前首先需要用户决定是否修订 §6.3 的命令；M1–M6 尚未实现，不要求用户提前操作设备或登录账号。

## 未做与方案差异

M7、M8 按要求不做。当前没有修改 PLAN.md，没有引入除 XcodeGen 以外的第三方依赖。M1–M6 因上述方案冲突未继续实现。未运行 UI 自动化、快照测试或真机验收；未使用 Jev。

## M0 命令输出摘录

主目录 `make test`（退出码 0）：

```text
Test configurationLifecycle() passed after 0.001 seconds.
Test loginKeychainLifecycle() passed after 0.044 seconds.
Test run with 2 tests in 0 suites passed after 0.044 seconds.
```

新克隆 `make gen && make test && make release`（退出码 0）：

```text
Created project at /tmp/kayoi-m0-clone.Ki0yAJ/Kayoi.xcodeproj
Test configurationLifecycle() passed after 0.002 seconds.
Test loginKeychainLifecycle() passed after 0.041 seconds.
Test run with 2 tests in 0 suites passed after 0.041 seconds.
** BUILD SUCCEEDED **
Kayoi.app: valid on disk
Kayoi.app: satisfies its Designated Requirement
```

`PlistBuddy` 读取实际产物：`LSMinimumSystemVersion = 26.0`，`LSUIElement = true`。
`codesign -dv --verbose=2`：`Identifier=com.seaony.Kayoi`，`Format=app bundle with Mach-O universal (x86_64 arm64)`，`Authority=Apple Development: seaony@outlook.com (ZB4G2AWAU9)`。

核对 diff：仅 M0 工程、包空壳、存储与测试、构建说明及验收记录；PLAN.md 原文原样纳入首次提交。未实现 M7/M8、未增加本期之外的产品行为。
