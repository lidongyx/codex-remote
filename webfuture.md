# Web 版 Remodex 方案草案

## 目标

基于当前项目增加一个“类似 iOS App 的网页版客户端”，用户在 Mac 上启动本地 relay/bridge 后，直接打开本地网页即可使用 Codex 远程 UI。Web 版保持本仓库的 local-first 原则：Codex 执行、文件访问、Git 操作和工作区上下文仍发生在本机，浏览器只作为 UI 和控制端。

## 结论

可以做，而且建议先做一个渐进式 Web 客户端，而不是重写 bridge 或引入远程托管服务。当前项目已经具备 Web 版所需的大部分后端基础：

- `phodex-bridge/` 已通过 WebSocket relay 转发 JSON-RPC，并维护本地 Codex runtime、thread/turn、Git、workspace、desktop、voice 等能力。
- `relay/` 已能在本地 `0.0.0.0:9000` 跑起来，为客户端和 bridge 提供中转通道。
- `CodexMobile/` 的 Swift 代码已经把客户端职责分清：连接、配对、安全传输、线程同步、消息 timeline、composer、Git 操作和设置页都能作为 Web 版参考。

推荐执行方向：在仓库内新增一个 `web/` 前端包，并给本地 bridge 增加“打开 Web UI / 输出 Web URL”的本地入口。Web 端复用现有 relay + bridge 协议，优先实现 iOS App 的核心体验，再逐步补齐高级能力。

## 体验形态

### 推荐 MVP 体验

1. 用户在仓库根目录执行本地启动命令，例如 `npm run dev:local` 或未来的 `npm run web:dev`。
2. 本地 relay 和 bridge 启动，bridge 继续生成本地 session 与配对信息。
3. 浏览器打开 `http://localhost:<web-port>`。
4. Web UI 自动读取本机 bridge 暴露的本地配对 bootstrap，或让用户粘贴/扫码当前二维码中的 relay URL 与 session 信息。
5. 页面完成安全握手后显示 iOS App 类似布局：sidebar 会话列表、主聊天 timeline、底部 composer、连接状态、Stop 按钮。
6. 用户直接在网页发送 prompt，Codex 在本机执行，输出实时流式返回网页。

### 后续体验

- 局域网其他设备访问：可通过 `http://<mac-lan-ip>:<web-port>` 打开网页，仍连接本地 relay/bridge。
- 远程访问：推荐通过 Cloudflare Tunnel 把本机 Web UI、relay 和 bridge bootstrap 映射到用户自己的远程域名，不需要开放公网入站端口。
- PWA：加入 manifest、离线壳、桌面图标和移动端适配，让 iPad/Android/另一台电脑也能作为客户端。
- 二维码兼容：Web 页面可扫描现有 QR，也可展示“同机免扫码连接”。

## Cloudflare Tunnel 远程域名方案

### 判断

Cloudflare Tunnel 更适合“有一个远程域名，打开网页就能用”的目标。它和本项目的 local-first 模型也能兼容：Mac 仍是 Codex 执行端，Web 客户端通过 Cloudflare 域名访问 Mac 上的本地 Web/relay/bootstrap 服务，`cloudflared` 只建立出站隧道，不需要在路由器或防火墙上开放入站端口。

首选方案是 Cloudflare Tunnel + Cloudflare Access：

- Tunnel 负责把 `https://codex.example.com` 转发到本机服务。
- Access 负责登录鉴权，避免任何知道域名的人都能打开远程控制台。
- Web UI、relay WebSocket、bridge bootstrap 尽量挂在同一个 HTTPS origin 下，减少 CORS、mixed content 和 cookie/credential 问题。
- 远程域名必须是用户显式配置的自有域名，不能在仓库里硬编码生产域名。

### 推荐部署形态

建议在 `web/` 中加入 Docker + `cloudflared` sidecar 方案，用 Docker Compose 同时运行：

- `web`：构建并服务 Web 静态资源，内部端口例如 `8080`。
- `cloudflared`：官方 `cloudflare/cloudflared` 容器，使用 Tunnel token 连接 Cloudflare，并把远程域名路径转发到本机服务。
- `relay`：继续使用本仓库 `relay/`，可在宿主机或容器中运行，并通过 Tunnel 代理 WebSocket 路径。
- `bridge`：默认仍建议在宿主 Mac 进程运行，因为它需要访问本机 Codex CLI、用户文件系统、Git、Keychain/本地配置和 macOS 桌面刷新能力。

也就是说，首版 Docker 化重点放在 Web UI + Cloudflare Tunnel 入口；bridge 不建议一开始完全容器化。原因是 bridge 容器化会立刻遇到本机 workspace 挂载、Codex CLI 凭据、macOS launch agent、桌面刷新、Git SSH agent 等问题，反而会破坏当前稳定的本地工作流。

### 网络拓扑

```text
Remote browser
  │
  │ HTTPS + Cloudflare Access
  ▼
Cloudflare edge
  │ outbound tunnel
  ▼
cloudflared container on Mac
  │
  ├─ /                         → web container :8080
  ├─ /relay                    → local relay :9000
  └─ /local-web/bootstrap      → local bridge bootstrap port

local bridge on Mac ── Codex CLI / local repos
```

远程正式形态建议统一成同一个 HTTPS origin：

- `https://codex.example.com/`：Web UI。
- `wss://codex.example.com/relay`：relay WebSocket。
- `https://codex.example.com/local-web/bootstrap`：bridge pairing/bootstrap endpoint。

这样浏览器不会遇到 `https` 页面连接 `ws://` 或 `http://` 的 mixed content 限制，也能把 Access 鉴权策略集中挂在同一个 application 上。

### 建议新增文件

```text
web/
  Dockerfile
  docker-compose.cloudflare.yml
  cloudflare/
    config.example.yml
    README.md
```

### Dockerfile 草案

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
```

如果 Web 包使用 pnpm 或 npm workspace，Dockerfile 再按最终包管理器调整；MVP 阶段可以先保持 `web/` 独立 npm 包，减少根目录构建耦合。

### Docker Compose 草案

```yaml
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    expose:
      - "8080"

  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run --token ${CLOUDFLARE_TUNNEL_TOKEN:?set CLOUDFLARE_TUNNEL_TOKEN}
    depends_on:
      - web
```

推荐优先使用 Cloudflare Dashboard 创建 remotely-managed tunnel，然后复制 token 到本机 `.env`。Cloudflare 官方也建议 Docker 场景优先使用 remotely-managed tunnel；本地 `config.yml` 方案更适合调试、测试或 legacy 配置。

### Cloudflare Tunnel Ingress 草案

如果采用 remotely-managed tunnel，下面这些 public hostname 规则在 Cloudflare Dashboard 里配置：

```text
codex.example.com                  → http://web:8080
codex.example.com/relay            → http://host.docker.internal:9000/relay
codex.example.com/local-web/*      → http://host.docker.internal:8787
```

如果采用 locally-managed tunnel，可以把同等规则放到 `web/cloudflare/config.example.yml`：

```yaml
tunnel: <tunnel-uuid>
credentials-file: /etc/cloudflared/<tunnel-uuid>.json

ingress:
  - hostname: codex.example.com
    path: /relay
    service: http://host.docker.internal:9000
  - hostname: codex.example.com
    path: /local-web/*
    service: http://host.docker.internal:8787
  - hostname: codex.example.com
    service: http://web:8080
  - service: http_status:404
```

WebSocket 通常可通过 Cloudflare Tunnel 的 HTTP 反向代理路径转发，但实现时需要用浏览器实际验证 `wss://codex.example.com/relay` 能稳定连到当前 `relay/` 的 WebSocket endpoint。

### 远程访问执行路径

1. 先实现本地 Web UI，确认 `localhost` 能完成配对和聊天。
2. 在 Cloudflare Dashboard 创建 remotely-managed tunnel，并绑定用户自己的域名，例如 `codex.example.com`。
3. 增加 `web/Dockerfile` 和 `web/docker-compose.cloudflare.yml`，运行 Web 静态服务和 `cloudflare/cloudflared` sidecar。
4. 配置 Cloudflare Access application，至少限制到指定邮箱、组织账号或一次性 PIN；默认不允许匿名公网访问。
5. 配置 Tunnel public hostname：`/` 到 Web UI、`/relay` 到本地 relay、`/local-web/*` 到 bridge bootstrap。
6. 让 bridge bootstrap endpoint 支持显式远程模式，但默认仍只监听 loopback；远程模式必须依赖 Access 或额外一次性 token。
7. 在 Web 设置页增加“远程访问状态”：当前 origin、relay URL、bootstrap URL、是否 Cloudflare Access、是否安全通道已启用。
8. 验证远程域名下的新建线程、发送 prompt、Stop、重连、WebSocket keepalive 和 secure transport。

### 安全边界

- `CLOUDFLARE_TUNNEL_TOKEN` 是敏感凭据，只能放 `.env` 或系统 secret，不提交到仓库。
- 远程域名前必须启用 Cloudflare Access；没有 Access 时，这相当于把本地 Codex 控制台暴露到公网。
- bridge bootstrap endpoint 不能无鉴权暴露到公网；远程访问必须依赖 Access 身份或额外一次性 token。
- relay `sessionId`、pairing payload、private key、notification secret 不写入容器日志。
- Cloudflare WAF、rate limiting、bot protection 可以作为外层防护，但不能替代应用层配对和 secure transport。
- 域名、Tunnel token、Access policy 都属于用户本地配置或 Cloudflare 控制台配置，仓库中只保留 example，不提交真实值。

## 技术路线

### 前端栈

建议新增 `web/`：

- Vite + React + TypeScript：启动快、适合本地开发，和现有 Node 工具链兼容。
- Zustand 或 Redux Toolkit：管理连接状态、threads、timeline、composer 和 pending request。
- Tailwind CSS 或 CSS Modules：快速复刻 iOS 风格，同时避免引入重 UI 框架。
- `@uiw/react-codemirror` 或轻量 markdown renderer：用于代码块、diff、命令输出和长文本展示。

不建议一开始使用 Next.js 或服务端渲染，因为当前目标是本地 UI，不需要远程部署、SEO 或后端页面渲染。

### 本地服务形态

Web 版需要两类本地入口：

- 静态 Web dev/server：服务 `web/` 产物，默认只绑定 `127.0.0.1`，用户明确开启局域网时才绑定 `0.0.0.0`。
- bridge pairing bootstrap：提供 Web UI 获取当前本地 relay URL、session 元数据、bridge 版本和安全握手材料的方式。

可选实现路径：

1. 最小侵入：`web/` 自己跑 Vite dev server，用户从 bridge 终端复制二维码/配对码到网页。
2. 推荐 MVP：在 `phodex-bridge` 增加本地 HTTP bootstrap endpoint，只监听 loopback，例如 `GET /local-web/bootstrap`，返回当前 pairing payload，但不要记录完整 `sessionId`。
3. 成熟形态：bridge 启动时同时托管 `web/dist`，打印 `http://localhost:<port>`，并支持 `npm run web:open` 自动打开浏览器。

### 协议复用

Web 客户端不应新造一套业务 API。它应复用当前 iOS 客户端已使用的 JSON-RPC 方法与事件：

- 初始化：`initialize`、`initialized`。
- 会话列表与读取：`thread/list`、`thread/read`、`thread/name/set`、`thread/archive`、`thread/unarchive`。
- turn 生命周期：`turn/start`、`turn/interrupt`，并处理 `turn/started` 可能缺少可用 `turnId` 的情况。
- timeline 增量：复用 iOS 的 item-aware 归并策略，避免只按 `turnId` 合并导致消息扁平化或重排。
- Git：`git/status`、`git/diff`、`git/commit`、`git/push`、`git/pull`、`git/branches` 等。
- Workspace：`workspace/revertPatchPreview`、`workspace/revertPatchApply`，以及后续 workspace/list/open/create 能力。
- Account：`account/status/read`、`account/login/start`、`account/login/cancel`、`account/logout`。

需要在 Web 端实现一个 `CodexClient` 层，对应 Swift 里的 `CodexService`：

- 管理 WebSocket 生命周期、重连、心跳和 pending requests。
- 管理 JSON-RPC request/response/notification。
- 管理 secure transport 握手和 envelope 加解密。
- 统一派发 thread、turn、plan、structured input、Git、workspace 等事件。

### 安全传输

当前 iOS 客户端和 bridge 已有安全握手与 encrypted envelope。Web 版有两种实现选择：

1. MVP 快速路径：同机 `localhost` 模式允许“本地开发安全模式”，但只能用于本机回环访问，不能扩展到局域网设备。
2. 正式路径：用 Web Crypto API 复刻 Swift 安全传输逻辑，完成 `clientHello`、`serverHello`、client auth、`secureReady` 和 encrypted envelope。

建议执行时优先走正式路径，原因是：

- 不能为了 Web 版削弱现有配对模型。
- 局域网访问、PWA 和跨设备使用都依赖同一安全模型。
- 现有 `phodex-bridge/src/secure-transport.js` 可作为 bridge 侧真值，Swift 的 `CodexService+SecureTransport.swift` 可作为客户端行为参考。

Web 端不得在 console 或日志中输出完整 relay `sessionId`、pairing secret、private key 或 bearer-like 标识。调试日志只保留短 hash 或前后截断值。

## UI 信息架构

Web 版第一阶段复刻 iOS App 的三段式核心体验：

- Sidebar：连接状态、新建聊天、线程列表、归档入口、搜索、运行中/完成 badge。
- Conversation：消息 timeline、reasoning 折叠、工具调用、命令输出、计划卡片、结构化用户输入卡片、diff 摘要。
- Composer：文本输入、发送、Stop、模型/推理强度入口、文件 mention、技能 mention、附件预览。

桌面浏览器默认双栏布局，窄屏时切换成 iOS 类似的 sidebar overlay。视觉上可以参考 iOS 的 glass/capsule 风格，但 Web 实现应以可维护 CSS token 为主，不直接复制 SwiftUI 结构。

## 数据模型迁移

建议将 iOS 中分散但稳定的客户端模型整理成 TypeScript 类型：

- `RPCMessage` -> `JsonRpcMessage`、`JsonRpcRequest`、`JsonRpcResponse`、`JsonRpcNotification`。
- `CodexMessage` -> timeline item 类型，保留 item id、turn id、role、kind、presentation metadata、ordering。
- `CodexRateLimitStatus`、`CommandExecutionDetails`、`AIChangeSetModels` -> Web 侧只迁移 UI 需要的字段。
- `TurnTimelineReducer` -> TypeScript reducer，优先保证 item-aware 合并、late delta 合并、turn-less 活动过滤。

不要让 React 组件直接解析 bridge 原始 payload。解析、归并和容错逻辑应放在 `web/src/services/` 或 `web/src/domain/`，保持 views 单一职责。

## 执行路径

### 阶段 0：协议盘点与边界确认

- 从 `CodexMobile/CodexMobile/Services/CodexService*.swift` 列出 Web MVP 必需 RPC 方法、通知和事件 shape。
- 从 `phodex-bridge/src/secure-transport.js` 与 `CodexService+SecureTransport.swift` 提取 Web Crypto 需要的算法、字段和状态机。
- 明确 Web 首版只支持本地 relay/bridge，不引入远程部署域名、托管 relay 或生产公网配置。

### 阶段 1：Web 项目骨架

- 新增 `web/package.json`、`web/src/`、`web/index.html`、`web/vite.config.ts`。
- 根目录增加脚本：`web:dev`、`web:build`、`web:preview`。
- 建立基础页面：连接页、sidebar、conversation、composer、settings shell。
- 建立 design token：颜色、圆角、阴影、字体、spacing、状态色。

### 阶段 2：连接与配对

- 新增 `web/src/services/codexClient.ts`，实现 WebSocket、JSON-RPC pending map、request timeout、notification dispatch。
- 实现 pairing bootstrap：先支持手动输入 relay URL/session payload，再接 bridge 本地 endpoint。
- 实现 secure transport：Web Crypto 生成客户端密钥、完成握手、加解密 envelope、重连后 trusted reconnect。
- 实现连接状态 UI：connecting、secure handshake、connected、reconnecting、disconnected、unsupported bridge/app version。

### 阶段 3：线程与聊天 MVP

- 实现 `initialize` / `initialized`。
- 实现 `thread/list`、`thread/read`，加载 active 和 archived 线程。
- 实现 `turn/start`，发送用户 prompt。
- 实现 timeline reducer，渲染 user/assistant/reasoning/tool/command rows。
- 实现 Stop：优先用本地 active turn id；缺失时通过 `thread/read` 回查 interruptible turn，再发 `turn/interrupt`。

### 阶段 4：恢复与一致性

- 实现 reconnect 后 active turn rehydrate，让 Stop 按钮恢复可见。
- 实现 late delta 合并，不生成假的额外 “Thinking...” 行。
- 忽略 turn 已 inactive 后到达的 turn-less activity。
- 保留 item-aware history reconciliation，不退回到只按 `turnId` 匹配。
- 本地持久化最近连接、当前线程、本地草稿和 UI 偏好到 IndexedDB 或 localStorage。

### 阶段 5：工作区、Git 与高级 composer

- 实现 workspace 选择/创建/打开，保持跨 repo open/create 自动本地 context switch。
- 实现 Git toolbar：status、diff、branch、commit、push、pull、managed worktree/handoff 的第一批常用入口。
- 实现 slash command、file mention、skill mention、附件预览。
- 实现 diff sheet、revert preview/apply、change set summary。

### 阶段 6：集成到本地启动流

- bridge 启动时打印 Web URL，例如 `Web UI: http://localhost:5173` 或托管后的端口。
- `./run-local-remodex.sh` 可选启动 Web UI，但不要默认强制打开浏览器。
- 增加 `npm run web:open` 或 `npm run dev:web-local`，一次启动 relay、bridge、web。
- 文档只描述本地用法，不加入远程生产部署 runbook。

### 阶段 7：验证

- Node 层：补 `phodex-bridge` bootstrap endpoint 单测，确保不记录完整 `sessionId`。
- Web 层：为 JSON-RPC client、secure transport、timeline reducer、Stop fallback 写 Vitest 单测。
- 端到端：用本地 relay/bridge 和浏览器验证新建线程、发送 prompt、Stop、重连、thread/read 恢复、Git status。
- 不主动跑 Xcode 测试；Web 版改动默认只跑 Node/Web 相关测试。

## 关键风险与处理

- 安全握手复杂：优先把 secure transport 做成独立模块和测试夹具，避免混入 React 状态。
- 事件 shape 分散：先从 Swift reducer 和 bridge handler 提取最小兼容 schema，不在 UI 层做临时判断。
- Timeline 顺序回归：Web reducer 必须保留 item-aware 策略，专门覆盖 late deltas、turn-less events 和 reconnect history merge。
- 本地端口暴露：默认只监听 loopback；开启局域网访问必须显式参数，并在 UI 显示风险提示。
- 项目职责膨胀：共享协议、加解密、reducer 放服务/领域层，React view 只负责展示和用户动作。

## 建议目录结构

```text
web/
  index.html
  package.json
  vite.config.ts
  src/
    app/
      App.tsx
      routes.tsx
    components/
      sidebar/
      timeline/
      composer/
      settings/
    domain/
      messages.ts
      threads.ts
      timelineReducer.ts
      rpcTypes.ts
    services/
      codexClient.ts
      secureTransport.ts
      pairing.ts
      persistence.ts
    styles/
      tokens.css
      globals.css
    test/
      fixtures/
```

后续如果希望 Swift 和 Web 长期共享 schema，可以再引入 `codex-proto/` 或 `proto/` 的生成链路；MVP 阶段不建议先做大规模协议生成改造。

## 首版验收标准

- 在本机启动 relay + bridge + web 后，浏览器能完成配对/连接。
- 能列出历史线程，打开线程并显示已有 timeline。
- 能新建聊天并发送 prompt，assistant 输出流式显示。
- Stop 在 `turn/started` 缺少可用 `turnId` 时仍能通过 `thread/read` fallback 生效。
- 断线重连后能恢复 active turn 状态和最新 timeline。
- 不按 selected repo 过滤 sidebar/content，保持跨 repo 线程可见。
- 不引入硬编码生产域名、托管 relay 假设或远程部署说明。
