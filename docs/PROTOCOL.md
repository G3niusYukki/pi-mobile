# Pi Mobile 协议（P0）

手机 ↔ VPS relay ↔ Mac gateway ↔ `pi --mode rpc`。外层使用 WebSocket JSON。内层沿用 Pi 的 JSONL RPC 命令和事件类型，网关提取手机需要的公开正文字段。

## 角色

- **gateway**：跑在装 pi 的 Mac 上，默认启动 `pi --mode rpc`，使新对话也能进入本机历史。需要临时会话时可显式配置 `PI_ARGS="--mode rpc --no-session"`，把 stdin/stdout 的 JSONL 转成 WSS 消息。主动连出到 relay，Mac 不需要入站端口。
- **relay**：跑在 VPS，只做鉴权、配对、消息路由。不存会话内容、不碰密钥。
- **client**：iPhone App。

## 连接与鉴权

1. gateway 用 `Authorization: Bearer <GATEWAY_TOKEN>` 连 `wss://relay.example.com/pi/gateway`。
2. gateway 发 `{"type":"pair_create"}`；relay 回 `{"type":"pair_token","token":"<32 hex>","expiresAt":...}`（TTL 5 分钟，单用）。Mac 把它显示成二维码/文本。
3. client 从 `https://relay.example.com/pi/pair#<token>.<gatewayPub>` 导出同源 `wss://relay.example.com/pi/client`，首帧发送 `{"type":"pair","token":"…","pub":"<clientPub>"}`。relay 校验后发回 `{"type":"paired","deviceToken":"<64 hex>"}`，并把客户端公钥转交给 gateway。
4. 之后 client 用 `Authorization: Bearer <deviceToken>` 连 `/pi/client`，relay 直接放行并把缓存的状态快照推给它。
5. 一条 relay 同时只允许一个 gateway 和一个 device；重复连接踢掉旧连接。

## 消息

以下为解密后的逻辑字段。线上 `rpc` 的 `command` 封装在 `sealed` 中，`rpc_response` 和 `event` 的正文也通过 `sealed` 传输。`status` 是 relay 可以读取的连接状态。

client → gateway：

```json
{"type":"rpc","id":"req-1","command":{"type":"prompt","message":"...","id":"req-1"}}
```

gateway → client：

```json
{"type":"rpc_response","id":"req-1","success":true,"data":{...}}
{"type":"event","event":{ "type":"message_update", "...": "..." }}
{"type":"status","state":"running|idle|unknown"}
```

- 网关将原生命令写入 Pi 的 stdin，并将响应关联到手机请求的 `id`。聊天与工具事件仅发送公开文字和生命周期字段，剔除结构化思考块、签名及原始快照。手机也从旧版网关的事件中只提取文字块。
- client 必须订阅事件后再发 prompt；`agent_settled` 作为「本轮自动工作结束」的信号。
- 图片附件走 `prompt.images`（base64 + mimeType），网关按解码后的数据大小限制为每张 2 MiB。

## 会话切换、恢复与历史

以下是端到端加密载荷内的命令；线上通过 `sealed` 传输。

- `prompt` 始终携带 `streamingBehavior: "steer"`，因此在 Pi 已开始回复的竞态下也能接受补充消息。客户端保留当前流式回复的身份，并按响应的 `disposition` 处理开始、排队或直接完成的命令。
- 客户端使用带唯一 `id` 的原生 `switch_session` / `new_session`，收到成功且未 `cancelled` 的响应后才加载目标历史。切换中的超时不会被当作失败重放；结果不明时暂停新的发送与切换，保留原请求身份供重连核对。
- 恢复时发送 `get_state`，可携带 `afterSessionChangeId`。网关等待已接收的原生会话变更全部响应后再读取状态，返回 `data.sessionBarrier: true` 与相同的 `sessionBarrierId`。客户端只用匹配的屏障或原生响应结束不确定的切换。扩展 UI 审批回复仍直接转发，避免等待审批的切换被锁住。此恢复能力需要 App 与网关同时更新。
- 模型与思考强度共用一个写入队列。客户端按原生响应确认设置，恢复时可在 `get_state` 中携带 `afterSettingChangeId`。当前网关等已收到的 `set_model` / `set_thinking_level` 得到 Pi 的响应，再读取实际设置并回传相同的 `data.settingBarrierId`。旧网关没有这个字段时，客户端等待原请求响应或读到与请求一致的设置。
- `session_catalog` 是只读网关命令，返回 `data.sessions`，最多 50 项，按最近活动排序。每项包含 `path`、完整工作目录 `cwd`、毫秒时间戳 `mtime`、话题 `title` 和简述 `summary`。网关在 Mac 本地从当前分支提取文字，手机按 `cwd` 分组，使用 `path` 打开会话。旧版 `session_list` 仅返回文件元数据。
- `session_history` 是网关扩展命令：`{ "type": "session_history", "id": "…", "sessionPath": "…", "anchorId": "可选的上一条已知持久消息 ID" }`。成功返回 `{ sessionPath, messages, hasEarlierMessages }`；文件不存在、路径非法等错误返回 `success: false`，不伪装为空会话。
- 历史仅包含当前分支。消息含稳定 `id`、`role`、完整 `text`；工具消息另含 `toolTitle` 及已有记录的 `toolCallId`，用于合并流式结果。默认返回最近 80 条；同分支的旧 `anchorId` 可将窗口扩展到该消息，使客户端保留阅读前缀。其他分支或无效锚点不会引入旧分支内容。
- 正文不做展示层截断；整体传输仍受 relay 的 12 MiB WebSocket 载荷上限约束。历史窗口不是无限量分页接口。

## 安全

- WSS 由 Caddy 终结 TLS；relay 只监听 127.0.0.1。
- GATEWAY_TOKEN 至少 32 字节随机值，gateway 与 relay 各自配置，不进代码库。
- deviceToken 由 relay 随机生成，client 存 Keychain。
- 正文、附件、当前版会话目录和历史记录在手机与 Mac 之间使用 X25519、HKDF-SHA256 和 AES-256-GCM 加密。relay 可以看到连接状态、外层消息类型及大小。旧版兼容的 `session_list` 还包含文件路径和工作目录等元数据。

## 与 zcode-mobile 的对应

| zcode-mobile | Pi Mobile |
|---|---|
| ZCode 二进制帧 / CRC32 / IPC 值编码 | WebSocket JSON（无需自定义帧） |
| Z.ai 账号登录 + JWT | gateway 配对码 + 设备令牌（pi 凭证只在 Mac） |
| Conversation V4 channel | pi RPC events + messages |
| Controller（审批 / 模型 / 停止） | `abort` / `set_model` / `set_thinking_level` / `extension_ui_response` |
| APNs + Cloudflare Worker | P2：APNs + 同一台 VPS（仅需加推送网关） |
