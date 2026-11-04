let cliHelp = """
  kayoi-dev — Kayoi 开发工具
    devices                            列出安卓与 USB 相机
    pair <host:port> <配对码>            无线配对
    ls [-a] <连接ID> <路径>              列目录
    stat <连接ID> <路径>                 文件信息
    get <连接ID> <远端> <本地>            下载文件或目录
    put <连接ID> <本地> <远端>            上传文件或目录
    mkdir <连接ID> <路径>                新建目录
    rm [-r] <连接ID> <路径>              删除
    mv <连接ID> <源> <目标>              移动或改名
    df <连接ID>                         容量
    cat [--range <起>-<止>] <连接ID> <路径>  输出文件，范围含两端

    -- 结束选项解析；选项也可放在连接 ID 后。
    get 拒绝覆盖已有目标；失败会清理临时下载。
    配置取自环境变量；仅 KAYOI_SECRETS_FILE 显式指定时读取配置文件。
  """
