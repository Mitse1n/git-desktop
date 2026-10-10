# 调查与验证记录

验证日期：2026-10-08。本机 macOS / Apple Silicon，Swift 6.1.2 Command Line Tools。

## IDEA 参考

通过 Computer Use 查看了本机已打开的 IntelliJ IDEA，以及自己创建的 `/tmp/gitdesk-demo` 测试仓库。用户原有项目仅用于查看界面，没有执行 Git 写操作。

- 用户截图中的空仓库 Log：Git / Log / Console 标题、分支搜索、本地分支树、消息/哈希搜索、Branch / User / Date 筛选、右侧文件变化和详情。
- 测试仓库中的 Log：包含 merge 的提交图、分支/标签标记、作者和日期列、选中提交的详情、按目录分组的文件变化。
- 分支菜单：Checkout、创建分支、Compare、与工作区比较、Rebase、Merge、Worktree、Push、重命名和删除。
- Commit 面板：工作区变化、文件勾选、提交消息、Amend 与 Diff。
- 双击修改文件后的 Diff：左右版本、行号、变化背景、差异导航与空白选项。

原始参考截图：[idea-reference.png](idea-reference.png)。IDEA Diff 实际截图：[idea-diff.png](idea-diff.png)。

## 原生应用验证

在打包的 `dist/GitDesk.app` 中通过 Computer Use 验证了：

- 打开仓库、Log 三栏布局、分支文件夹、提交图、提交详情和目录变化树。
- 消息搜索、分支菜单和新建分支窗口。
- 新建 `test/ui-verification` 分支，仅勾选 `Sources/Repository.swift` 创建提交；其他未跟踪文件仍保留在工作区。
- 单击提交读取详情，以及双击提交/文件打开 Diff。
- Side-by-side / Unified 切换、忽略空白选项、Commit 面板内文件预览。
- 窗口与嵌入面板的 Diff 列宽适配；Commit 消息占位文字与深色复选框文字。

所有实际提交操作都在自行创建的测试仓库内完成。仓库初始数据和作者信息为测试数据。

最终界面截图：

![Log](gitdesk-log.png)

![Commit](gitdesk-commit.png)

![Diff](gitdesk-diff.png)

## 自动检查

### Commit Message 输入修复

后续实际输入检查发现，消息框中的 `NSTextView` 未配置滚动容器内的尺寸跟踪，宽度为零，导致边框和占位文字可见，但点击不能获得焦点。已为文本滚动容器统一配置宽度跟踪、纵向扩展与最小视口高度，并显式启用消息编辑、选择和撤销。

修复后的 release 应用已通过 Computer Use 实际验证：点击消息框获得焦点，键盘英文输入、换行、中文粘贴、撤销和刷新保留消息。测试文字已清除，没有执行提交。截图：[gitdesk-message-input.png](gitdesk-message-input.png)。

`scripts/test.sh` 的结果为 **22 scenarios, 0 failures**。检查使用临时仓库和本地 bare remote，无真实网络远程操作。

覆盖初始提交、选择文件提交、失败后的 index 保留、amend、特殊文件名与路径、符号链接、预览大小限制、重命名、暂存区/工作区 Diff、历史筛选、分支与标签 checkout、stash、本地 push/fetch/pull、冲突与中止、merge 父提交、rebase、worktree、cherry-pick、revert、reset、rollback、提交图与文本差异算法。完整结果见 [regression-results.txt](regression-results.txt)。

`scripts/build-app.sh` 的 release 构建成功；`codesign --verify --deep --strict dist/GitDesk.app` 验证通过。打包应用约 1 MB，使用本机 ad-hoc 签名，尚未做 Developer ID 签名或公证。

## 复刻范围

2026-10-10 Log 视觉调整：依据用户提供的两张对比截图，改为扁平描边搜索框（文本搜索的正则与大小写按钮在框内）、单箭头筛选按钮、按视口分配消息列宽、完整日期时间、当前 Git 身份作者加粗、无底色的描边引用标签、矩形低饱和选中效果、直线提交图和 HEAD 空心环。分支改为收藏优先再按名称排序，main/master 默认收藏；刷新保留折叠状态并取消初次自动选中。工具栏收紧，右侧空状态居中，分隔线使用统一颜色。Release 构建及签名检查通过。用户在授权界面启用 GitDesk 后，Computer Use 仍返回 `Computer Use was not approved to use GitDesk`，刷新工具会话后结果相同；此版未通过实际界面验收，以上描述为代码实现，不能视为像素一致性已验证。

2026-10-10 标题栏调整：通过 IDEA 实际项目菜单对照，确认 `gitdesk-demo` 为绿色 GD、`git-view` 为青色 GV，并查看了项目颜色开关和自定义 SVG 图标对话框（已取消，未保存设置）。GitDesk 标题栏已改为同一行的原生窗口按钮、仓库下拉和分支下拉；字母按仓库名称生成，颜色按规范化仓库路径稳定生成，仓库菜单也使用相同标识。颜色分配算法未与 JetBrains 内部算法核对，自定义 SVG 图标功能此次未实现。Release 构建通过；此次界面验收因 Computer Use 尚未获准访问 GitDesk 而待完成。

### 2026-10-10 后续实际界面验收

Computer Use 已恢复访问 GitDesk。上述“待完成”描述记录的是此前授权受阻时的状态；本次已在最新打包应用中完成以下实际检查，并再次查看 IDEA 的测试仓库界面：

- 标题栏改用原生 `NSTitlebarAccessoryViewController`，修复窗口标题栏覆盖按钮点击区域的问题；补充原生紧凑工具栏，修复顶部控件被裁切。仓库按钮中央点击可打开菜单，分支按钮也可打开操作菜单。
- 最近仓库按规范化路径去重，避免 `/tmp` 与 `/private/tmp` 出现重复条目。仓库字母和颜色随仓库生成。
- 分支搜索输入 `feature` 可正确过滤；清空后恢复目录树，刷新保留折叠状态。修复搜索后的横向偏移，根节点文字完整可见。
- Log 搜索输入 `hello` 后从 9 条过滤为 1 条，清空后恢复 9 条。搜索框编辑时文字与静态显示位置一致。
- 按 IDEA 对照补充当前分支可达提交的淡靛色背景、独立的选中效果、HEAD 洋红色空心环、青色主线与紫色支线；过滤时保留历史图颜色。
- 引用名称采用紧凑描边标签，多引用使用叠放图标。分支树使用原生绘制的分支图标，收藏优先排序；日期显示完整时间，当前 Git 身份作者加粗。
- Commit 消息框可输入英文、换行与粘贴中文，刷新后保留草稿。验收文字已清除，没有执行提交或其他 Git 写操作。
- 连续选择不同提交时详情正确更新，正文保持常规字重，标题加粗。

最新 release 构建成功，`codesign --verify --deep --strict dist/GitDesk.app` 验证通过。本轮修改集中于界面，未重新执行此前的 22 项核心回归场景。

核心布局、深色配色、信息结构与常用 Git 操作按实际 IDEA 界面实现。没有进行像素差异自动验收，也未达到 IDEA 所有高级功能的完整等价。macOS 系统字体和 SF Symbols 与 JetBrains 的字体、图标存在差别。功能边界及预览限制见 [中文 README](../README.zh-CN.md#当前限制)。

## 2026-10-10 开源整理检查

- 环境：Apple Silicon、Swift 6.1.2。
- 再次执行 `./scripts/test.sh`：**22 scenarios, 0 failures**。
- `./scripts/build-app.sh` Release 打包成功，`codesign --verify --deep --strict dist/GitDesk.app` 通过。
- 补充中英文 README、MIT 许可、第三方说明、贡献指南、安全说明、变更记录及 Issue/PR 模板。
- GitHub Actions 配置 Apple Silicon / Intel macOS 回归检查和打包；本地检查不代表远程 CI 已通过。
- README 截图来自 2026-10-08 的演示仓库验证，不代表最新版本的像素验收。
