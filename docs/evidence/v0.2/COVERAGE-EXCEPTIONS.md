# 覆盖率系统边界例外审查

依据 OPTIMIZATION §13.1，只排除直接调用系统 API、物理行数不超过 150、没有业务解析与判断的薄封装。路径在 scripts/coverage.py 精确列出；超过 150 行会使命令失败。测试辅助 target 不属于交付业务代码。

## ADB / SystemUSBMonitor.swift

- 路径：Packages/ADB/Sources/ADB/SystemUSBMonitor.swift，69 行。
- 已全文核对：仅创建 IOKit 通知端口、注册固定 ADB 接口匹配、消费/释放系统迭代器、把系统返回码交给既有映射器、转发变化回调和释放句柄。条件语句仅保护系统句柄所有权、处理注册返回码；没有设备身份、协议解析、发现代次或用户可见状态决策。
- 发现生命周期、过期回调抑制、设备列表更新和用户错误分类仍在 USBDiscovery.swift，保留在覆盖率统计并通过假发现源测试。
- 本轮覆盖数据：原始 1916/2453（78.11%）；只排除此系统边界后 1916/2371（80.81%）。最终以完整 make coverage 输出为准。
- 真实 IOKit 注册、设备插拔、系统权限错误留在 ACCEPTANCE 真机验收；本轮没有扫描 USB。

## 相机候选未采用

NativeCameraSession 与 ImageCaptureDeviceAccess 初次提案虽小于 150 行，但仍含文件索引、目录转换和会话状态判断，因此未加入例外。随后保留这些业务逻辑在可注入适配器中，以假 hardware 覆盖目录、句柄、读删失败和会话生命周期。CameraUSB 原始覆盖 703/896（78.46%，28 项通过）；RicohGR 原始覆盖 745/888（83.90%，35 项通过）。新 ICC 转发层仍计入分母，没有相机文件被排除。证据：/tmp/diskit-camera-coverage-final.log、/tmp/diskit-ricoh-coverage-refined.log；最终以完整 make coverage 输出为准。
