import Core
import Foundation

let commands = ["devices", "pair", "ls", "stat", "get", "put", "mkdir", "rm", "mv", "df", "cat"]
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args == ["--help"] || args == ["-h"] {
  print(
    """
    kayoi-dev — Kayoi 开发工具
    devices                         列出安卓与 GR 设备
    pair <host:port> <配对码>         无线配对
    ls <连接ID> <路径>               列目录
    stat <连接ID> <路径>             文件信息
    get <连接ID> <远端> <本地>        下载
    put <连接ID> <本地> <远端>        上传
    mkdir <连接ID> <路径>            新建目录
    rm [-r] <连接ID> <路径>          删除
    mv <连接ID> <源> <目标>          移动或改名
    df <连接ID>                     容量
    cat --range <起>-<止> <连接ID> <路径>  按范围读取
    """)
} else if commands.contains(args[0]) {
  print("未实现：\(args[0])")
  exit(1)
} else {
  fputs("未知命令，请运行 kayoi-dev --help\n", stderr)
  exit(2)
}
