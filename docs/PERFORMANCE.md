# 演示性能测量

仅使用签名后的稳定 Release，启动时设置 `KAYOI_DEMO=1`。先完成构建，再测量；测量期间不运行构建、测试或其他采样工具。输出目录须提前存在。

## 软件绘制就绪

显式设置 `KAYOI_PERF_OUTPUT=/绝对路径/launch.json` 启用探针；缺少演示标志、缺少路径或相对路径均不启用，也不写文件。

```sh
KAYOI_DEMO=1 KAYOI_PANEL_WINDOW=1 KAYOI_PERF_OUTPUT="$PWD/build/Validation/launch.json" build/DerivedData/Build/Products/Release/Kayoi.app/Contents/MacOS/Kayoi
```

- `processStartTick` 来自内核 `proc_pid_rusage(RUSAGE_INFO_V2).ri_proc_start_abstime`，事件使用 `mach_absolute_time()`；通过系统 `mach_timebase_info` 转换毫秒。起点包含进程初始化，非视图初始化或探针创建时间。
- `menu_software_draw_ready` 是菜单栏标签背景视图第一次执行 `draw`、返回到主队列且窗口仍可见的时间。每进程只记一次。
- `panel_open_request` 在调用主面板 `openWindow` 前记录；`panel_software_draw_ready` 在面板背景视图完成绘制且窗口可见后记录。一条请求最多匹配一条就绪事件；重新打开会产生新的一对事件。
- 没有可见绘制事件就没有就绪样本，不使用 `NSWindow` 初始化、`onAppear` 或预设耗时填补缺失值。主队列繁忙会计入就绪耗时。
- 这些是**软件绘制完成**事件，不是 WindowServer 合成、显示器扫描输出或物理点击。主面板的显式打开请求也不能替代真实菜单栏图标点击。PERF-01 的真实点击到显示仍须 Computer Use 实际点击并核查；工具无法定位时列入用户验收。
- 记录器是普通对象，不更新 SwiftUI 状态、不轮询、不强制重绘。编码与原子文件写入在后台串行队列执行。

## CPU 与常驻内存

应用稳定后取得其准确 PID；脚本只读指定 PID，不启动应用、不操作界面、不连接设备或账号。样本保留原始单调时间、累计 CPU 秒数和 RSS 字节。

```sh
python3 scripts/sample-process.py --pid 12345 --seconds 300 --interval 1 --output build/Validation/perf-panel-closed.json
```

分别在面板保持关闭、面板保持打开时测 300 秒；长驻留测试把 `--seconds` 改为 `1800`。CPU 使用累计 CPU 增量除以实际单调时间间隔，100% 表示一个 CPU 核，不使用 `ps %cpu` 的平滑值。RSS 来自 `ps rss` 的 KiB 转字节；它不是物理内存占用 footprint，也不含子进程。计时分辨率和外部采样开销必须保留在解释中。

打开关闭 50 次的测量：先稳定应用，开始采样；由 Computer Use 实际完成 50 次面板/添加窗口的打开与关闭，记下动作时间和计数；结束前回到起始窗口状态并等待同样的稳定时间。对比原始样本中稳定起止窗口的 RSS，也保留脚本的首末差值和峰值。不能只测一次打开后乘以 50，不能把未执行的动作写成已完成。若指定采样时长不足以完成动作，应重新选择足够时长。

脚本遇到进程退出或手动中断会保存已有样本并以失败状态退出。只有同一存活进程完整完成规定时间的记录，才能用于阈值验收；采样期间不要重启应用。
