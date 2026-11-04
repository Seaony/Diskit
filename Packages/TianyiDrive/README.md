# TianyiDrive

天翼云盘个人云 / 家庭云实验包，实现 `RemoteFileProvider`。网页接口没有面向个人用户的公开 OAuth App，客户端使用用户在网页登录后取得的 SSON Cookie 换取网页会话，再把会话和 Cookie 保存到 `SecretStore`。

## 已验证依据

- 官方能力开放页：<https://cloud.189.cn/web/open>
- 官方页面说明的是能力开放，不提供本包可用的个人 OAuth 应用凭据。
- OpenList `drivers/189pc` 公开的 HTTP 行为用于核对个人云和家庭云的会话字段、根目录、分页、下载、上传、目录操作和批量任务参数。只参考行为，没有复制 AGPL 源码。
- `suileyan/xpmibackup_sly`（MIT）的公开实现用于核对 SSON 登录跳转、会话换取以及会话失效表现。只参考 HTTP 行为。
- 上传接口公开行为显示可使用 `initMultiUpload`、`getMultiUploadUrls`、分片 PUT 和 `commitMultiUploadFile`；本包按每次 10 MiB 起步分片，片数过多时增大分片。

接口核对日期：2026-11-04。这是非官方网页接口，可能随时变化。

## 核对到的 HTTP 行为

- 登录跳转：`GET https://cloud.189.cn/api/portal/unifyLoginForPC.action`，随后在网页登录完成地址携带 SSON Cookie。
- 会话换取：`POST https://api.cloud.189.cn/getSessionForPC.action`，响应含个人云 `sessionKey` / `sessionSecret`、家庭云 `familySessionKey` / `familySessionSecret`、`accessToken` 和 `refreshToken`。
- 空间信息：`GET https://api.cloud.189.cn/portal/getUserSizeInfo.action`。
- 个人云分页：`GET https://api.cloud.189.cn/file/listFiles.action`，根目录 `folderId=-11`，分页使用 `pageNum`、`pageSize`，响应为 `fileListAO.fileList` 和 `fileListAO.folderList`。
- 家庭云选择：`GET https://api.cloud.189.cn/family/manage/getFamilyList.action`，使用 `familySessionKey` / `familySessionSecret` 签名，响应 `familyInfoResp` 提供 `familyId`。
- 家庭云分页：`GET https://api.cloud.189.cn/family/file/listFiles.action`，根目录 ID 为空，必须携带 `familyId`；个人云使用 `orderBy=filename`，家庭云使用 `orderBy=1`。
- 下载：个人云使用 `/file/getFileDownloadUrl.action` 并带 `dt=3`、`flag=1`；家庭云使用 `/family/file/getFileDownloadUrl.action` 并带 `familyId`。临时链接都使用标准 HTTP Range。
- 新建目录：个人云使用 `/file/createFolder.action` 和 `parentFolderId`；家庭云使用 `/family/file/createFolder.action`、`familyId` 和 `parentId`。
- 改名：个人云使用 POST 的 `/file/renameFile.action` 或 `/file/renameFolder.action`；家庭云使用 GET 的 `/family/file/renameFile.action` 或 `/family/file/renameFolder.action`，并携带 `familyId`。
- 移动与删除：两者都使用 `/batch/createBatchTask.action`；家庭云表单额外携带 `familyId`。公开实现随后用个人云会话检查任务状态，本包保持这一已核实行为。
- 上传：个人云使用 `https://upload.cloud.189.cn/person/*`；家庭云使用 `https://upload.cloud.189.cn/family/*`，参数额外携带 `familyId`，并使用家庭云会话签名。参数使用对应 `sessionSecret` 前 16 字节做 AES-PKCS7 加密，再用 HMAC-SHA1 签名。

证据来源：

- <https://github.com/OpenListTeam/OpenList/tree/main/drivers/189pc>
- <https://github.com/suileyan/xpmibackup_sly/blob/main/src/app/src/main/java/com/suileyan/cloud/provider/TianyiProvider.java>

## 已实现

- SSON Cookie 登录、持久化和 `189.cn` 域隔离，不向外部下载或分片上传地址发送 Cookie。
- HTTP 401、`InvalidSessionKey` 和 `InvalidAccessToken` 会使保存的登录失效并抛出 `RemoteError.unauthorized`。
- `TianyiStorageScope` 显式选择 `personal` 或 `family(familyID:)`；家庭云缺少独立凭据时返回错误，不会复用个人云会话。
- 个人云和家庭云分别实现目录分页、`stat`、短链接 Range 下载、上传、新建目录、移动、改名和删除。
- `familySpaces()` 可列出 SSO 账号可访问的家庭云，供调用方选择 `familyID`。
- 上传前检查同名，发现同名直接返回 `EEXIST`；提交参数固定为非覆盖模式。
- 分片上传使用 CryptoKit 计算 MD5/HMAC-SHA1，使用系统 CommonCrypto 做 AES-PKCS7，没有自带密码学实现。

## 限制

- 没有真实账号和真实文件验证。真实接口字段变化、风控、IP 变化和上传域限制仍需用户验收。
- 下载链接由接口临时签发。其域名和查询参数可能变化。
- Cookie 只能从网页登录结果取得，包内不包含扫码或账号密码登录流程。
