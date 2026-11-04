# 类型卡片副标题内边距

独立布局问题：修前英文图 `type-picker-before/keyboard-light-en.png` 中 Android 的“USB or wireless debugging”贴到左右边框。源码 `ConnectionTypeTile` 的 VStack 直接铺满卡片宽度，没有横向 padding，与该现象一致。

修复仅在内容 VStack 增加 `Space.sm`（8pt）横向内边距，保持卡片 96pt 高、四列、40pt 图标、单行副标题和完整 help 文案不变。未调整字体或窗口尺寸，未新增词条。

局部语法与差异检查通过，待主任务重截图检查英文长副标题在真实窗口的截断与边距；此项与焦点修复分别记录，未提交。
