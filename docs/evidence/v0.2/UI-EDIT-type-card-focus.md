# 类型卡片继承网格焦点导致全部描边

修前图已另存 `type-picker-before/keyboard-light-en.png` 与 `keyboard-dark-en.png`，避免后续重截图覆盖证据。主任务复现路径为英文搜索 `smb` → 全选替换 `no-such-type` → 全选删除 → Down → Right；实际仅 Camera USB 选中，但每张卡片都有粗焦点边框。

根因：`ConnectionCardStyle` 读取 `@Environment(\.isFocused)`。ScrollView 网格取得键盘焦点后，该环境值由子卡片继承，因而所有卡片都走 focused 描边；此前移除容器系统焦点效果不能影响这个自定义样式判断。

修复：卡片样式改为显式 focused 参数；Picker 只将「网格有焦点且当前卡片为 selectedKind」的判断传入。保留网格方向键、Return、搜索框焦点和选中样式，没有增加新导航行为。

针对性检查：先提取原网格焦点规则写 `ConnectionTypeFocusTests.swift`，局部程序链接当前 Core 对象文件，不启动 App、不做 UI 自动化。

- 修前退出 1：`FAIL: 网格焦点使29个类型卡片同时高亮`。
- 修后退出 0：`PASS: 仅选中卡片跟随网格焦点；搜索框焦点和无选择均不高亮卡片`。
- 新用例还按现有搜索重置与移动选择逻辑断言 Down→Right 最终选择 Camera USB。
- 调用文件语法及范围差异检查通过；没有全套测试、应用构建或提交。

待主任务集中构建后重走英文复现路径，检查浅深色每次仅一个实际选中格子显示强调描边；新截图不能沿用修前结果。
