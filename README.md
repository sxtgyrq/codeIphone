# Argument Map · 原生 iPhone 逻辑地图编辑

使用 SwiftUI 原生界面连接现有 ArgumentMap Server，支持 iOS 16 及以上。本轮已实现线路、Cross、LN、区域操作、撤销及流程图导入的触控编辑流程，沿用电脑版的账号、数据和服务端业务规则。

**当前交付状态：这轮编辑版代码已实现，正在等待对应提交的云端编译与原生测试。** 真机安装、同一 Wi-Fi 连接及完整编辑验收仍需验证。旧版浏览或缩放版本的成功记录、旧 IPA，不能证明本轮编辑版已经验证通过。

## 手机上的基本操作

地图下方提供 **浏览、线路、Cross、LN、区域** 五个工具。轻点对象后，底部显示“编辑、资料、更多”；复杂操作用表单或预览确认。顶部“更多 → 触摸操作指南”也有电脑版按键对照。

- **浏览**：单指拖动平移、双指缩放；“查看全部”适配整图，更多面板提供放大、缩小、回到地图中心。
- **精确落点**：移动地图，使目标位置对准中央准星，再点“确认落点”或“加点”。准星旁的定位按钮及“更多 → 精确定位”可以输入 X/Y，并逐单位微调。
- **选择对象**：在相应工具下点选线路、交点或 LN；密集区域也可用“列表”或“更多 → 地图对象列表”查找。节点列表支持搜索逻辑语言和定位。
- **显示控制**：“显示”面板切换线路箭头、速度、LN 标签、LN 保护区域，以及连通、不连通、未设置的 Cross。
- **最细网格**：放到最大时为 **1 坐标单位**，1 单位线段显示为 128 个屏幕点；比例尺显示当前网格单位。

线路节点与 Cross 使用整数坐标；LN 中心保持“整数 + 0.5”。地图范围为 `0…500000`，Y 轴向上。落点、合法线段方向和 LN 实际边界仍由 Server 校验；外围虚线保护区域只用于规划。

## 电脑版按键对应哪里

| 电脑版操作 | iPhone 入口 |
| --- | --- |
| `3 / 4` 新建、开始绘制 | **线路 → 新建线路**，进入草稿 |
| `A / 5` 加点、切换前端或末端 | 草稿底部 **加点**；草稿 **更多 → 切换到前端/末端加点** |
| `T / E / R` 插点、改点、删点 | 草稿 **节点** 列表选择节点，再移动、插点或删除 |
| `F6` 保存 | 草稿底部 **保存线路** |
| `Backspace / Esc` 取消操作 | 底部 **取消**；只退一步用顶部 **撤回草稿一步** |
| `F8 / F9` 选线、编辑线 | **线路** 工具点选线路 → **编辑** |
| 线路 `E / C / D / B / L` | 选中线路 → **更多 → 线路属性、反转方向、拆分线路、合并线路、锁定/解锁线路** |
| `K` 计算 Cross | **Cross → 计算交点**，或 **显示 → 计算交点** |
| `U / Tab` 选交点、切换同位置关系 | **Cross** 工具点交点 → 选择该位置的线路关系 |
| `I / O / P` 设置交点 | Cross 表单选择 **双向连通、不连通、未设置** |
| `Enter / 【` 选择出口、单向换路 | Cross 表单直接选择所需的 **线路 A → 线路 B** 方向 |
| `F5 / A` 新增 LN | **LN → 新增 LN → 选类型 → 确认落点 → 保存**；可开启连续放置 |
| LN 的 `7 / E` | **LN** 工具点节点 → **编辑**；移动、连接和删除在该节点的 **更多** 中 |
| `J / G` 计算关联、显示保护区域 | **显示 → 重算 LN 关联 / LN 保护区域** |
| `F7` 框选移动 | **区域 → 开始框选**，依次确认两个角，再选择移动、复制或删除整组 |
| `Ctrl+C / Ctrl+V` | 选中线路或 LN → **更多 → 复制**；区域选中后点 **复制**；再用 **更多 → 粘贴** 选落点 |
| `Ctrl+Z` | 顶部撤销按钮；有线路草稿时撤回本地一步，其余时候请求撤销本账号上次数据库操作 |
| `F2 / F3 / F4` | **浏览 → 刷新** 或顶部 **更多 → 刷新地图（保留草稿）** |
| `1 / 8 / 9 / 0` 显示开关 | **显示** 菜单 |
| `Ctrl+F1 / F1` 收起工具、帮助 | 顶部 **更多 → 收起工具栏 / 触摸操作指南** |

手机端不需要外接键盘，也不需要记住这些快捷键。

## 编辑功能

### 线路

新建时先编辑本地草稿：添加前端或末端节点、选择节点、插点、删除、反转草稿方向、撤回一步。首次保存，或首次请求 Server 计算移动节点的合法位置时，会创建真实的空线路标识；后续沿用该标识，避免失败后重复创建线路。节点移动使用现有 `FindNodePosition` 规则，由 Server 计算合法位置。

已有线路支持编辑节点、属性和速度、单/双向、锁定/解锁、反向、拆分、合并、复制粘贴和删除。合并先读取服务端可用方案，选择并预览后确认。保存、属性变更及几何操作均携带读取时的版本。

### Cross

同一坐标上的不同线路关系分开选择。保留五种状态：未设置、不连通、双向连通、第一条线路到第二条线路、第二条线路到第一条线路。界面直接展示线路名称和方向；LN 范围内必须不连通等规则仍由 Server 检查。

“计算交点”按现有服务端的单步事务连续执行，显示进度，可停止；前台编辑优先于下一步计算。停止不会撤回已经完成的计算步骤。

### LN

支持 LN4、LN6、LN8、LN10、LN12、LN18 的新建、编辑、移动、删除与资料查看；可复制允许复制的 LN，LN18 开始节点全图只能有一个。

- LN4：True/False 分支，可关联 LN6 命题，查看来源。
- LN6：命题及 Custom/Class/Instance 类型，查看引用它的分支。
- LN8：关系选项包含 **非（NOT）**，逻辑语言自动生成 **`¬(?)`**。
- LN10/LN12：实例、类及关联导航，可从类创建实例，遵循已有命名和关联规则。
- LN 连接：选择两个节点后，选择直连、前往或寻找，先向 Server 请求路线预览，再确认保存；提交时保留预览使用的几何信息。
- “显示 → 重算 LN 关联”按服务端游标逐步计算，可停止；不自动重试结果不确定的步骤。

### 区域、复制与导入

区域用两个精确角点确定边界，Server 返回选中的完整线路、LN 和 Cross。随后可以预览整组移动、复制粘贴或删除整组。这里只处理符合现有框选规则的完整对象，不裁剪半条线路或部分 LN。含 LN18 开始节点的区域不能复制；区域粘贴以选区左上角为落点，与 WPF 相同。

复制时同时写入系统剪贴板，使用与 WPF 相同的线路、LN、区域 JSON 副本格式。当前 App 可用“更多 → 粘贴”；从其他地方复制的副本使用“更多 → 从系统剪贴板粘贴”，解析后预览新落点再保存。App 不在后台读取剪贴板。复制粘贴、区域操作和导入都走现有 Server 接口。

顶部 **更多 → 导入流程图** 支持粘贴 JSON 或从文件读取 `argumentmap.flow/1` 数据，先预览布局，再确认整组保存。格式见 [流程图制作与导入说明](HelloYrq/FlowDiagramLanguage.md)，App 内的触摸操作指南也可查看。

## 版本日期

登录页、进入后的地图主界面和操作指南显示 **版本 YYYY.MM.DD**，例如 `版本 2026.10.28`；账号菜单还显示构建号。这里的日期是随安装包固定的发布日期，不随手机当天日期变化。

`tools/generate_project.py` 默认按 UTC+8 的当天生成版本日期，也可通过环境变量 `RELEASE_DATE=2026.10.28` 固定指定发布日期。日期同时写入 `MARKETING_VERSION` 和 `ArgumentMapReleaseDate`；云构建设备包的构建号使用 `GITHUB_RUN_NUMBER`，同一天重建也能区分。

## 保存、冲突与撤销

Server 保持最终裁决权。所有写操作携带当前会话和接口要求的版本、几何预览或区域快照；手机不会跳过所有权、锁定、坐标、LN 边界及唯一性规则。

| 提示或情形 | App 的处理与继续方式 |
| --- | --- |
| 版本冲突，其他客户端已修改对象 | 阻止继续写入，先刷新检查。刷新保留线路草稿；需要放弃本地修改时，用 **更多 → 重新加载当前线路** 并确认。旧草稿不会自动套用最新版本去覆盖远端。 |
| 保存请求断网、超时或响应无法确认 | 结果可能已写入，App 不自动重试新增、粘贴或导入。先刷新并检查地图，再决定下一步；结果不明期间禁止新的写操作。 |
| Server 已确认保存，但随后刷新失败 | 明确提示 **已保存、刷新失败**，保留已有画面；恢复网络后刷新，不要再次提交同一操作。 |
| 撤销请求没有确定结果 | 保留本次撤销请求 ID。同一服务器、同一账号重新登录后，再点撤销仍使用该 ID，避免意外撤销更早的一笔操作。确认前允许读取、刷新和同 ID 撤销，阻止其他写操作。 |
| Server 明确确认或拒绝撤销 | 清除待确认撤销 ID。能否撤销及可撤销范围由现有 Server 决定。 |
| 会话失效或退出账号 | 停止计算和本次操作，清除地图并回到登录页；旧会话的迟到结果不会覆盖新登录的数据。 |

前台提交期间防止连续点击重复请求。K/J 计算与前台操作串行使用服务端步骤；这里的“后台计算”指 App 内的异步计算，**不保证锁屏或切到其他 App 后继续运行**。取消网络请求也不能保证服务端已回滚；有不确定结果时需刷新检查。

本机只持久保存服务器地址、用户名，以及按服务器和用户名区分的待确认状态/撤销请求 ID；密码和 LoginCode 不写入偏好设置。草稿撤回与数据库撤销是不同范围的操作，顶部按钮会随当前状态改变含义。

## 同一 Wi-Fi 连接电脑

1. 在 Windows 启动 ArgumentMap Server，例如运行 `E:\publish\ArgumentMap\Start-Server.cmd`。Server 需要监听局域网接口；当前默认端口为 `61011`。
2. 手机与电脑连接同一 Wi-Fi。用 `ipconfig` 确认电脑当前 WLAN 的 IPv4 地址。
3. 手机填写 `http://电脑IPv4地址:61011`。例如电脑当前仍为 `192.168.1.33` 时，填写 `http://192.168.1.33:61011`；换网络后按实际地址更新。`localhost`、`127.0.0.1` 在手机上代表手机自身，`0.0.0.0` 是监听地址。
4. 使用现有地图账号登录，并允许本地网络访问。连不上时检查 Windows 防火墙、电脑休眠和 Wi-Fi 客户端隔离设置。
5. 电脑端完成修改后，在手机刷新查看。读取失败保留上一份完整地图；会话失效则返回登录。

**现有 Server 同一账号仅保留一个 LoginCode。手机登录会使电脑版该账号的旧会话失效。** 两端同时操作时应使用各自有权限的账号，仍须遵守对象所有权规则。MySQL 地址、账号和密码只留在 Server 配置中，不放入 iPhone 工程。

局域网 HTTP 使用本地网络配置及私有 IPv4 网段的 ATS 例外，没有全局关闭 ATS；域名服务可使用 HTTPS。配置依据 [Apple ATS 文档](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppTransportSecurity/NSExceptionDomains) 和 [本地网络隐私说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。

## 协议兼容

全部请求为 POST。`Login` 发送用户名、密码与 `dbPrefix: ArgumentMap`，接收裸 32 位十六进制 LoginCode；其余请求使用 `userName`、`loginCode`，解析 `{success,code,message,data}`。

地图读取 `GetAllLineData`、`GetAllCrossData`、`GetLogicalNodes`，全部成功后一起更新画面。三次读取仍是 Server 的独立事务，不代表跨端编辑时的单一数据库快照。

Cross 传输继续使用二倍坐标 `x2/y2`，客户端只接受范围内偶数，不把旧半整数 Cross 取整；LN 中心仍为半整数。线路和对象版本保留 `Int64`。iOS 复用既有读写接口，本轮不增加手机专用数据库或修改 Server 数据结构。

## Windows → 云端编译 → iPhone

1. 仓库根目录包含 `HelloYrq.xcodeproj`、`HelloYrq`、测试目录和隐藏的 `.github` 目录。
2. 在 GitHub **Actions → Build native iPhone app → Run workflow** 启动对应分支构建。推送到 `main`、`master`、`codex/**` 或创建 Pull Request 也会触发。
3. `macos-15` 上先运行工程检查，再用 Xcode 编译真机 ARM64 程序，并运行原生协议、状态与 UI 测试。脚本返回成功后，工作流才上传可下载 IPA。
4. 在该次运行的 **Artifacts** 下载 `HelloYrq-unsigned-ipa` 并解压，得到 **`HelloYrq-unsigned.ipa`**。外层 Artifact ZIP 不是 IPA。
5. 用 Windows 上的 iLoader 选择 IPA，签名后安装到 iPhone。使用与本次验证提交对应的产物。

云端产物路径为 `build/HelloYrq-unsigned.ipa`。本机此前整理的交付位置为 `E:\project\codeIphone\build\delivery\ArgumentMap-unsigned.ipa`；该文件可能仍是旧版本，**只有下载并替换为本轮成功构建的产物后，才包含本轮编辑功能**。安装后可用界面版本日期、构建号和 Actions 提交核对。

云编译不使用 Apple ID、密码或签名证书。未签名 IPA 不能直接点击安装，也不是 TestFlight 包；安装时需要在本机签名。

### 用 iLoader 安装

[iLoader 官方项目](https://github.com/nab138/iloader)支持导入 IPA；Windows 按其说明安装 iTunes 以提供设备连接组件。安装包从 [iLoader 官网](https://iloader.app/)或官方仓库下载。

1. 用 USB 连接并解锁 iPhone，按手机提示信任这台电脑。
2. 打开 iLoader，选择设备，在本机安装工具中登录自己的 Apple 账号。
3. 使用导入 IPA 的入口，选择从成功构建下载的 `HelloYrq-unsigned.ipa`，按工具提示完成签名和安装。
4. 按设备提示信任开发者，并在需要时开启 **设置 → 隐私与安全性 → 开发者模式**。参见 [Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。
5. 从主屏幕打开 **Argument Map**，检查版本，再连接局域网 Server。

iLoader 是第三方签名工具。普通 Apple 账号 Personal Team 的描述文件有效期为 7 天，到期需要重新签名安装；是否使用额外的自动刷新工具由自己的安装方式决定。[Apple 个人团队限制](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 验证与测试证据

Windows 本地可运行工程生成器与配置检查：

```powershell
cd 'E:\project\codeIphone'
python tools/generate_project.py
python -m unittest discover -s Tests -v
```

Mac/Xcode 可运行 `bash tools/build_ios.sh`。Windows 不能编译 iOS 或执行 XCTest；本地配置检查通过不等于原生代码、模拟器及真机已验证。

- `HelloYrqTests`：截获请求的协议测试、模型与编辑规则测试，以及会话切换、版本冲突、不确定写入、撤销同 ID 恢复、计算调度等状态测试。
- `HelloYrqUITests`：用 Debug 专用夹具覆盖登录、地图浏览及编辑交互；夹具只在显式 UI 测试启动参数下启用，不连接正式地图。
- Actions 的 `HelloYrq-test-results`：包含设备编译/模拟器测试日志、`HelloYrq.xcresult`，以及能导出时的截图和测试摘要。通过与否以本次提交的实际运行结果为准。

完整验收还应在测试地图上检查：线路新增及节点修改、锁定/反向/拆分/合并、五种 Cross 状态、各尺寸 LN 与 NOT、LN 连接与实例、区域移动/粘贴/删除、导入、撤销，以及断网、会话失效、跨端版本冲突后的恢复。当前文档不把这些尚待执行的真机操作记作已通过。

## 主要文件

| 文件 | 内容 |
| --- | --- |
| `HelloYrq/HelloYrqApp.swift` | App 入口，沿用原工程与 Bundle ID |
| `MapAPI.swift`、`MapModels.swift` | 登录、读取与公共模型 |
| `MapEditingAPI.swift`、`MapEditingModels.swift` | 真实 Server 写操作、预览协议及类型化数据 |
| `MapViewModel.swift` | 会话、写操作调度、K/J 循环、未知结果恢复和撤销 |
| `MapWorkspace.swift`、`MapWorkspaceSupporting.swift` | 触控工具、选择、准星、区域与导航 |
| `MapCanvasView.swift`、`MapInteraction.swift` | 原生画布、编辑覆盖层、选择及发布日期显示 |
| `MapLineDraft.swift`、`MapLineEditor.swift` | 线路草稿与节点操作 |
| `MapNodeEditor.swift`、`MapCrossEditor.swift` | LN 与 Cross 表单 |
| `MapAdvancedEditors.swift` | LN 连接、线路合并和流程图导入预览 |
| `HelloYrq/FlowDiagramLanguage.md` | 流程图格式与制作说明 |
| `.github/workflows/build-ios.yml`、`tools/build_ios.sh` | 云构建、原生测试与产物 |
| `tools/generate_project.py` | Windows/Mac 共用工程及版本生成器 |

表中未写目录的 Swift 文件均在 `HelloYrq/` 下。

## 触控设计参考

触控入口、准星定位和预览流程参考以下官方资料，具体行为以本项目实现为准。

- [Apple HIG · Gestures](https://developer.apple.com/design/human-interface-guidelines/gestures)：使用用户熟悉的点选、拖动与缩放，并为操作保留可发现的按钮入口。本项目据此采用底部工具与明确确认按钮。
- [Autodesk AutoCAD Mobile · Drawing Settings](https://help.autodesk.com/cloudhelp/ENU/AutoCAD-Mobile-Help/files/Creating-and-Viewing/DRAWING_SETTINGS_html.html)：移动绘图仍需明确的捕捉、追踪、单位与网格控制。本项目的整数网格、坐标输入和准星定位是结合 ArgumentMap 几何规则做的设计选择。
- [Microsoft · Touch interactions](https://learn.microsoft.com/en-us/windows/apps/develop/input/touch-interactions)：触摸应容纳手指定位误差，并及时展示反馈和提交后的预期结果。本项目据此把键盘命令转换为对象操作菜单、草稿覆盖层与提交前预览。
