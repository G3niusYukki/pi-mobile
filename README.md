# Pi Mobile

Pi Mobile 让你在 iPhone 上继续 Mac 上的 pi 会话，查看工具结果、回复审批请求，或在任务运行时补充指令。手机和 Mac 都主动连接到你自建的 relay。Mac 网关（gateway，也就是 controller）负责运行 `pi --mode rpc`。

```text
iPhone App ←─ WSS ─→ relay ←─ WSS ─→ Mac gateway ←─ JSONL ─→ pi
```

## 安装 0.1.2

iPhone 需要 iOS 26.0 或更高版本。从 [v0.1.2 发布页](https://github.com/G3niusYukki/pi-mobile/releases/tag/v0.1.2) 下载未签名 IPA（构建 7）和 `SHA256SUMS.txt`，在下载目录运行 `shasum -a 256 -c SHA256SUMS.txt` 校验安装包。真机安装前，请用自己的 Apple 签名证书和描述文件为主 App 和内嵌的实时活动扩展签名。

从 0.1.0 或 0.1.1 升级时，请沿用原签名团队和 Bundle ID，覆盖安装以保留配对。将 Mac 网关更新到同一版本并重启网关，即可使用断线回执核对与恢复能力。首次安装请按下文连接自己的 relay 和 Mac 网关。

## 自托管与配对

准备一台可提供 HTTPS/WSS 的服务器，以及一台已安装 pi、可在终端正常使用模型的 Mac。两个 Node.js 服务均需要 Node.js 18 或更高版本及 npm。以下示例在各自主机的仓库根目录执行，请将 `relay.example.com` 换成你自己的域名。

### 1. 在服务器启动 relay

生成一个随机令牌（例如用密码管理器生成 32 字节随机值），在服务器和 Mac 上分别以环境变量 `GATEWAY_TOKEN` 注入**同一个值**。relay 直接读取进程环境。

```sh
npm --prefix relay ci
npm --prefix relay start
```

relay 默认监听本机的 8789 端口。让反向代理在你的域名上终结 TLS，并保留 `/pi/*` 路径和 WebSocket 升级。使用 Caddy 时，可采用以下配置。

```caddyfile
relay.example.com {
    reverse_proxy /pi/* localhost:8789
}
```

运行 `curl -fsS https://relay.example.com/pi/healthz`。返回的 `ok` 表示服务已响应，`gateway` 和 `device` 分别表示 Mac 和手机是否在线。

### 2. 在 Mac 启动 gateway

`RELAY_URL` 是 Mac 使用的 WebSocket 入口，`PAIR_BASE` 是写进二维码的 HTTPS 配对地址，两者应指向同一台 relay。示例将当前仓库作为 pi 的初始工作目录，也可将 `PI_CWD` 改为要操作的其他项目目录。

```sh
export RELAY_URL='wss://relay.example.com/pi/gateway'
export PAIR_BASE='https://relay.example.com/pi/pair'
export PI_CWD="$PWD"
npm --prefix gateway ci
npm --prefix gateway start
```

网关也支持从本机的 `gateway/.env` 逐行读取 `KEY=VALUE`，已导出的环境变量优先。如果使用该文件，请将权限限制为仅自己可读写。连接成功后，Mac 终端将显示配对二维码和链接。

### 3. 在 iPhone 配对并打开会话

在 App 的「连接 Pi」页面扫描 Mac 终端的二维码，或粘贴**完整配对链接**并点「连接」。首次配对需要完整链接，例如 `https://relay.example.com/pi/pair#<一次性配对令牌>.<网关公钥>`。App 会连接同一主机的 `wss://relay.example.com/pi/client` 并记住中继地址。已有中继地址时，也可以粘贴 `#` 后的完整配对码。

配对码单次有效，5 分钟后过期。需要新码时，重启 Mac 网关。连接后在工作区点「新建会话」，或从「最近会话」打开已有对话。

## 可以做什么

- **查找和恢复会话**。工作区和对话侧栏按工作目录显示最近 50 个会话，可按文件夹、话题或简述搜索。Mac 从各会话的当前分支提取话题与最近进展，通过加密的 `session_catalog` 返回。打开会话后可以阅读该分支的历史消息。
- **远程对话**。思考时只显示阶段提示。工具开始执行后，对话里会显示进度，点开可看每步状态和输出，回复到达后仍可回看。运行中可补充消息、停止生成，也可以处理 pi 扩展的确认请求。
- **发送图片和选择模型**。从系统照片选择器发送图片，App 会缩放为每张 2 MiB 以内的 JPEG，并在对话中显示预览。模型列表来自 Mac 上的 pi，可切换模型和思考强度。
- **屏幕与实时活动**。工作区根据可用宽度在单列和双列间切换，适配 iPhone Duo。支持调整外观与字号。内嵌的 ActivityKit 扩展可在支持的设备上显示锁屏和灵动岛活动，状态更新依赖 App 在前台或短时后台运行。

长时间后台的 APNs 推送、非图片文件附件和下载预览留待后续版本。

## 连接和数据

手机与 Mac 使用 X25519 协商密钥，经 HKDF-SHA256 派生 AES-256-GCM 密钥，加密对话、图片、RPC 结果与会话历史。relay 负责鉴权、配对和转发，可以看到连接状态。pi 的模型凭据由 Mac 管理，设备令牌和手机配对密钥保存在 iOS Keychain。配对链接仅应交给你要授权的设备。

一个 relay 同时连接一个网关和一台手机。已配对的手机在断线后会自动重连。relay 在内存中保存设备授权，重启 relay 后需要使用新的配对链接。

## 从源码运行与测试

在 Mac 上安装 XcodeGen 以及包含 iOS 27.1 或更新 SDK 的 Xcode。在[工程配置](app/project.yml) 中把 `PI_MOBILE_BUNDLE_ID` 改成自己的 Bundle ID，实时活动扩展会沿用此前缀。然后从仓库根目录生成并打开工程：

```sh
(cd app && xcodegen generate && open PiMobile.xcodeproj)
```

在 Xcode 中选择 `PiMobile` scheme。模拟器可直接运行，真机运行时为主 App 和扩展选择自己的签名团队。

安装两端 npm 依赖后，可在 Mac 上从仓库根目录运行测试。网关测试使用测试用 pi 进程。

```sh
npm --prefix relay test
npm --prefix gateway test
swift test --package-path app/Packages/PiMobileCore
```

[协议文档](docs/PROTOCOL.md) 说明消息格式和历史恢复机制。界面与 Duo 适配采用了 Whaleness 和 ZDuo 的 MIT 许可组件，版权声明随 App 一同分发。[第三方许可](app/PiMobile/ThirdPartyNotices.txt)
