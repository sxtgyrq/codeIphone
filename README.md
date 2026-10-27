# 你好，要瑞卿 · 原生 iPhone App

第一版只做一件事：打开 App，在屏幕中央显示 **你好，要瑞卿**。

使用 SwiftUI 原生界面，无网页、WebView、后端、第三方 App 依赖或 Apple 账号配置。支持 iOS 16 及以上。现有 `E:\ProjectYrq\ArgumentMap` 未作修改，本版本暂不连接 Server。

## Windows → 云端编译 → iPhone

1. 把**本目录中的文件**上传到你自己的 GitHub 仓库，包含隐藏的 `.github` 目录。仓库根目录应直接包含 `HelloYrq.xcodeproj`、`HelloYrq` 和 `.github`。
2. 在仓库的 **Actions → Build native iPhone app → Run workflow** 启动构建。推送到 main/master 也会触发。
3. 云端 Mac 使用 Xcode 编译真实 iPhone 的 ARM64 程序，再在 iPhone 模拟器中启动 App，检查文字是否正确显示，并保存截图。全部通过后才提供 IPA 下载。
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
6. 在主屏幕打开“你好，要瑞卿”。

AltStore 是第三方签名工具，不是 Apple 自带软件。普通 Apple ID 的个人测试签名通常 **7 天到期**，到期前用 AltStore 刷新；能否自动刷新取决于 AltServer 和连接情况。[Apple 个人团队限制](https://developer.apple.com/help/account/basics/about-your-developer-account)、[AltStore 刷新说明](https://faq.altstore.io/altstore-classic/your-altstore)。

## 查看“确实跑起来”的证据

Actions 成功需要同时通过 ARM64 真机编译和原生 UI 启动测试。`HelloYrq-test-results` Artifact 包含测试日志、`HelloYrq.xcresult` 和可用时导出的截图。只有 Windows 本地检查通过，不代表已经完成 iOS 编译、模拟器启动或真机安装。

## 文件

- `HelloYrq/HelloYrqApp.swift`：全部原生界面。
- `HelloYrq.xcodeproj`：已生成并共享 Scheme 的 Xcode 工程，可直接交给云端 Mac。
- `HelloYrqUITests`：启动 App 并核对文字的 UI 测试。
- `.github/workflows/build-ios.yml`：云编译、模拟器启动和产物下载。
- `tools/build_ios.sh`：云端与 Mac 本地共用的构建脚本。
- `tools/generate_project.py`：用 Python 重新生成工程，无须安装 XcodeGen。

Windows 本地检查：

```powershell
cd 'E:\ProjectYrq\codeIphone'
python tools/generate_project.py
python -m unittest discover -s Tests -v
```

本地有 Mac/Xcode 时可直接运行 `bash tools/build_ios.sh`。Windows 不能运行 Xcode 或直接编译 iOS App。

## 当前交付状态

工程、云构建脚本和 UI 测试已准备。是否已云编译成功、是否已安装到真机，需以实际 Actions 结果和手机验证为准；不把静态检查或未签名包当作安装成功。
