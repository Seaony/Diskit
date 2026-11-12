# 当前批量修改交接快照（非最终验收）

本快照来自实施交接；其中定向测试只覆盖交接所注明的代码时点，后续改动未据此标为通过。统一验收尚未执行。文件行号以交接时点为准。

# K-05 公共客户端与 Google 桌面回调

## 已修改

- OAuthConfiguration 初始化时，usesPKCE=true 必定清空 clientSecret，防止调用者误配置后在授权码交换或刷新中携带静态 secret。
- AppModel 和 DevTool 的 OneDrive/Google/Dropbox 都使用空 secret 和 PKCE；project.yml 不再把三家 *_CLIENT_SECRET 写入 Info.plist。App/Validation/示例 xcconfig 删除无效项，没有读取真实 Config/Secrets.xcconfig。
- GoogleDesktopOAuth 从合法 Google client ID 派生 `com.googleusercontent.apps.IDENTIFIER:/oauth2redirect/google`。旧任意 `diskit://oauth/google` 不再使用，移除 GOOGLE_REDIRECT_URI 配置。非法/缺失clientID返回空回调，配置校验不通过。
- WebAuthorization 原有 ASWebAuthenticationSession 已从真实 redirect_uri 提取 callbackURLScheme，因此无需端口监听或额外 URL handler。OAuthCallback 继续精确校验 scheme/host/port/path/state，重复code/state不接受。
- README 更新真实配置要求；不新增依赖、不使用真实账号。

## 官方与相似开源证据

1. Google 当前文档标题为 OAuth 2.0 for Desktop Apps，Step 2 的 redirect_uri values 表给出含点反向域名 custom scheme 和单斜杠路径；交换与刷新参数表均将 client_secret 标为可选。
   https://developers.google.com/identity/protocols/oauth2/native-app
2. OpenID AppAuth 官方示例 `Examples/README-Google.md` 的 **macOS** 专节明确允许 loopback 或自定义 scheme，给出反向 Google client ID + `/oauth2redirect/google` 的精确形式。本实现选这一明确 macOS 示例，而非从移动平台示例推测。
   https://github.com/openid/AppAuth-iOS/blob/master/Examples/README-Google.md
3. Microsoft 授权码文档“Redeem a code”规定 native/public 客户端不能使用 secret；refresh 同样不应在 native app 使用 secret。
   https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow
4. Dropbox OAuth 文档 PKCE 一节面向不能保密 secret 的桌面/移动应用，要求使用动态verifier/challenge；Public clients 开关需平台配置。
   https://docs.dropboxapi.com/dropbox-api/docs/oauth
5. Apple ASWebAuthenticationSession 文档说明回调只交付给调用应用的认证会话，即便多个App登记同一scheme；现有流程直接指定派生callbackURLScheme并在回调后验证state。
   https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession

## DECISIONS 应追加的决定

- 支持PKCE的这三家作为公共客户端，不打包/发送静态 secret，不将混淆或钥匙串安装配置当成能保护发布二进制秘密的方案。
- 阿里、百度、115、123 当前采用的授权契约仍保留原 client secret 配置；未确认它们可无secret的官方PKCE契约，不擅自删字段破坏授权。桌面应用无法保密 secret，二进制内的值应视为可被提取，只能作为平台要求的客户端标识辅助，不能作为安全边界。发布前必须核对提供方允许桌面分发此类凭据的政策、最小scope及密钥轮换。
- Google 用已获官方macOS开源示例明确支持的反向clientID scheme，不引入随机端口监听；不能据本地参数测试声称某个真实OAuth注册已经兼容。

## 待用户账号验收

- 三家均用公共/原生客户端配置进行一次授权，再触发过期刷新；确认平台不要求secret。
- Google使用可用于macOS的OAuth客户端，核对实际反向clientID回调，授权页成功返回App；旧diskit回调不可继续依赖。
- OneDrive原生/公共客户端及Dropbox public clients设置需后台启用；本轮未登录控制台，未读取实际clientID或secret。
- 在最终构建后的Info.plist只检查三家secret键不存在；不要打印任何其他平台的secret值。

## 登录错误整合

- 按root新增LoginRequiredFailure协议，OAuthDriveError仅loginRequired要求重新登录；配置缺失、暂时不可用、非法响应、用户拒绝授权均不强制重登录。
- 新增 onlyExplicitOAuthLoginFailureRequiresReauthentication；该补充在前述3用例快检之后写入，未为此重复运行，留最终统一验证。
