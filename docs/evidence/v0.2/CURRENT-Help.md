# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 帮助窗口改动交接

- UI-HELP-01：App/HelpView.swift:23 的 NavigationSplitView，27种可选择类型（WebDAV合并），按设备/局域网共享/网盘/实验性网盘/对象存储五组；侧栏使用TypeIcon 24pt。App/HelpGuideDetail.swift提供准备步骤、FAQ、能力表。
- UI-HELP-02：删除构建配置/应用凭据等开发者说明；展示真实版本限制、相机条件删除、蓝奏只读、云盘权限/账号限制。全部界面文案使用L，未改catalog，新增词条在/tmp/help-new-strings.md。
- UI-HELP-03：搜索覆盖类型名称、别名、准备步骤和FAQ；选择通过SceneStorage保存，搜索无结果使用系统空态；View只有640×480最小尺寸，没有固定宽高，窗口scene由panel_settings_design处理。
- 逻辑测试：Tests/DiskitTests/HelpGuideTests.swift三项覆盖类型完整性、只读/条件能力、搜索。测试尚未运行。
- 快检：帮助模型Swift6类型检查通过（docs/evidence/v0.2/CURRENT-help-typecheck.log），帮助View连同实际TypeIcon、Space、DiskitTheme和ConnectionPresentation的Swift6类型检查通过（docs/evidence/v0.2/CURRENT-help-ui-typecheck.log）；最终小改后的语法parse及范围diff check通过。
- 尝试单独类型检查Testing测试时缺少TestingMacros插件，这不是执行失败；不将它算测试通过，最终由DiskitTests统一运行。
- 待统一验收：浅深色、中英文/伪语言、640×480与大窗口、键盘侧栏选择/搜索/FAQ、VoiceOver及增强对比度。未启动应用、未截图、未提交。
