# UI-PANEL-06：只有已发现位置时不显示大空态

修前现象已在主任务对话的 Computer Use 工具输出中观察：只有五条已发现位置时仍出现大空态插图。原截图文件已被修后截图覆盖，当前路径不作为修前图证据。

原因：PanelView 只用已保存列表是否为空控制大空态和紧凑添加行，忽略已发现列表。

改动：复用现有 `PanelCopy` 增加一个纯布尔判断 `showsEmptyState(savedCount:discoveredCount:)`；仅两个列表同时为空才显示大空态。发现列表非空、保存列表为空时保留全部发现行，底部显示紧凑添加行，且不渲染空的「我的位置」标题。其它分组、拖动与添加操作未改。

先写 `PanelEmptyStateTests.swift` 的针对性用例，提取旧条件后用当前 Core 对象文件只链接 PanelCopy、SpaceSummary 与本地检查程序：

- 修前退出 1：`FAIL: 只有已发现位置时仍显示大空态`。
- 修后退出 0：`PASS: 四种列表组合正确区分大空态与紧凑添加行`。
- 四组合为 `(已保存, 已发现) = (0,0)、(0,5)、(1,0)、(1,5)`。
- `swiftc -frontend -parse` 和范围 `git diff --check` 通过；没有完整测试、应用构建、启动或提交。

主任务集中构建后，已用 Debug 演示模式经 Computer Use 复核浅色与深色：五条发现行和紧凑添加入口均完整显示在首屏，没有大空态插图。

修后截图（已覆盖此前同名文件）：

- `docs/screenshots/v0.2/UI-PANEL-04-discovered-light-zh.png`
- `docs/screenshots/v0.2/UI-PANEL-04-discovered-dark-zh.png`

结论：该独立界面缺陷已通过主任务实际目检；完整最终门禁仍待统一完成。本次仅更新证据，未额外构建、测试或提交。
