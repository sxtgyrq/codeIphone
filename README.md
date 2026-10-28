# Argument Map · 原生 iPhone 地图浏览

当前版本实现 **登录已有 Server，以及只读显示逻辑地图**。使用 SwiftUI 原生画布，支持 iOS 16 及以上。

登录后显示线路、单/双向箭头、整数 Cross、六种尺寸 LN 及值/逻辑语言；单指拖动、双指缩放、“查看全部”、手动刷新。点选查看对象资料，节点列表可以搜索完整逻辑语言；显示菜单可切换箭头、标签和交点。缩小时减少标签重叠，详情保留完整文本。

最大放大时网格为 **1 坐标单位**，1 单位线段显示为 128 个屏幕点，方便查看短线和相邻线路；右下角比例尺标明当前网格单位，点击“查看全部”恢复全图。

本阶段不提供地图新增、修改、删除、K/J 计算或导入入口。登录/退出以外只调用现有读取接口，不改 Server 或数据库结构。

## 同一 Wi-Fi 连接电脑

1. 在 Windows 电脑启动现有 ArgumentMap Server，例如运行 `E:\publish\ArgumentMap\Start-Server.cmd`。它需要监听局域网接口；现有默认端口为 `61011`。
2. 手机与电脑连接同一 Wi-Fi。在电脑上用 `ipconfig` 查看 **WLAN 的 IPv4 地址**，不要填写 VPN/虚拟网卡地址。
3. App 的服务器地址填写 `http://电脑的IPv4地址:61011`，例如 `http://192.168.0.100:61011`。`localhost`、`127.0.0.1` 在手机上表示手机自身，`0.0.0.0` 是监听地址，均不能代替电脑 IP。
4. 使用现有地图账号登录。首次连接时允许“本地网络”访问；如连不上，检查 Windows 防火墙是否允许 Server 的局域网连接、电脑是否休眠，以及 Wi-Fi 是否开启客户端隔离。
5. 登录后自动读取地图；电脑版保存修改后，手机点击“刷新”。刷新失败保留上一份完整地图，登录失效则清除地图并返回登录页。

**现有 Server 同一账号仅保留一个 LoginCode。手机登录会使电脑版该账号的旧会话失效。** App 仅记住服务器地址和用户名，不保存密码；LoginCode 只保存在本次运行内存中。电脑的 MySQL 配置只留在 Server，不能放进 iPhone 工程。

局域网 HTTP 配置仅对本地地址放行，没有全局关闭 ATS。iOS 17 起为 IPv4/CIDR 配置窄范围例外，同时提供本地网络用途说明，依据 [Apple ATS 文档](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppTransportSecurity/NSExceptionDomains) 和 [本地网络隐私说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。域名服务可使用 HTTPS。

## 协议与显示

全部请求为 POST。`Login` 发送用户名、密码与 `dbPrefix: ArgumentMap`，接收裸 32 位十六进制 LoginCode；其余请求 body 使用 `userName`、`loginCode`，解析 `{success,code,message,data}`。地图依次读取 `GetAllLineData`、`GetAllCrossData`、`GetLogicalNodes`，全部成功后一起显示。三次读取是现有 Server 的独立事务，不代表跨端编辑时的单一数据库快照。

Cross 传输保留二倍坐标 `x2/y2`，客户端只接受范围内偶数，不把旧半整数 Cross 取整；LN 中心仍保留半整数。Y 轴向上，地图范围 `0…500000`。Cross 显示五种换路状态，和线路本身的单/双向区分。NOT 的 `¬(?)` 等逻辑语言按服务端原文显示。

## Windows → 云端编译 → iPhone

1. 把**本目录中的文件**上传到你自己的 GitHub 仓库，包含隐藏的 `.github` 目录。仓库根目录应直接包含 `HelloYrq.xcodeproj`、`HelloYrq` 和 `.github`。
2. 在仓库的 **Actions → Build native iPhone app → Run workflow** 启动构建。推送到 main/master 也会触发。
3. 云端 Mac 使用 Xcode 编译真实 iPhone 的 ARM64 程序，再运行协议单测和 iPhone 原生 UI 测试，检查登录、地图显示、刷新失败、失效会话、空地图和退出，并保存截图。全部通过后才提供 IPA 下载。
4. 构建成功后，在该次运行页面的 **Artifacts** 下载 `HelloYrq-unsigned-ipa`，解压，得到 `HelloYrq-unsigned.ipa`。不要把外层 GitHub Artifact ZIP 当 IPA。
5. 用 Windows 上的 AltServer + iPhone 上的 AltStore Classic，为 IPA 签名后安装，详见下面。

云构建不需要 Apple ID、密码、签名证书或付费开发者账号；不要把这些信息放入源代码、GitHub Secrets 或上传给我。GitHub 云运行额度取决于你的仓库和账号方案。

**未签名 IPA 无法直接点击安装，也不是 TestFlight 包。** 云编译解决“生成原生程序”，Windows 签名工具解决“安装到你的手机”，是两个步骤。

## 普通 Apple ID 安装到自己的 iPhone

按照 [AltStore Classic 的 Windows 官方安装说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) 操作：

1. 安装 AltServer，以及它要求的 Apple 驱动/iTunes/iCloud 组件；以该官方页面的当前说明为准。
2. 用 USB 连接、解锁 iPhone，选择信任电脑；通过 AltServer 安装 AltStore Classic。
3. Apple ID 只在你本机的安装工具中登录，不进入本工程或云端构建。
4. 按提示信任开发者；iOS 16 及以上开启“设置 → 隐私与安全性 → 开发者模式”。
5. 把 `HelloYrq-unsigned.ipa` 传到 iPhone“文件”，在 AltStore 的 My Apps 页面点 `+` 选择它并签名安装。
6. 在主屏幕打开“Argument Map”。

AltStore 是第三方签名工具，不是 Apple 自带软件。普通 Apple ID 的个人测试签名通常 **7 天到期**，到期前用 AltStore 刷新；能否自动刷新取决于 AltServer 和连接情况。[Apple 个人团队限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[AltStore 刷新说明](https://faq.altstore.io/altstore-classic/your-altstore)。

## 查看“确实跑起来”的证据

Actions 成功需要同时通过 ARM64 真机编译和原生 UI 启动测试。`HelloYrq-test-results` Artifact 包含测试日志、`HelloYrq.xcresult` 和可用时导出的截图。只有 Windows 本地检查通过，不代表已经完成 iOS 编译、模拟器启动或真机安装。

## 文件

- `HelloYrq/HelloYrqApp.swift`：App 入口，沿用原工程/Bundle ID，安装时更新原 App。
- `HelloYrq/MapAPI.swift`、`MapModels.swift`：现有 Server 协议与地图模型。
- `HelloYrq/MapViewModel.swift`：登录、刷新、注销及失效会话状态。
- `HelloYrq/MapLoginView.swift`、`MapScreen.swift`、`MapCanvasView.swift`：登录、地图浏览和原生画布。
- `HelloYrq.xcodeproj`：已生成并共享 Scheme 的 Xcode 工程，可直接交给云端 Mac。
- `HelloYrqTests`：URLProtocol 截获网络请求的原生协议单测，不访问正式地图。
- `HelloYrqUITests`：登录与地图交互测试，使用仅 Debug 编译且显式测试参数启用的网络夹具；正常启动始终连接真实 Server。
- `.github/workflows/build-ios.yml`：云编译、模拟器启动和产物下载。
- `tools/build_ios.sh`：云端与 Mac 本地共用的构建脚本。
- `tools/generate_project.py`：用 Python 重新生成工程，无须安装 XcodeGen。

Windows 本地检查：

```powershell
cd 'E:\project\codeIphone'
python tools/generate_project.py
python -m unittest discover -s Tests -v
```

本地有 Mac/Xcode 时可直接运行 `bash tools/build_ios.sh`。Windows 不能运行 Xcode 或直接编译 iOS App。

## 当前交付状态

工程、局域网连接、地图浏览和原生测试已准备。Windows 本地只能运行生成器/配置检查，不能运行 XCTest 或编译 iOS。旧问候页的 Actions 成功记录不代表本次版本已通过；新版本需以对应提交的设备构建与模拟器测试结果为准，真机仍需安装签名并在同一 Wi-Fi 验证。
