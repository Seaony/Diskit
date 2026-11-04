# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# 115/123 审计处理记录

## 已修改

- 115：Drive115Provider.swift:43 每次spaceInfo重新读取userInfo；:54 起枚举完成后才更新ID缓存，:96 标记同名歧义，:405 resolve通过父目录枚举确认唯一身份，getInfo核对返回ID，遇重名报EEXIST而不操作任意同名文件。短页依赖总数继续枚举，不能仅因未满1150停止。列表仍返回全部同名行，没有静默丢弃。
- 115/123：同目录改名分别在Drive115Provider.swift:248、Drive123Provider.swift:222跳过多余move请求。
- 115：Drive115OSSSigner（同文件:746）按bucket构造虚拟主机地址，HTTPS优先且无明文回退；裸endpoint补HTTPS，已有bucket主机不再重复添加。临时凭据接口返回endpoint为上传端点来源。对象名保留重复斜杠，V1签名使用原始对象名和排序子资源，实际URL单次编码。callback及callback-var按OSS要求base64编码，仍用CryptoKit HMAC实现，不新增密码学代码或依赖。
- 115：:414 checkUploadResult拒绝203和XML错误，即便200也不会把CallbackFailed XML当成功；JSON回调明确业务失败同样抛错。分片读取验证精确长度，防止截断文件进入空循环；新建分片ID拒绝空值。
- 123：:168 分片响应通过统一业务解码，不再忽略非零code；读取分片要求等于期望字节数，服务器地址必须HTTPS。:174 使用HTTPProgressDeadline包围整个完成轮询，真实经过60秒无完成进展就取消在途请求；false状态不是进展，不因每次轮询响应而延长。原completionPollLimit参数保留调用兼容，但现在表示秒数，默认取RemoteTimeout.transferIdle。

## 本地证据

- docs/evidence/v0.2/CURRENT-115123-quick.log：一次定向快检exit0，16项函数通过。筛选drive115|drive123|sameDirectoryRenameDoesNotIssueMove，未跑全包或make门禁。
- 新测试文件 Packages/CloudDrive/Tests/CloudDriveTests/Drive115123AuditTests.swift：重名（:42）、容量（:67）、仅改名（:86）、回调失败（:114）、分片结果（:146）、签名及URL（:178）、callback编码（:197）、跨短页重名（:219）。
- 追加的慢完成轮询取消测试（:262 drive123CompletionDeadlineCancelsSlowPollRequest）未在此次快检中执行，留最终统一验证。
- 原OfficialDriveProvidersTests仅在115删除夹具前新增父目录枚举响应；未改百度、国际网盘及upload计数内容。

## 来源及边界

1. 阿里OSS官方V1签名规则：https://www.alibabacloud.com/help/en/oss/include-signatures-in-the-authorization-header
2. 阿里官方Go SDK CanonicalizedResource 原始对象与子资源序列规则：https://raw.githubusercontent.com/aliyun/aliyun-oss-go-sdk/master/oss/conn.go （getSubResource/getResource）；HMAC实现对照 https://raw.githubusercontent.com/aliyun/aliyun-oss-go-sdk/master/oss/auth.go 。固定测试签名预期由Python标准库HMAC独立算出，不由被测Swift代码生成。
3. 阿里官方域名规则：https://www.alibabacloud.com/help/en/oss/user-guide/access-oss-via-bucket-domain-name 。没有把自定义endpoint默认当成CNAME；115当前响应无CNAME标记，参考OpenList的115上传实现同样以token.Endpoint创建OSS客户端并选择init.Bucket：https://raw.githubusercontent.com/OpenListTeam/OpenList/main/drivers/115_open/upload.go 。这只是实现对照，真实115端点及证书兼容仍需账号验收。
4. 阿里203回调失败定义：https://www.alibabacloud.com/help/en/oss/upload-callbacks-6 。203可能对象已保存、业务回调失败，本地报错不自动删除原对象，用户应在官网检查上传结果后决定重试。
5. 123官网 www.123pan.com/developer 重定向yun.123pan.cn/developer，其公开脚本 https://statics.123pan.com/static-by-custom/member-prod/p__OpenPlatform__index.28a64775.async.js 明确将“开发文档”链接到 https://123yunpan.yuque.com/org-wiki-123yunpan-muaork/cr6ced 。官方目录列上传V2分片 scs8yg89yz8immus、完成 fzzc5o8gok517720，但本次公开HTML未取得文档正文，因此不声称核对了所有真实接口返回字段。改动沿用现有code/data/completed契约，仅停止忽略失败并按PLAN无进展时限处理。

真实验收待用户：115临时OSS端点/回调签名与回调失败显示；重名目录不应删除错误对象；两平台同目录改名；123服务端处理大文件超过60秒但无进度字段时的可用性。无真实网络账号/设备/API访问，无Secrets读取，无提交。
