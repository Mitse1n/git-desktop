# GitDesk 和 IntelliJ IDEA 性能复测方法

这套方法用于更新 GitDesk 后重复检查内存、仓库加载、刷新、搜索、提交详情和 Diff，并与同一台机器上的 IntelliJ IDEA 对照。自动工具测量 GitDesk 的真实核心及 AppKit 控制器；IDEA 的可见界面响应通过统一的人工操作和录像计时记录。两个层次分别统计，不把核心函数耗时当作鼠标点击到屏幕更新的耗时。

工具入口是 `scripts/performance/bench.py`，只需要 macOS、系统 Git、Swift 和 Python 3，无第三方 Python 包。新生成的数据均保存在本地；仓库只收录历史报告明确引用的数据及必要的复现快照。工具不会连接远程、提交业务代码或更改 IDEA 配置；生成的仓库使用测试身份。新结果目录必须不存在，避免覆盖旧结果。

## 一次完整自动测试

在项目根目录运行：

```sh
python3 scripts/performance/bench.py run \
  --fixtures /tmp/gitdesk-perf-v1 \
  --out output/performance/version-a \
  --iterations 20 --timeout 300
```

第一次会生成固定仓库并编译 Release 探针。后续复用相同的测试仓库，每个场景和模式启动独立探针进程；每项先做 1 次预热，再计入 20 次测量。编译和生成数据的时间不计入操作耗时。整套测试通常需要数分钟，以机器和系统负载为准。

加入一个真实仓库的只读测试：

```sh
python3 scripts/performance/bench.py run \
  --fixtures /tmp/gitdesk-perf-v1 \
  --out output/performance/version-a-real \
  --iterations 20 --timeout 300 \
  --real-repo /absolute/path/to/repository
```

`--real-repo` 只做查询和控制器加载，但仓库中其他程序的写入会改变结果。记录当时的 HEAD、修改数量、分支数量，以及是否存在构建/依赖安装。真实仓库不会被工具重置。

新版工具将被测可执行文件冻结到结果目录，并保存当时的 `Sources` 和 `Package.swift`。需要用新测试工具复测旧源码时，执行：

```sh
python3 scripts/performance/bench.py run \
  --fixtures /tmp/gitdesk-perf-v1 \
  --out output/performance/version-a-replayed \
  --before-sources output/performance/version-a/Sources \
  --iterations 20 --timeout 300
```

旧源码会在独立临时包中构建，不替换当前源码。比较测试工具版本变化较大的两次结果时，应使用同一套新工具重跑旧源码，不能仅忽略元数据警告。

快速复测可以加 `--scenarios small medium`。此选项只缩小历史/工作区场景；Diff 用例仍全部运行。缺少数据目录时仍生成完整固定数据集。

也可以使用 `--modes core`、`--modes ui` 或 `--modes diff` 只运行一个测量层，默认三层全部执行。`--modes diff --scenarios small` 适合只复测差分算法；场景选项此时只影响记录的数据仓库指纹。

## 固定测试数据

| 场景 | 提交数 | 普通跟踪文件 | 修改文件 | 未跟踪文件 | 特征 |
| --- | ---: | ---: | ---: | ---: | --- |
| small | 100 | 20 | 5 | 0 | 5 个额外分支引用 |
| medium | 10,000 | 1,000 | 100 | 0 | 30 个额外分支引用 |
| history100k | 100,000 | 100 | 10 | 0 | 完整祖先关系规模 |
| dirty | 1,000 | 10,000 | 2,000 | 10,000 | 大量文件状态和变更树 |
| refs1000 | 10,000 | 100 | 10 | 0 | 1,000 个额外分支引用 |
| wide200 | 11,000 | 100 | 10 | 0 | 200 条分叉，每条 5 个提交 |

每个仓库还包含一个有 1,000 行、单行修改的 `diff.txt`，因此实际跟踪文件数比表中多 1，修改数也多 1。主分支叫 `main`；分支叫 `feature/b0000` 等。提交消息、作者、时间及文件内容固定，使用打包 Git 对象。仓库没有网络 remote。

这些数据主要隔离提交数、引用数和文件数的影响。大多数历史提交不改变文件，因此它们不能代表每次提交都修改几十个文件的真实工程，也不能单独代表 IDEA 的 Java、Kotlin、Maven 或 Gradle 索引负担。正式产品结论应补充真实工程。

生成器遇到已有非测试目录会拒绝覆盖。已有测试目录根据 `.git/gitdesk-benchmark.json` 识别；如果你在其中做过切换、提交或编辑，请使用新的目录重新生成，不要把修改后的数据当作旧基线。新版工具还在结果元数据中记录文件内容和 Git 引用的指纹，比较时会提示差异。

`/tmp` 可能被系统清理。需要长期固定数据时，可将 `--fixtures` 指向自己的持久测试目录，保留整目录及 `.git`。

## 自动指标的准确含义

| 指标 | 起点和终点 | 不包含的部分 |
| --- | --- | --- |
| snapshot | 调用 `GitRepository.snapshot` 至返回 | AppKit UI、Console 展示 |
| graph | 现成快照到 `CommitGraph.layout` 返回 | Git 查询、其他 UI 重建 |
| status | 完整 Git status 查询及解析 | 变更树渲染 |
| filter_text / filter_regex | log-only 查询及过滤返回 | 输入防抖、主线程 UI |
| log_10000 | 请求 10,000 条完整日志至解析结束 | 绘图及 UI |
| commit_details | HEAD 文件变更列表查询返回 | 屏幕刷新 |
| ui_open | 对已有控制器调用 open，至仓库快照应用并完成布局 | 启动进程、应用菜单、可见首帧 |
| ui_refresh | 主动 refresh 至数据应用完成 | 鼠标事件和可见首帧 |
| ui_worktree_change_refresh | 生成仓库中新增/移除固定未跟踪文件，并刷新至数据应用完成 | 真实工程写操作、可见首帧 |
| ui_rebuild_main_thread | updateUI 及布局返回 | Git 查询、GPU/屏幕呈现 |
| ui_search_with_debounce | 250 ms 防抖模拟，加 log-only 查询和数据应用 | 实际键盘事件、可见首帧 |
| ui_commit_details | loadDetails 至对应哈希文件列表应用 | 鼠标事件和可见首帧 |
| ui_working_diff | 文件读取、真实 Diff 计算、视图数据应用完成 | 独立可见 Diff 窗口及屏幕呈现 |
| ui_diff_layout_switch | 切换双栏/Unified 并等待队列和结果应用 | 鼠标事件、可见首帧 |
| ui_diff_options_burst | 队列被受控挡住时连续提交 5 个空白选项请求，再释放并等待最终结果 | 人的输入间隔、可见首帧 |

搜索项交替执行 `needle` 查询和清除查询，20 次包含两种状态各 10 次。核心文本搜索只搜索当前加载的提交集合，默认 2,000 条；它不等于全仓库全文索引。合成仓库最新提交通常没有文件变更，提交详情的真实大变更负担要另测。

UI 探针直接编译项目的 AppKit 源码，保留真实 Console 回调。新版会显式约束并断言 Log 和 Diff 的实际视图尺寸为 1440×850，在 `ui_open.detail` 中记录实际宽高；早期只设置窗口初始尺寸的记录会被 AppKit 收缩，不能与新版全尺寸记录混算。为隔离单次操作，禁用控制器的 5 秒自动刷新；它没有走生产应用的完整 AppDelegate 启动，也不测可见帧、滚动帧率、鼠标输入或 IDEA。探针独立进程的偏好设置域与 GitDesk 应用域不同。

工作区变化刷新只修改带有工具专用 `.git/gitdesk-benchmark.json` 标记的生成仓库，使用临时文件并恢复原状，不在普通真实仓库上运行该项。

## 四种主题的渲染对照

```sh
python3 scripts/performance/visual_check.py \
  --before-sources output/performance/version-a/Sources \
  --repository /tmp/gitdesk-perf-v1/small \
  --out output/performance/visual-a-vs-b
```

同一个渲染器分别编译优化前和当前源码，保存四种主题的 Log、双栏 Diff、Unified Diff，共 12 张 AppKit 视图 PNG 及像素指纹。仓库另外存在已跟踪并修改的 `syntax.swift` 时，会再对照 8 张 Swift 语法着色 Diff。结果在 `comparison.json`，不一致会返回失败。该工具不操作用户已有应用窗口，也不是桌面截图；必须同时检查像素尺寸和图片内容，避免把相同的空白图误判为通过。

每种主题使用全新的进程，调用视图出现流程，固定实际视图为 1440×850，并验证分支与详情面板有效展开。原有 Diff 选项栏包含两个同优先级的弹性空白，即使旧版与旧版重复渲染也可能出现不同宽度分配。因此渲染器只在测试中将第一个空白宽度固定为 0，在前后两版使用相同约束；生产界面不做该修改。像素相同证明的是这些固定布局、主题和内容下的渲染一致性，不能替代全部交互、任意窗口尺寸或实际屏幕动画的检查。

## 内存指标

- `rss_mib`：操作结束时探针的驻留内存。`1 MiB = 1,048,576 bytes`。
- `footprint_mib`：操作结束时从 `TASK_VM_INFO.phys_footprint` 读取的进程 physical footprint。它和 RSS 的口径不同，压缩内存可能导致 RSS 下降而 footprint 仍然很高。
- `process_peak_rss_mib`：该探针进程从启动至当前的最高 RSS。它是累计峰值，不能说成“这次操作新分配的内存”。核心、UI、各个 Diff 场景分别启动进程，因此跨场景不互相继承峰值。
- `process_peak_footprint_mib`：新版探针读取的内核 physical footprint 高水位，也是进程存活期峰值。旧基线没有此字段；汇总缺失值为 -1，不能当作负内存或零占用。
- `rss_mib_max_after` 和 `footprint_mib_max_after`：该指标计入样本中，操作结束读数的最大值，可能漏掉计算过程中的瞬时峰值。

探针的内存不包含其短暂 Git 子进程。生产应用对比必须再采样进程树。RSS 树合计会重复计算某些共享页，不是整个系统增加的物理内存。IDEA 堆内存、`-Xmx`、主进程 RSS、主进程 footprint 和进程树合计应分别报告，不能互换。

## 生产应用内存采样

在两个应用中打开**同一个测试仓库**，完成相同操作，等待 IDEA 的项目分析和 Git 日志索引结束，再执行：

```sh
python3 scripts/performance/bench.py sample \
  --seconds 60 --interval 0.2 --footprint \
  --label medium-idle-warm \
  --out output/performance/version-a-medium-idle
```

默认自动查找 GitDesk 和 `/Applications` 中 IDEA 的主进程，递归采样子进程，包括可观测到的 Git、文件监听、浏览器辅助进程及语言服务。多个同名实例时，指定主 PID：

```sh
python3 scripts/performance/bench.py sample \
  --pid 12345 --pid 23456 \
  --seconds 60 --interval 0.2 --footprint \
  --label medium-diff \
  --out output/performance/version-a-medium-diff
```

PID 可以在活动监视器查看。每次应用重启都可能变化。`samples.csv` 保留主进程与树 RSS、进程数量、时间戳及基于累计 CPU 时间差的 CPU 使用率；100% 约为占满一个核心。很短、在两个采样点之间启动并结束的子进程会漏采，CPU 计数也有精度限制。

`--footprint` 在采样结束后对主进程执行一次 `vmmap -summary`，保存完整文本及时间戳。它不是 0.2 秒分辨率的 footprint 曲线，也不是所有子进程 footprint 的合计。`vmmap` 记录的 peak 是进程整个存活期峰值；不同启动时长的应用不应直接比较这个峰值。

至少记录五个阶段：打开并分析中、分析结束静置 60 秒、重复浏览/搜索、打开大 Diff、关闭 Diff 后静置 60 秒。单独做 1、3、5 个窗口测试，报告相对单窗口的增量。每个阶段用独立结果目录。不要让自动基准与“空闲生产应用”采样并行，否则基准造成的内存压力可能压缩或换出应用页面。

## IDEA 与 GitDesk 可见响应的对照

公平对照需要相同机器、仓库内容、窗口大小、显示缩放、Git 可执行文件、磁盘路径类型和操作结果。记录 IDEA 版本/build、JBR 版本、`-Xms/-Xmx`、插件、Git 日志索引开关、项目类型和打开窗口数。保留正常使用配置；若测试精简插件配置，把它单列为另一组结果。

两类问题要分别回答：

1. 只为 Git 工作流单独启动应用：对比两个完整进程树的总成本。
2. IDEA 已经用于开发：对比 IDEA 打开 Git Log/Diff **前后的增量**，再与额外启动 GitDesk 的成本对照。不能把已经必需的整个 IDEA 进程当成 Git 操作的新增成本。

建议使用 60 fps 或更高帧率的屏幕录像逐帧计时。60 fps 每帧约 16.7 ms，开始/结束点识别各有帧级误差，不要用这种方式声称 1 ms 的差异。鼠标按下或快捷键触发为起点；目标内容正确显示且可操作为终点。文字输入时同时记录最后一次输入到结果出现的时间，不能从第一次输入开始计时后忽略人的输入速度。

| 操作 | 固定操作 | 完成判定 |
| --- | --- | --- |
| 进程启动 | 完全退出应用，再打开固定仓库 | 首个可操作窗口；日志可用时间另记 |
| 打开仓库 | 应用已运行，打开 medium | main 和正确日志列表出现，加载指示结束 |
| 完整刷新 | 不改变仓库，主动刷新 | 刷新结束；另测插入新提交后刷新 |
| 近期搜索 | 输入明确位于最新 2,000 条中的完整消息 | 结果正确，等待提示结束 |
| 旧提交搜索 | 搜索 medium 中的 `initial needle` | 记录找到/未找到；未找到不能记作更快 |
| 提交详情 | 固定哈希、固定变更数 | 文件列表及提交说明都正确 |
| 普通 Diff | `diff.txt` 的单行修改 | 差异行及计数出现 |
| 大幅重写 Diff | 专用 replace5000 仓库 | 全部行差异可浏览；拒绝展示单独记状态 |
| 快速文件切换 | 连续切换 20 次，最后固定文件 | 最后文件内容正确，记录等待和旧任务积压 |
| 滚动日志 | 同样距离、相同持续时间 | 录像检查长帧、空白行和卡顿；不能用打开耗时代替 FPS |
| 分支切换 | 同一源/目标分支及干净工作区 | HEAD、文件状态与日志正确，刷新结束 |
| 外部文件修改 | 外部修改已跟踪文件 | 变更面板正确更新；测自动发现延迟 |

GitDesk 默认日志范围为 2,000，Load More 扩展到 10,000。IDEA 可以索引全历史；搜索结果语义不同的两次操作不能直接算快慢。比较普通“打开”时应分别记录“首屏可用”和“后台所有索引结束”，不要把一个应用的首屏时间与另一个的全部工作完成时间比较。

每项先预热 3 次，再记录 20 次有效观测，A/B/A/B 交替应用测试，避免温度、系统缓存或后台任务只影响后测的应用。首次进程启动、应用运行中重开仓库、首次打开从未分析的仓库分开记录。只有重启系统并明确缓存状态的测试才能声称接近文件系统冷启动；本自动基准不清理系统缓存。

UI 自动化耗时包含工具往返、等待和辅助功能树读取，不能直接作为应用耗时。IDEA 的辅助功能树读取在此次环境中发生超时，所以本次报告没有 IDEA 的毫秒级可见响应结果。

## 可见响应记录表

生成空表：

```sh
python3 scripts/performance/bench.py ui-template \
  --out output/performance/ui-observations.csv --iterations 20
```

填写 `version`、`phase`、录像中的 `start_ms/ready_ms`、`correct` 和必要的 `notes`。正确结果写 `yes`；错误/超时写 `no` 并注明原因，保留该行。冷启动可将 phase 改为 `process-first`，首次项目分析写 `first-project`。不适用行留空；文件也可以新增真实仓库、多窗口及其它操作行。

```sh
python3 scripts/performance/bench.py ui-summary \
  output/performance/ui-observations.csv \
  > output/performance/ui-summary.csv
```

汇总按应用、版本、场景、阶段和操作分别计算中位数和 P95，同时保留无效/失败数量。空白模板不会被当成零耗时。只有 `correct=yes` 且时间合法的行进入成功耗时统计；失败率必须与成功耗时一起展示。

## 专用 Diff 数据

自动基准中的 Diff 是纯计算。要在两个应用里复现完全相同的内容，可生成磁盘仓库：

```sh
python3 scripts/performance/bench.py diff-fixtures \
  --fixtures /tmp/gitdesk-diff-perf-v1
```

每个子目录都是独立仓库，HEAD 保存 before，工作区 `sample.txt` 保存 after。该命令拒绝覆盖任何已有子目录。

| 子目录 | 内容 |
| --- | --- |
| sparse1000 / sparse5000 | 双方各 1,000 / 5,000 行，仅修改 1 行 |
| whitespace5000 | 双方各 5,000 行，仅空白不同；双方启用忽略空白 |
| replace1000 / replace5000 / replace10000 | 双方各指定行数，没有共同的完整行 |
| bytes-limit | after 为 2,000,001 bytes，触发大小边界 |
| lines-limit | after 为 20,001 行，触发行数边界 |
| binary | after 包含 NUL |

拒绝预览/二进制提示不是成功的文本比较，不能与另一个应用展示完整文本的耗时算同一组。10,000+10,000 行刚好等于 GitDesk 的总行数限制，仍进入文本比较。新版的全部重写输入有精确快速路径，但重复共享行或重排仍可能进入昂贵的原算法；不能用超限提示的速度代表算法速度。

## 远程操作和写操作

clone/fetch/pull/push 的耗时应拆成网络、认证、Git 执行和应用刷新。先用专用本地 bare remote 排除网络，再对指定测试服务器测试固定 RTT/带宽；两组分开报告。不要使用业务 remote 做提交或推送基准。

commit、stage、stash、checkout、merge、rebase、cherry-pick、冲突处理应在测试仓库的独立副本中操作。固定文件数、字节数、冲突数量、hook、签名配置和最终结果，并在每次测量前恢复相同初始状态。签名弹窗、hook 和网络认证等待单列；成功与失败不能混合。当前自动套件未测这些修改仓库的操作。

持续使用测试建议每轮固定 10 次日志筛选、10 次选择提交、10 次 Diff 文件切换和 1 次完整刷新，做 30 轮。记录开始、每 5 轮、结束和静置 60 秒后的 footprint；三次独立重启重复。缓存预热后的平台期与持续线性上涨要区分。一次操作后内存不立即下降不足以证明泄漏，应结合分配栈或 Instruments Leaks。

也可以对冻结的探针做自动重复检查，复现本次 50 次小仓库与 5 次大 Diff 测量。先完成完整基准及专用 Diff 仓库生成，然后运行：

```sh
output/performance/version-a/GitDeskPerfProbe \
  /tmp/gitdesk-perf-v1/small 50 ui \
  > output/performance/version-a-sustained.jsonl
output/performance/version-a/GitDeskPerfProbe \
  /tmp/gitdesk-diff-perf-v1/replace5000 5 ui \
  > output/performance/version-a-heavy-diff.jsonl
```

依次对 version-b 的探针执行同样命令，并使用不同输出文件。每项先预热一次，然后按指标分组重复指定次数；这不是按用户旅程混合执行的 50 轮操作。统计 `warmup=false` 的耗时，比较 `ui_final` 内存及每个指标首 / 末 10 次的 footprint 中位数。探针可直接运行 `core` 或 `diff` 模式；`ui` 模式要求可用的 macOS 图形会话。测试应顺序执行，不能与编译、回归、渲染或其它性能测量并行。

## 更新版本后的对比

更新代码后保留旧结果，使用同样仓库和参数：

```sh
python3 scripts/performance/bench.py run \
  --fixtures /tmp/gitdesk-perf-v1 \
  --out output/performance/version-b \
  --iterations 20 --timeout 300

python3 scripts/performance/bench.py compare \
  output/performance/version-a output/performance/version-b \
  > output/performance/version-a-vs-b.csv
```

`median_change_percent` 正数表示新版更慢，负数表示更快。比较表也输出操作结束 footprint 的变化百分比及进程峰值 RSS；峰值属于累计进程值，不能当作单项操作增量。比较器会提示机器、参数、工具或数据指纹的变化；提示不代表自动证明结果可比。保持同样的 `--real-repo` 使用方式。记录代码 HEAD、未提交修改、源码指纹、探针指纹及测试工具版本；正式长期基线还应提交或单独保存测试工具，防止测试定义自身变化。

每个目录中的 `metadata.json`、`raw.jsonl`、`summary.csv/json`、`errors.json` 和各场景标准错误都应保留。先检查 `errors.json` 为空，再解读耗时。超时会返回失败并保存已完成样本，不能把剩下的快样本当作完整结果。P95 使用 nearest-rank：排序后取第 `ceil(0.95×n)` 个值；n=20 时为第 19 个。20 次只能粗略观察尾延迟，关键指标建议 3 轮×50 次。

可先采用以下内部复核门槛，随后根据多轮基线噪声调整，它们不是行业标准：耗时中位数同时变慢超过 15% 和 10 ms，或 P95 同时变慢超过 20% 和 20 ms；稳定阶段 footprint 同时增长超过 20% 和 20 MiB；主线程连续工作超过 50 ms 单独关注，超过 100 ms 优先调查。发现异常后重复 3 轮，不因一轮失败立即推断代码退化。

16.7 ms 是 60 Hz 一帧的时间参考，8.3 ms 是 120 Hz 一帧的时间参考。`ui_rebuild_main_thread` 超过一帧说明重建阶段存在影响交互的风险，但离屏同步耗时不能直接换算成实际滚动 FPS。

## 结果可信度检查

复测时固定供电、电源模式、显示器、温度和后台应用；避免构建、容器任务、系统更新、 Spotlight 扫描及大规模文件同步。记录内存压力、swap 状态和测试顺序。每个应用至少重启一轮，区分进程存活期峰值和当前占用。不要强制 IDEA GC 后只测 IDEA，也不要只清其中一个应用的缓存。

自动套件没有覆盖所有真实输入：超长单行、大提交说明、百万提交、深 merge 图、Git LFS、子模块、网络盘、权限失败、磁盘空间不足、长时间远程操作和系统高内存压力，都应在专门测试环境补充。请将“已测”“代码推断”“待测”分开标记。
