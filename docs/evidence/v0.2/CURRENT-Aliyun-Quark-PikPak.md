# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 阿里 / 夸克 / PikPak 剩余审计交付

本组仅内存凭据、假传输、临时文件；没有真实账号/设备/API、全量构建或提交。所有代码仍为工作区改动，最终统一验收由主任务执行。

## 阿里

- AliyunProvider.swift:12、302–339：变更代数与每目录进行中列表ID，晚于删除/重命名或新列表的回包报EAGAIN而不写旧缓存。stat/getDownloadLink也检查代数；connect开始即置未连接并清缓存，避免切换根期间拿旧根查询。
- AliyunProvider.swift:216：mkdir已有文件或目录均EEXIST，根目录既有特殊空操作不变；写入、删除、建目录用defer清理变更后的缓存，失败也不保留可能失真的旧目录。
- AliyunProvider.swift:369：异步元数据任务整轮30秒截止，计时包住单次慢poll而不只是while外看时钟；超时映射ETIMEDOUT并取消底层等待。
- AliyunOAuth.swift:111：复用Core LimitedHTTPTransport（凭据存储命名空间+键的共享额度），删除重复无限等待队列与流游标，upload显式分支保留。requiresLogin仅loginRequired=true。
- AliyunFiles.swift:22、45：复用Core RemoteTimestamp，删除每条文件/链接新建ISO formatter的重复实现。
- 审计“阿里未读流占额度”：保留正在持有的下载占额度是限制并发的预期。旧游标已有deinit归还；新公共游标相同语义，新增丢弃回归证明第五个请求能继续，不能称原来永久泄漏。
- 审计“每次范围重取链接”：阿里原本已有expiresAt缓存。新增重复range用例证明两次range只取一次getDownloadUrl，没有无依据改写。
- 验证：docs/evidence/v0.2/CURRENT-aliyun-audit-focused.log 5测试通过（mkdir两分支、删后晚列表、新旧列表、登录语义、未读流丢弃）；docs/evidence/v0.2/CURRENT-aliyun-limit-focused.log 3测试通过（跨会话额度、流结束、流丢弃）；docs/evidence/v0.2/CURRENT-aliyun-task-focused.log 2测试通过（范围复用、慢poll取消）。最后仅将connect进入时清除旧driveID/cache，未重复跑；最终全量验收需包含它。

## 夸克 / UC

详单 /tmp/kayoi-quark-audit.md；14定向测试通过 docs/evidence/v0.2/CURRENT-quark-audit-focused.log，另新增pending状态0/1→2、目标最终名冲突两个测试尚未运行，留统一验收。

- QuarkProvider.swift:11、359：代数+目录列表ID，修改/断开后旧回包不回填；按fid/size/updatedAt缓存下载URL，401/403重取，改变/断开清理。
- :118、134：format_type依据远端目标文件名；CryptoKit分块摘要移后台，取消继续传递。
- :226：已存在目录报EEXIST；total=0空目录原本已支持，不成立的原审计断言予以纠正；total>0不一致空页仅重新从第一页读一次，仍矛盾报错而非漏行。
- :245、310、312：删除/移动拿task_id后等待成功，失败与超时不伪报成功。
- :270–299：跨目录改名遇目标原名冲突，用临时名避免误冲突，再按fid改最终名；失败尝试恢复原位置/原名，恢复失败QuarkMoveRecoveryError保留原错误和恢复错误及临时名，绝不报告成功。
- QuarkSession.swift:240–293：拒绝登录不删除Cookie记录，5xx/429不因正文/Set-Cookie误判登录；requiresLogin只有loginRequired为true。
- 依据是公开客户端适配实现，未获官方登录态业务脚本：Cp0204/quark-auto-save（task_id/retry_index/status2）及 alist-org/alist quark_uc driver（移动、改名分离）。不把第三方来源写成官方协议验证；UC任务语义、临时改名恢复、Cookie续期需真实账号验收。

## PikPak

- PikPakProvider.swift:13、341：目录变更代数/请求ID阻止晚回包；:468自定义根保留parent ID；:151摘要后台与取消；:221 mkdir已存在报EEXIST。
- :116：只有带可靠expire信息的下载URL缓存，401/403重取一次，元数据变化及断开清除。无有效期不猜TTL。
- :409：任务轮询无进展60秒，progress只有超过历史最大值才续期；没有progress、重复、倒退和慢请求均受截止时间约束。
- PikPakSession.swift:27、306、367：captcha按action/device/user/username隔离，过期淘汰，上限64；反复拒绝独立captchaRequired，不再改报密码错或登录失效。
- PikPakModels.swift:113、162、211：下载链接有效期、公共时间解析、可选任务progress。
- 两项原审计不贸然修改：当前rclone主仓PikPak适配也使用固定https://mypikpak.com/ S3兼容入口，并说明move时服务端对冲突原名自动加序号、随后按fileID改名。现请求顺序与其一致；补了模拟自动改名回归，不凭字段名把AWS4请求发到可能不同协议的endpoint，不额外增加临时重命名写操作。来源 https://raw.githubusercontent.com/rclone/rclone/master/backend/pikpak/pikpak.go（S3 newS3Client/Move）和api/types.go（任务progress、链接expire）；真实服务兼容仍待账号验收。
- 验证：6审计用例 docs/evidence/v0.2/CURRENT-pikpak-audit-focused.log 通过；范围+任务截止2用例（2+5分支） docs/evidence/v0.2/CURRENT-pikpak-deadline-focused.log 通过。合并证据 docs/evidence/v0.2/AUDIT-PikPak-focused.log。
- 0字节上传、sendSigned误删AWS4签名由upload_paths任务修复，本组保留其改动，不重复计功。

## 主任务需整合的文案

- PikPak 验证未通过，请稍后重试
- 移动失败，恢复原位置也未完成。请刷新目录，检查临时文件“%@”。

需要加入中英catalog；本组没有修改共享catalog。
