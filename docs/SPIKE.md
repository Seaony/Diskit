# M7 第一步：FSKit 验证

日期：2026-11-11。环境：macOS 27.2（26B123）、Xcode 27.2（27B52），付费团队 `JJJKGPY7T7`。

验证代码：

- 扩展 `FSExtension/`（`KayoiFS.appex`，bundle ID `com.seaony.Kayoi.FS`）：内存假数据卷，根目录有 `readme.txt`、`big.bin`（1 GiB，内容按偏移现算，不占内存）和 `Folder/inside.txt`。所有新建、删除、改名、设属性、设扩展属性的操作都写日志（subsystem `com.seaony.Kayoi.FS`，category `spike`）。
- 主 App 验证入口 `App/FSKitSpike.swift`：只有带 `--fskit-spike` 参数启动时才运行，跑完就退出，不进入正常界面。子命令有 `seed`（写 App Group 文件和共享钥匙串条目）、`status`（列出系统里的 FSKit 扩展和是否启用）、`mount <URL>`、`unmount <路径>`、`usbcheck`（在主 App 里跑和扩展相同的 USB 握手检查）、`settings`（打开系统设置的扩展页）。
- 签名：`project.yml` 改为自动签名加 `DEVELOPMENT_TEAM`。`make build` 带 `-allowProvisioningUpdates`，Xcode 会自动注册 App ID、生成描述文件。

## 结论汇总

| # | 项目 | 结论 |
| --- | --- | --- |
| 1 | 系统识别扩展、系统设置里能打开开关 | 通过 |
| 2 | 不需要管理员密码挂载 / 推出 | 通过（macOS 27 用 `FSClient`；macOS 26 用 `mount -F`） |
| 3 | 扩展读到 App Group 和共享钥匙串 | 读写通过；§7 一次性迁移**未验证**，原因见下文 |
| 4 | 扩展进程内通过 IOUSBHost 连安卓并握手 | 通过（需要加一条沙盒 IOKit 例外权限） |
| 5 | 扩展进程内用 ImageCaptureCore 看 GR IV | 未测（没有相机） |
| 6 | Finder 产生的 `._*` / `.DS_Store`，覆盖层方案 | 可行，并且找到了更简单的做法 |
| 7 | 1 GiB 读吞吐和 CPU | 冷读约 5 GB/s，扩展每 GiB 用 0.25 秒 CPU |

## 1. 系统识别扩展

- 签名后，扩展和主 App 的描述文件（Mac Team Provisioning Profile）都授权了 `com.apple.developer.fskit.fsmodule` 和 `com.apple.developer.fskit.mount`，在开发者后台不用手动开能力。
- 执行 `lsregister -f` 后，`pluginkit -m -i com.seaony.Kayoi.FS` 能列出扩展；`FSClient.installedExtensions` 返回 `com.seaony.Kayoi.FS 已启用=false`。
- `FSClient.shared.openFileSystemExtensionsSettings()`（macOS 27）能直接打开「登录项与扩展 › 文件系统扩展」，Kayoi 出现在列表里。打开开关不需要密码，之后 `status` 显示 `已启用=true`。
- 重新编译、重新签名后，开关仍然保持打开。

## 2. 挂载与推出

| 方式 | 系统 | 需要密码 | 挂载点 | 结果 |
| --- | --- | --- | --- | --- |
| `FSClient.shared.mountSingleVolume(resource: FSGenericURLResource(url:), bundleID:options:)` | macOS 27 起，需要 `com.apple.developer.fskit.mount` | 否 | 固定在 `/Volumes/<卷名>` | 成功，耗时 0.07–0.32 秒 |
| `mount -F -t kayoi <URL> <目录>`（普通用户执行） | macOS 26 起 | 否 | 任意自己有写权限的目录 | 成功，挂载记录显示 `mounted by seaony` |

推出：`FileManager.unmountVolume(at:)`、`diskutil unmount`、Finder「推出」都成功，都不需要密码。`umount` 推出 `FSClient` 挂的卷会报 `Operation not permitted`，因为那个卷是系统守护进程挂的。

Finder 中的表现：

- 卷能在「电脑」窗口里看到，也有「推出“spike”」菜单。默认图标是网络卷图标。
- **侧栏「位置」里没有出现**（同一台机器上 OrbStack 的 NFS 卷会出现）。挂载参数是 `kayoi, nodev, nosuid, noowners, noatime, fskit`，没有 `local`。要不要以及怎么进侧栏，留到第二步再处理。
- 卷名就是 `FSVolume` 的 `volumeName`，可以自定义（验证时用的是 URL 的主机名）。
- 自定义图标可以做到：用 `NSWorkspace.setIcon(_:forFile:)` 设置后，Finder 显示了新图标。原理是在卷根目录写 `.VolumeIcon.icns`，并给根目录设 `com.apple.FinderInfo` 扩展属性。正式实现时，由扩展直接提供这两样东西即可。

## 3. App Group 与共享钥匙串

- 主 App 执行 `seed`：写入 `~/Library/Group Containers/JJJKGPY7T7.com.seaony.Kayoi/spike-check.txt`，再写入共享访问组 `JJJKGPY7T7.com.seaony.Kayoi.shared` 里的钥匙串条目（`kSecUseDataProtectionKeychain=true`）。两项都写入成功，回读一致。
- 扩展（沙盒）挂载时把两项读出来写进 `readme.txt`，内容与主 App 写入的一致。
- §7 的一次性迁移（把用户真实的配置和钥匙串条目搬到新位置、删掉旧条目）**这次没做**。原因是它会动用户的真实数据，属于第二步的正式实现，不该放在验证代码里。这次只证明了新位置在两端都能读写。迁移流程本身还没验证：读旧配置和旧钥匙串条目、换成付费团队签名后读旧条目会不会弹窗、写入成功后删旧条目、失败时保留旧数据，这几步都还没跑过。

## 4. 扩展进程内连 USB 安卓

测试手机：Xiaomi 17，USB 连接。

- 扩展已经链接 ADB 包。挂载 `kayoi-adb://usbcheck` 时，扩展会在后台枚举 ADB 接口，直接调一次 `IOServiceOpen` 记下返回码，然后用 `USBTransport` 加 `ADBSession` 握手，结果写进卷里的 `usb-check.txt`。主 App 用 `--fskit-spike usbcheck` 能跑同一段检查，用来对比。
- 只带 `com.apple.security.device.usb` 时，扩展里 `IOServiceOpen` 返回 `0xe00002e2`（`kIOReturnNotPermitted`），握手报 EIO。内核日志：`Sandbox: KayoiFS deny(1) iokit-open-user-client AppleUSBHostFrameworkInterfaceClient`。同一时间主 App（不开沙盒）能打开这个接口，所以不是被别的进程占用了。
- 加上 `com.apple.security.temporary-exception.iokit-user-client-class` = `AppleUSBHostFrameworkInterfaceClient`、`AppleUSBHostFrameworkDeviceClient` 之后，扩展里 `IOServiceOpen` 返回 0，**握手成功**，手机报了 23 项 features。
- ADB 私钥存在共享钥匙串访问组里。主 App 第一次握手时，手机弹出授权，点了允许；之后扩展用同一把钥匙握手，手机没有再弹。说明两个进程能共用一把钥匙，手机只需要授权一次。
- 代价：`temporary-exception` 这类权限 Mac App Store 不收，但 Kayoi 走 GitHub 加 Sparkle 分发，不受影响。
- 没插手机时：扩展枚举到 0 台，不报错也不崩溃。

## 5. GR IV

未测，手边没有相机。

## 6. Finder 产生的元数据文件

**卷不支持扩展属性时**（`maximumXattrSize = 0`，没实现 `FSVolume.XattrOperations`），Finder 拷一个带扩展属性的文件夹进去，日志里能看到：

- 列目录时，Finder 会对每一项都查一次 `._<名字>`（`lookup miss ._readme.txt`、`._big.bin`、`._Folder`）。
- 文件带扩展属性时，会建 `._<文件名>`（`._a b.txt`）。
- 拷文件夹时，会先建临时的 `._<文件夹名>`，拷完再删掉。
- 会写 `.DS_Store` 和 `._.DS_Store`。设自定义图标时，还会写 `.VolumeIcon.icns`、`._.VolumeIcon.icns` 和 `._.`。

**卷支持扩展属性之后**（实现了 `getXattr` / `setXattr` / `listXattrs`），重做同样的拷贝和设图标操作：**一个 `._*` 文件都没有产生**，全部变成了扩展属性调用（`com.apple.FinderInfo`、`com.apple.ResourceFork`、`com.apple.metadata:kMDItemWhereFroms`，以及拷贝过程中的 `com.apple.finder.copy.*`）。剩下的只有 `.DS_Store` 和 `.VolumeIcon.icns` 两个固定名字的文件。

结论：§3.4 的覆盖层方案可行，而且可以更简单。

1. 扩展实现扩展属性操作，属性值存在本地覆盖层，不写到远端。
2. 只需要拦截 `.DS_Store`、`.VolumeIcon.icns`（以及 PLAN 里列的 `.Spotlight-V100`、`.fseventsd`、`.Trashes`）这几个名字，它们也存在本地覆盖层。
3. 不再需要按 `._*` 前缀拦截。

另外，拷进去的中文、空格、emoji 文件名都正常；8 MB 随机文件拷进去之后，用 `cmp` 比对内容一致。

## 7. 性能基线

Debug 构建，数据在内存里，读取时从预先算好的花样里整块拷贝。

| 场景 | 结果 |
| --- | --- |
| `dd if=big.bin of=/dev/null bs=1m`，刚挂载、冷读 | 1 GiB 用 0.205–0.218 秒，约 4.9–5.2 GB/s |
| 同一个文件第二次读（命中系统缓存） | 0.065 秒，约 16.5 GB/s |
| 冷读 1 GiB 的扩展进程 CPU 时间 | 0.24–0.25 秒 |
| 冷读 1 GiB 的 `fskitd` CPU 时间 | 0.11 秒 |
| 数据正确性 | 抽查 59 个偏移（含边界和 50 个随机位置），0 错误 |

这是上限，FSKit 本身不会成为瓶颈，实际速度取决于 ADB 和网络。论坛里说的「CPU 比 macFUSE 高」，这次纯内存场景下没有观察到。

## 实现时要注意的事

- **回调不能在持锁时调用**：FSKit 会在 `createItem` 的回调里同步调回 `getAttributes`。如果持着同一把锁调用回调，扩展会死锁，Finder 一直「正在加载」，终端里的 `ls` 也会卡住。正确做法是先在锁里算好结果，释放锁之后再回调。
- **扩展崩溃或被杀时**：系统会自动推出卷，卡在这个卷上的进程会返回，不会永久卡住。
- **列目录不要自己返回 `.` 和 `..`**，系统会自动补上，自己返回会显示成两份。
- **接口版本**：`FSVolume.Operations` 这一套接口在 macOS 27 被标为过时，新的是带 `context` 的 `FSVolume.Handler`。部署目标是 26.0，只能用旧接口，它在 27 上能正常工作。
- **`FSClient` 挂载只在 macOS 27 可用**：部署目标留在 26 的话，主 App 要按系统版本分两条路，26 上用 `mount -F`。
- **纯资源包不单独签名**：SwiftPM 的纯资源包（`Core_Core.bundle` 等）放进扩展后不会被单独签名，但已经封在外层签名里，`codesign --verify --deep --strict` 能通过。所以 `make build` 改用整体验证。
