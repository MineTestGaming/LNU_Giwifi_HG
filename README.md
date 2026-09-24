# GiWiFi 岭南师范学院校园网认证工具

面向岭南师范学院校园网的第三方开源认证工具。项目基于 [Yanmo552/giwifi-ua-switcher](https://github.com/Yanmo552/giwifi-ua-switcher) 的开源实现进行适配与扩展，重点补充了湖光校区门户所需的 `wlanacname`（AC 名称）参数，并提供可配置 AC 名称的 Windows 轻量版本。

> 本项目与学校、校园网运营方及上游项目作者没有隶属或官方合作关系。湖光校区适配根据实际门户响应进行验证；其他校区和网络环境请自行测试。

## 版本说明

仓库保留上游 Flutter 项目，同时新增 Windows 原生轻量版：

| 版本 | 目录 | 平台 | 开发/运行环境 |
| --- | --- | --- | --- |
| Flutter 原版 | 仓库根目录的 `lib/`、`android/`、`ios/` 等 | Flutter 支持的平台 | Flutter SDK；按平台配置对应工具链 |
| Windows 轻量版 | [`windows-lite/`](windows-lite/) | Windows x64 | .NET 10 SDK；无需 Flutter |

轻量版使用 Windows Forms 和 .NET 自带的 HTTP、Cookie、AES 能力，不依赖 Flutter、WebView 或第三方 NuGet 包。它是 Windows 桌面版本，不提供 Android/iOS 支持。

macOS 版本继续使用 Flutter 原版认证逻辑，发布包为同时支持 Intel 和 Apple Silicon 的 universal binary。仓库已配置 GitHub Actions，可在 Actions 页面手动运行 `Apple builds`，或推送 `v*` 标签自动构建并创建 Release，生成 `.dmg` 和 `.zip` 安装包。

macOS 安装包构建完成后，可在对应的 workflow artifacts 中下载：

- `GiWiFi-macOS-universal.dmg`：Intel Mac 与 Apple Silicon Mac（M 系列）通用

目前未配置 Apple Developer 签名与公证，因此首次打开时，macOS 可能需要在“系统设置 → 隐私与安全性”中手动允许打开。

## Windows 轻量版快速开始

### 直接运行源码

1. 安装 [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)。
2. 克隆本仓库，并进入项目目录。
3. 双击根目录的 `启动轻量版.bat`，或在终端运行：

   ```powershell
   dotnet run --project windows-lite/GiWifiLite.csproj
   ```

首次运行时 .NET 会构建项目。也可以在 Visual Studio 中打开 `windows-lite/GiWifiLite.csproj`。

### 发布独立 Windows 程序

在 Windows x64 上运行：

```powershell
dotnet publish windows-lite/GiWifiLite.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish/win-x64
```

发布产物会放在 `publish/win-x64/`。独立版包含 .NET 运行时，文件会比框架依赖版本大；可将 `--self-contained true` 改成 `--self-contained false` 以缩小体积，但目标电脑需要安装相应 .NET Desktop Runtime。构建产物不会提交进源码仓库。

## 湖光校区设置

连接需要认证的校园 Wi-Fi 后，打开应用并填写自己的校园网上网账号和密码。认证服务器默认是 `http://100.100.9.2`；“校园 AC 名称”用于构造门户登录页请求，湖光校区默认值为：

```text
GiWiFi_lnsfHG
```

程序会请求类似下面的登录地址，并解析门户返回的隐藏字段：

```text
http://100.100.9.2/gportal/web/login?wlanacname=GiWiFi_lnsfHG
```

如果其他校区的门户地址使用不同的 `wlanacname`，请在界面中改成该校区实际使用的值。登录页没有返回密码框时，程序会提示检查校园 Wi-Fi 连接、认证服务器和 AC 名称；不能仅凭此提示判断账号密码是否正确。

## 功能

- 选择电脑、安卓手机、iPhone、iPad、安卓平板等 User-Agent，或填写自定义 UA。
- 一键获取门户登录表单并提交认证。
- 遇到门户要求更换绑定设备时，确认后自动提交换绑并等待冷却，再重试认证。
- 检测当前在线状态；已在线时可确认先下线再切换设备类型。
- 可选开启每 60 秒掉线检查和自动重连。
- 查看最近认证记录并清空日志。
- 可选在本机记住账号密码。

Flutter 版本具有自身的界面和平台功能；请以对应版本的实际实现为准。

## 数据与安全

- 工具不会将账号、密码或认证日志上传到本项目维护者的服务器；认证请求发送到界面配置的校园网认证服务器。
- Windows 轻量版勾选“在本机记住账号密码”时，会将凭据以**未加密明文**保存到 `%APPDATA%\giwifi_ua_switcher\settings.json`。仅在个人设备上使用；取消勾选可关闭保存。请勿分享该配置文件或包含个人凭据的日志。
- 本工具只应用于你获准使用的校园网账号，并遵守学校及网络运营方的规定。设备类型选择和认证行为可能受套餐、门户策略或校区配置限制。
- 发现本次对话或测试中曾暴露的密码时，请及时更换，不要将真实账号密码写进 issue、截图或源码。

## 来源与许可

- 上游项目：[Yanmo552/giwifi-ua-switcher](https://github.com/Yanmo552/giwifi-ua-switcher)。感谢原作者提供 Flutter 版本及认证流程实现。本项目保留上游 `LICENSE` 文件中的 MIT 许可与版权声明。
- 本仓库的修改和 Windows 轻量版以仓库中的 MIT License 文件为准；继续分发时请保留许可和版权声明。
- GiWiFi、岭南师范学院及相关网络标识归其各自权利人所有。本项目不代表学校官方软件。

## 反馈

请提交 issue 时注明操作系统、所在校区、门户登录 URL 中的 AC 名称、应用版本和脱敏后的错误信息。**不要提交账号、密码、Cookie、认证令牌或完整的个人网络信息。**
