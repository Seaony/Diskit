# 审计交接与保留理由

下文旧行号和阶段覆盖率只属当时；最终结果以FINAL证据为准。Camera候选豁免已退回，最终不豁免相机文件。

# 相机审计交接（待统一编译测试）

- 两包 CameraIdentity.swift:4,10：非零 USB location 生成 usb:<UInt32>；否则非空 uuid/persistentID；精确 id 优先，旧 serial 仅非空且唯一才命中。无序列号及重复序列号不任选设备。换 USB 口会改变 location 身份，重新发现选择；旧唯一 serial 配置可跨口。
- CameraUSBDiscovery.swift:49,119,151 / RicohDiscovery.swift:65,87：明确 GR IV 名称路由专用，通用排除相同集合；RicohProvider.swift:15 保留 make(serial:) 并新增 make(identifier:)。
- CameraUSBProvider.swift:6,145 / RicohProvider.swift:6,108：删除能力在会话快照后刷新，断开清除；remove 用当前能力，锁定后不可删除。RicohCameraAdapter 新增 canDelete，兼容默认 true，真实adapter按锁定状态及IC能力返回。
- CameraUSBProvider.swift:187 / RicohProvider.swift:136：拒绝重复路径、文件占父目录、重复/零文件handle，不能覆盖字典后误读/误删另一文件。
- RicohErrors.swift:6、RicohProvider.swift:99、ImageCaptureAdapter.swift:190,217：保留POSIX、取消、IC超时/缺文件/权限等错误，不再所有删除错误归EACCES或读错误全归EIO。
- ImageCaptureAccess.swift:88 / ImageCaptureAdapter.swift:74：再次打开时恢复发现浏览器；provider假adapter覆盖 connect/disconnect/connect。物理拔插后的旧ICCameraDevice不会被假装恢复，App须重新factory，真机待验。
- 两个 discovery 新增 issue enum/property，start清空；仅实际可观察的枚举失败写 failed，没有伪造平台权限检测。

## 不改理由与真机边界

1. 官方 GR IV FAQ https://www.ricoh-imaging.co.jp/english/support/qa/gr-4/ 写 Image Capture 名称为 RICOH GR。显示名无法区分III/IV。含糊 RICOH GR保留通用相机支持，只有明确IV名字进入专用，打开专用仍PTP确认真实型号。待用户真机记录 USB productID/设备显示名/PTP model，才能安全扩展白名单；不能称全部GR IV已自动专用识别。
2. 通用容量继续返回未知（前一代理已改可选字段），不猜容量，不把零冒充真实值。待真机确认哪些机型允许标准PTP容量查询，当前通用不保证PTP能力。
3. 不可表示的目录名（空、路径分隔、dot）、重复路径/handle继续明确失败，不跳过条目制造不完整目录。损坏对象需要真机查看IC原始类型和名称；本次加强歧义保护，未声称可显示全部异常对象。
4. 理光每次snapshot重建目录仍保留：没有真机证据证明所有外部拍摄/删除均可靠回调，缓存可能返回已删除对象甚至导致错误操作。容量也需实时读取；性能优化须先测大目录时间与事件完整性。不是功能缺失修复声明。
5. 15秒目录deadline保留统一设备请求预算，禁止无界等待；大卡首次枚举是否足够待真机。已有deadline用例的80/140ms短sleep已转交device_timeouts做TEST02。
6. Apple usbLocationID接口参考 https://developer.apple.com/documentation/imagecapturecore/icdevice/usblocationid 。未连接真实硬件。

## 回归与命令

新增每包 IdentityTests: cameraIdentityRejectsAmbiguousSerialAndSupportsMissingSerial、cameraGRIVBoundaryExcludesOtherModels。
Camera ProviderTests: cameraDeletionCapabilityRefreshesAfterOpen、cameraDuplicatePathsCannotSelectAnotherFile、cameraProviderReconnectsWithoutReusingOpenState。
Ricoh ProviderTests: ricohDeletionPreservesCancellationAndMissingFile、ricohDuplicatePathsCannotSelectAnotherFile、ricohProviderReconnectsWithoutReusingOpenState。
原ricohRejectedDeletionReturnsPermissionErrorAndKeepsFile改用真正POSIX EACCES，未知错误不得假称权限问题。

执行 git diff --check -- Packages/CameraUSB Packages/RicohGR：exit0。
执行两包源码及测试 xcrun swiftc -frontend -parse：exit0（添加最后两个重连用例前；用例同现有语法）。
未运行测试：root明确要求共享Core整合完成再统一跑，避免重复编译失败。未提交/构建/真实设备操作。

统一编译已发现 usbLocationID 的 SDK 类型为 Int32；两发现器均改用 UInt32(bitPattern:) 保留完整位模式后生成标识。按父代理要求未重跑编译。

# TEST-03 覆盖率追加

本轮已重构而非排除旧长文件：CameraCatalog.swift 纯值目录解析覆盖75/75；ImageCaptureAccess.swift注入CameraDeviceSession覆盖51/54；CameraUSBDiscovery注入启动/停止/截止等待覆盖120/186；CameraUSBErrors 50/50。新CatalogTests覆盖层级、重复名/handle、非法名称/存储、能力切换、读删失败、取消映射、关闭后拒绝操作。DiscoveryTests新增无设备的幂等启动/增删发布/超时issue恢复。

swift test --package-path Packages/CameraUSB --enable-code-coverage，退出0，26 tests通过；输出/tmp/kayoi-camera-coverage.log。读取 .build/out/Products/Debug/codecov/CameraUSB.json：raw 550/836=65.79%；仅剔除NativeCameraSession.swift（0/168 LLVM可执行行，格式化115物理行）后550/668=82.34%。候选是原生ICC属性、值投影、delegate、callback桥接；所有目录名/句柄安全判断、会话状态/错误业务移入可测代码。豁免由root最终审定，尚未修改coverage脚本。其余文件未豁免。

## 最终替代上轮豁免方案

主代理退回NativeCameraSession豁免后，已把它改为可注入CameraHardware/CameraHardwareItem，新增NativeSessionTests覆盖原始对象递归类型判定、日期/空目录缺省值、文件索引ENOENT、删除成功后移除索引、原生错误与nil正文、删除失败回调、ready成功与removed失败/available状态。NativeCameraSession计153/155覆盖，不再申请豁免。
真正ICC属性/系统call/delegate转接为 Packages/CameraUSB/Sources/CameraUSB/ICCCameraHardware.swift（swift-format后85物理行，LLVM0/72）。协议定义CameraHardware.swift无可执行行。

最终命令 swift test --package-path Packages/CameraUSB --enable-code-coverage，退出0，28tests通过。日志 /tmp/kayoi-camera-coverage-final.log。
最终raw703/896=78.46%，已经超过75%门槛，不需要豁免！仅如root批准ICCCameraHardware薄桥接，则703/824=85.32%。推荐直接使用raw指标。此前65.79/82.34数字已被本轮替代。
git diff --check -- Packages/CameraUSB 退出0。未真实设备、未改覆盖脚本、未提交。
