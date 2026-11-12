# 国内组出图与验收记录

- 服务：aliyunDrive、quark、baiduDrive、drive115、drive123、ucDrive、tianyiDrive。
- 生成方式：每张一次内置 image_gen，7次调用，0次重生。每次附 prompts/folder-peek.png 画法参考，并请求透明背景；每批至多两张并行。
- 原始输出：7张都是1254×1254 RGBA，原始路径保留在 research-china/source-paths.json。没有覆盖或删除生成原文件。
- 最终候选：使用根控提供的 /tmp/kayoi-device-size.py，仅按alpha≥32的主体边界等比缩放、居中到1024×1024；全部最大边819px，约79.98%；未清除alpha、未改颜色或内容。
- 透明检查：对每张实际alpha_composite合成白底和深灰底，检查200px与64/32/24px；7张轮廓清楚，没有可见底板、文字、数字、背景影子、彩边或浮点。直接预览RGBA时可见的彩点来自低alpha RGB，实际合成不可见，因此未消耗重生次数。
- 验收图：research-china/china-alpha-check.png。最终尺寸与alpha统计：research-china/final-stats.json。
- 造型：阿里盘轨道陀螺、夸克放大镜、百度三叶指尖陀螺、115帆船、123三阶储存积木、UC松鼠抱橡果、天翼上传风筝；没有云与文件夹模板，没有与设备造型混用。
- 最弱项：115生活、123云盘。两家官方主标均依赖数字，在禁止文字数字的前提下，本版保留品牌蓝色与曲线/三段几何节奏，品牌直接辨识度比其他五家弱。形状之间仍清楚区分，暂不建议为此重生；应由用户评审候选物件方向。
- UC在24px时脸部与橡果细节合并，但橙色松鼠与大卷尾的轮廓仍可辨认。
- 未操作GUI/Dia/Debug，未改App代码、Assets或仓库文件，未提交、未推送。

