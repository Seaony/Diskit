# FIX-10 公开官网客户端核对

仅下载无需登录的 HTML 与静态 JavaScript；没有调用网盘数据 API，没有载入账号、Cookie 或授权值。以下保留地址、摘要和定位点，不归档整份第三方代码。

## 迅雷请求封装
来源：[迅雷请求封装](https://static-pan.xunlei.com/_nuxt/dist/client/utils-initial.ddef3a9e719ae0793f69.js)
SHA-256：`ec49d5cdd8c7404bf6448896fedbd54f7b3eb8f2d7104f94b0567798ae2fc7b1`；大小：162534 字节。
- 定位文本 `files:batchDelete`，UTF-8 字节偏移 4922。
- 定位文本 `/trash`，UTF-8 字节偏移 5696。
- 定位文本 `trashFile`，UTF-8 字节偏移 13632。

## 迅雷页面动作
来源：[迅雷页面动作](https://static-pan.xunlei.com/_nuxt/dist/client/app.bcd8b551a8b324712ac6.js)
SHA-256：`b374e661290c8b937914686fbede93ec0688def6f417284373891df8c6f603b0`；大小：574189 字节。
- 定位文本 `批量彻底删除`，UTF-8 字节偏移 384742。
- 定位文本 `batchTrashFile`，UTF-8 字节偏移 386600。

## 移动云盘路由适配
来源：[移动云盘路由适配](https://yun.139.com/w/static/js/app.56b4a805.js)
SHA-256：`400dacc3a6a6040428f54cb3b23914f3c715cf94223e47e3d2cf0655e370131f`；大小：688070 字节。
- 定位文本 `201==t`，UTF-8 字节偏移 109191。
- 定位文本 `202==t`，UTF-8 字节偏移 109346。
- 定位文本 `/recyclebin/batchTrash`，UTF-8 字节偏移 132405。
- 定位文本 `/file/batchDelete`，UTF-8 字节偏移 132321。

## 移动云盘普通文件页面
来源：[移动云盘普通文件页面](https://yun.139.com/w/static/js/chunk-3eea94b2.4c2811e0.js)
SHA-256：`ec82d02ec5caffa36857a874458878e1641c49386186f412065bf49a5db61020`；大小：391933 字节。
- 定位文本 `删除后可在回收站找回已删除文件`，UTF-8 字节偏移 88668。
- 定位文本 `u.actionType=4==this.moduleType||5==this.moduleType?201`，UTF-8 字节偏移 89109。

## 移动云盘回收站页面
来源：[移动云盘回收站页面](https://yun.139.com/w/static/js/chunk-a8410ad6.277c4689.js)
SHA-256：`95fb94f2de4d74d6564a4d5695c7c2da2ed1a8adf684459a6f35e38727774698`；大小：52608 字节。
- 定位文本 `永久删除`，UTF-8 字节偏移 14453。
- 定位文本 `actionType:202`，UTF-8 字节偏移 25093。

## 结论

- 迅雷官网分别提供回收站请求和永久批量删除：普通回收站动作调用 PATCH files/{id}/trash，空对象正文；永久删除使用 files:batchDelete。
- 移动官网普通文件删除提示可恢复，使用动作 201；回收站的永久删除使用动作 202。适配层分别将其映射到 recyclebin/batchTrash 和 file/batchDelete，正文均为 fileIds 数组。不能仅凭 logicalDelete 这个变量名推断安全性。
- AList 自身驱动源码提供独立交叉核对：[迅雷](https://github.com/AlistGo/alist/blob/main/drivers/thunder/driver.go)、[移动个人云](https://github.com/AlistGo/alist/blob/main/drivers/139/driver.go)。最终修改以官网页面动作与请求封装的对应关系为依据。
- 这些证据确认客户端选择的接口，不代替真实服务端的回收站、恢复与保留期限验收。
