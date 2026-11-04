import Core

struct WebDAVPreset: Identifiable {
  let id: String
  let title: String
  let address: String
  let instructions: String

  static var all: [WebDAVPreset] {
    [
      .init(
        id: "custom", title: L("自定义"), address: "", instructions: L("向服务提供商确认完整 WebDAV 地址和登录方式。")),
      .init(
        id: "jianguoyun", title: L("坚果云"), address: "https://dav.jianguoyun.com/dav/",
        instructions: L("在坚果云账号的安全设置中创建应用密码，用户名填写账号邮箱。")),
      .init(
        id: "nextcloud", title: "Nextcloud",
        address: "https://nas.local/remote.php/dav/files/USERNAME/",
        instructions: L("在个人设置的安全页面创建应用密码，并从文件页面复制 WebDAV 地址。")),
      .init(
        id: "owncloud", title: "ownCloud",
        address: "https://nas.local/remote.php/dav/files/USERNAME/",
        instructions: L("在个人设置中创建应用密码，并复制服务器提供的 WebDAV 地址。")),
      .init(
        id: "synology", title: L("群晖"), address: "https://nas.local:5006/",
        instructions: L("在 NAS 上启用 WebDAV Server 的 HTTPS 服务，并允许此账户访问目标共享。")),
      .init(
        id: "qnap", title: L("威联通"), address: "https://nas.local/dav/",
        instructions: L("在 NAS 上开启 WebDAV，并使用实际配置的端口与共享路径。")),
      .init(
        id: "openlist", title: "OpenList / AList", address: "https://nas.local/dav/",
        instructions: L("使用站点的 WebDAV 地址和账户，确保账户拥有相应存储权限。")),
    ]
  }
}
