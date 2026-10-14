# GitDesk

使用 Swift 和 AppKit 构建的 macOS 原生 Git 桌面客户端。

[![CI](https://github.com/Mitse1n/git-desktop/actions/workflows/ci.yml/badge.svg)](https://github.com/Mitse1n/git-desktop/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-orange)

[English](README.md) · 简体中文

在一个原生窗口里浏览提交历史、管理分支、选择文件提交和查看差异。交互参考 IntelliJ IDEA 的 Git 工具，底层调用系统 Git，内嵌终端使用 SwiftTerm。

**项目状态：早期开发。** 目前按下述步骤从源码构建。生成的应用使用本机 ad-hoc 签名，尚未进行 Developer ID 签名和公证。

![GitDesk 提交历史、分支树、提交图和文件详情](docs/gitdesk-log.png)

*截图来自较早的开发版本，使用演示仓库；当前界面已有调整。*

## 功能

- **内嵌 Terminal：**真实 VT100/xterm PTY，支持多个会话、仓库工作目录、ANSI 颜色、Unicode、窗口缩放、复制粘贴、Ctrl-C 和 shell 历史。Git Console 保留为独立的命令日志。
- **GitHub / GitLab：**原生 PR/MR 列表、分页与本地筛选、描述、文件差异、本地完整 Diff、检出、创建/草稿、普通及行评论、讨论回复/解决、指定审核人、批准/请求修改、关闭/重开、合并/squash（GitHub 还支持 rebase）、CI 状态及 gist/项目 snippet 分享。支持 GitHub Enterprise 和自托管 GitLab，操作遵守服务端权限和分支保护。

- **主题**：支持 Island Dark、Island Light、Light、Dark。在 GitDesk → Settings…（⌘,）→ Appearance 或 View → Theme 中切换，所有窗口即时更新并记住选择；Island 主题仅保留工具窗口外框圆角，内部面板使用平直布局和细分隔线。

- **历史**：说明/作者/日期列之间可拖动调整宽度、提交行圆角悬浮高亮、被截断的说明/作者/日期悬浮展开（窗口内换行，超高时以 `...` 结尾）、分支点线同色、按完整祖先关系排列轨道（旧分支超出日志加载范围也保持正确）、连线接到提交点中心的彩色提交图、IDEA 风格紧凑轨道与逐行说明缩进（跨越 30 行及以上的长连线折叠为两端箭头，可在 Log 视图选项中切换 Long Edges）、分支和标签标记、当前分支专用图标、本地及 origin 的 main/master 默认收藏置顶、消息/哈希搜索、正则与大小写选项、分支/作者/日期/路径筛选、first-parent 模式。
- **历史操作**：撤销最新提交、修改最新或较早提交说明、父子提交跳转、补丁导出和只读历史文件树。原生交互式 rebase 编辑器支持排序、Pick、Reword、Squash、Fixup 和 Drop。
- **分支**：分支树可上下及左右滚动，悬浮行显示灰底，被裁切的长名称浮层完整展开（在窗口内换行、超高时截断）；本地/远程分支和标签分组、收藏、切换、新建、重命名、删除、比较、merge、rebase 和 worktree。分支设置独立控制目录分组、标签显示，以及单击时筛选日志或跳到分支头。 顶部分支选择器使用 IDEA 风格的搜索弹窗，整合更新/提交/推送快捷操作、本地/远程分支树、上游名称、当前分支及收藏图标、目录分组、可选标签与键盘导航。
- **视图选项**：Log、分支、历史文件列表及 Commit 使用各自的菜单。Log 可切换紧凑引用、标签名称、引用位置、作者/日期列和高亮；历史文件可按目录/模块分组（Control-P/Control-M），显示或隐藏提交详情及文件数量。右侧栏上方为文件树、下方为紧凑的提交详情；双击文件或按 ⌘D 打开差异窗口。显示选项会保存，切换 Log 外观保留所选提交。
- **工具窗口**：Reviews 使用仓库标题页签、上方搜索、可移除的状态/作者/标签/受理人/审查/排序筛选、空状态恢复与滚动加载；单击选择，Enter 或双击打开详情。从左侧工具栏打开 Commit 和 Pull/Merge Requests。Commit 左侧为变更树与提交区，右侧为 Diff；Reviews 左侧切换请求列表与请求摘要/文件，右侧显示概览、文件差异、时间线和检查结果。Git 位于工具栏第一位，Terminal 位于底部；工具窗口使用 IntelliJ 原始 SVG，图标 20×20 点，按钮区域 40×40 点。
- **提交**：可按目录或检测到的 IDEA 模块分组的变更树；点击或空格键勾选，分组支持半选状态。消息区可拖动调整大小，支持暂存/取消暂存、变更预览、amend、消息历史与 Commit and Push；小眼睛菜单可切换 Directory/Module 分组、显示忽略文件（忽略项不能勾选提交；右键可复制路径或在 Finder 中显示，差异、暂存、取消暂存及回滚禁用），模块分组读取 IDEA 模块配置，无配置时按仓库分组；提交设置支持指定作者及 Sign-off。普通选择文件提交通过临时 index 保留其他文件的暂存状态。
- **差异**：双栏和 Unified、内置 JetBrains Mono Regular/Italic 编辑器字体、多语言语法着色（保留跨行注释/字符串状态）、行内变化强调和按完整变化块绘制的连续连接。双栏按各自真实行排列、联动滚动，行号固定，长行可横向滚动；新增/删除整份文件使用全宽单侧视图。XML 标签/字符串、Markdown 标题符号/斜体文字分别着色。忽略空白及搜索（⌘F）收进齿轮选项。文件列表支持 ⌘/Shift 多选，多文件差异可通过下拉菜单切换；代码行支持多选、⌘C 复制右侧及右键复制左右版本。F7/Shift-F7 导航差异，搜索逐次定位匹配，支持忽略空白。
- **远程**：clone、fetch、仅 fast-forward 的 pull、push 和 remote 管理，复用已有 Git/SSH/credential helper 认证配置。

- **仓库工具**：初始化和打开仓库、最近仓库、仓库级身份配置、stash、文本冲突处理、cherry-pick、revert、reset、继续/中止操作。

日志首次加载 2,000 条提交，滚动接近底部时继续加载更早的记录，筛选和搜索结果也支持继续加载，到达匹配历史的末尾后停止。刷新保留已加载深度，切换筛选条件后重新加载首批。历史刷新按提交哈希保留多选；分支栏星标用于收藏/取消收藏所选分支，定位按钮跳到该分支的最新提交。Amend 从 HEAD 读取说明，不受日志筛选影响，取消时恢复原草稿。Commit 预览支持前后文件切换，忽略空白选项在切换文件和布局后继续生效。

<details>
<summary>查看提交和差异截图</summary>

![GitDesk 提交面板](docs/gitdesk-commit.png)

![GitDesk 双栏差异](docs/gitdesk-diff.png)

</details>

## 环境要求

- macOS 14 Sonoma 或更新版本。
- Swift 6.0 或更新版本，通过 Xcode 或兼容的 Xcode Command Line Tools 提供。项目当前使用 Swift 5 语言模式。
- 系统 Git：`/usr/bin/git`。

如未安装 Apple 开发命令行工具，可先执行安装，再检查版本：

```sh
xcode-select --install
swift --version
git --version
```

本地验证环境为 Apple Silicon、Swift 6.1.2。构建脚本生成当前机器架构的程序，不生成通用二进制。

## 快速开始

```sh
git clone https://github.com/Mitse1n/git-desktop.git
cd git-desktop
swift run GitDesk /absolute/path/to/your/repository
```

不传路径时恢复上次打开的仓库，也可以通过 **File → Open Repository…**（`⌘O`）选择仓库。

打包为可双击运行的应用：

```sh
./scripts/build-app.sh
open dist/GitDesk.app
```

`dist/` 和 `.build/` 是本地产物，不包含在源码仓库中。调试包使用 `./scripts/build-app.sh debug`。ad-hoc 签名不等于公证签名，将应用复制到其他机器后，macOS 可能显示安全提示。

## 演示仓库

```sh
./scripts/create-demo.sh
swift run GitDesk /tmp/gitdesk-demo
```

演示数据包含分支、merge、标签和未提交变更。目标目录已存在时不覆盖，也可以给脚本传入其他目标路径。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| `⌘N` | 新建空白窗口 |
| `⌘O` | 在当前窗口打开仓库 |
| `⌘K` | Commit 面板 |
| `⇧⌘K` | Push |
| `⌘T` | Pull |
| `⌘R` | 刷新 |
| `⌘L` | 搜索消息/哈希 |
| `⌘F` | 跳转到 Hash / Branch / Tag |
| `⌘D` | 打开 Diff |
| `⌥⌘N` | 新建分支 |
| `⌘1` / `⌘2` | Log / Console |
| `⌘3` / `⌘4` | Terminal / Reviews |

打开仓库或选择最近项目会替换当前窗口里的项目。需要另一个独立项目窗口时，使用 **New Window**（`⌘N`）。双击提交只更新选择和详情，不弹出 Diff 窗口；可通过 **Show Diff** 或 `⌘D` 主动打开。

## 编辑提交历史

在 Log 中右键提交即可使用这些操作。**Undo Commit** 仅对当前分支最后一次提交可用，保留暂存区和工作文件，并将提交说明回填到 Commit 面板。修改最新提交说明时不会把其他已暂存文件加入提交；修改较早说明通过 rebase 编辑器完成。

编辑器按从旧到新的顺序列出所选提交直到 HEAD。用 **Move Up / Move Down** 调整顺序，选择 Pick、Reword、Squash、Fixup 或 Drop。Squash/Fixup 合并到前一个保留的条目；说明框可编辑 Reword 或自定义 Squash 说明，Squash 留空时自动合并原说明。无效计划会提示修正并保留编辑内容。

Rebase 要求工作区干净，最多编辑 10,000 条提交，暂不支持含 merge 提交的区间。冲突暂停后，顶部提供 **Resolve Conflicts / Continue / Skip / Abort**；解决并暂存文件后再继续。消息文件保存在当前工作树的 Git 目录中，重启应用后仍可继续暂停的操作。受影响提交可从本地远程跟踪引用到达时会显示历史重写提示；此检查不自动 fetch，也未接入托管平台的分支保护规则。应用不执行强制推送。

普通和根提交可导出保留作者、说明的 Git 格式补丁，merge 提交导出相对第一父提交的二进制兼容差异。历史文件树无需 checkout；预览只读，单文件限 2 MB，不跟随符号链接或进入子模块。

## 托管账号与终端

打开 **左侧工具栏 → Pull/Merge Requests → Options → Account → Connect / Replace Token…**，选择 GitHub/GitLab、HTTPS 服务地址，输入个人访问令牌。应用调用 `/user` 验证账号，令牌仅保存在 macOS 钥匙串。GitHub 私有仓库通常需要 Pull requests 读写、Contents 读、Issues 读写；查看 CI 可能需要 Checks 读权限。草稿和讨论线程通过 GraphQL 操作，细粒度令牌可能不支持所有 GraphQL/gist 功能，界面会显示服务端返回的权限错误。GitLab 使用 `api` 范围令牌，审批功能取决于服务端版本和项目策略。

选择远端、状态和 PR/MR 后，可以查看详情；双击变更文件或点 **Show Diff** 打开完整本地 Diff，在代码行右键选择评论。查看差异只 fetch 引用，不切换当前分支。**Check Out** 使用独立 review 分支，不覆盖已有工作。**Review…** 提供草稿切换、编辑标题/描述、指定审核人等操作；**Account…** 可分享代码片段或移除令牌。

Git 传输仍使用系统 Git 的凭据助手或 SSH agent，与托管 API 令牌分开。**File → Clone Repository** 也使用系统 Git 认证。**Terminal** 在仓库目录启动配置的登录 shell，切换页面或仓库会保留会话，关闭窗口会终止对应终端会话。终端命令具有当前用户的正常权限。

## 开发与检查

```sh
swift build
./scripts/test.sh
./scripts/build-app.sh
codesign --verify --deep --strict dist/GitDesk.app
```

`scripts/test.sh` 使用独立临时仓库、本地 bare remote、模拟托管 HTTP 响应及真实本地 PTY 运行回归检查，无需 XCTest；检查不连接网络远程，也不操作已有项目。首次构建会下载锁定版本的 Swift 包。请使用该脚本而非 `swift test`：检查以 executable target 实现。

GitHub Actions 会在 Apple Silicon 和 Intel macOS 上执行检查和应用打包。CI 包用于开发验证，架构与运行环境一致，未经公证。

| 路径 | 说明 |
| --- | --- |
| `Sources/GitDesk/` | AppKit 窗口、控制器、菜单、主题、Diff 与冲突界面 |
| `Sources/GitDeskCore/` | Git 进程、输出解析、模型、提交图和文本差异计算 |
| `Tests/GitDeskCoreTests/` | 回归检查程序 `GitDeskChecks` |
| `scripts/` | 打包、图标渲染、检查和演示仓库生成 |
| `docs/` | 截图与[验证记录](docs/verification.md) |

## 当前限制

- 按整个文件提交，尚未支持按行/hunk 暂存、changelist/shelf、子模块/LFS 专用管理、签名验证、图片 Diff 和托管平台账户集成。
- 文本冲突编辑适用于 UTF-8；二进制冲突可使用 Accept Ours / Accept Theirs。
- Diff 预览限制为合计 2 MB 和 20,000 行，单文件读取也限制为 2 MB。Git 子进程最长运行 120 秒。
- Git 无交互式终端输入，远程操作前需配置认证；失败原因显示在界面/Console。未提供强制 push。
- Console 仅保留最近约 200,000 个 UTF-16 单元的文本，单条命令输出预览在 20,000 个单元处截断；应用读取的 Git 结果不受影响。
- 本项目独立开发，与 JetBrains、IntelliJ IDEA 无隶属关系。

## 参与与支持

欢迎缺陷报告、改进、文档和回归用例，中英文均可。

- 提交 PR 前请阅读[贡献指南](CONTRIBUTING.md)。
- 通过 [GitHub Issues](https://github.com/Mitse1n/git-desktop/issues) 报告问题或讨论建议。
- 敏感问题处理见 [SECURITY.md](SECURITY.md)。
- 项目变更见 [CHANGELOG.md](CHANGELOG.md)。

## 许可

项目源码和原创文档采用 [MIT 许可](LICENSE)。第三方产品名称和参考截图的权利归各自所有者，详见 [NOTICE.md](NOTICE.md)。
