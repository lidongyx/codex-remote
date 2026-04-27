# Codex Remote

英文版请见 [README.md](README.md)。

Codex Remote 是一个本地优先的工作区，用于让 iPhone 连接 Codex，同时把实际执行、Git 操作和仓库访问保留在你自己的 Mac 上。

本仓库只面向本地运行和自托管场景，不预设托管服务，也不依赖硬编码公共服务地址。

> 说明
> 当前仓库名是 `codex-remote`，但部分 App 名称、CLI 命令、包名、Bundle Identifier 和内部路径仍保留 `remodex` 或 `phodex`。这些兼容性命名在重命名过程中会暂时继续保留。

## 项目概览

这个仓库目前包含：

- 位于 `CodexMobile/` 的 iOS 客户端
- 位于 `web/` 的浏览器客户端
- 位于 `phodex-bridge/` 的本地 Node.js bridge
- 位于 `relay/` 的可自托管 relay
- 位于根目录 `package.json` 中的维护脚本
- 用于本地启动的 `./run-local-remodex.sh`

推荐工作流很直接：

1. 在 Mac 上启动本地 relay 和 bridge。
2. 从源码构建 iOS App。
3. 通过扫描二维码完成 iPhone 与 Mac 的首次配对。
4. 后续用手机作为 Codex 的远程客户端，而 Mac 仍是实际执行端。

## 运行前提

- 主要本地工作流建议使用 macOS
- Node.js 18+
- 已安装并可在 `PATH` 中访问的 [Codex CLI](https://github.com/openai/codex)
- 如果要从源码构建 iOS App，需要 Xcode 16+
- 需要一台 iPhone 用于真机配对和测试
- 如果要通过 Cloudflare Tunnel 远程访问 Web 端，需要 Docker 和一个接入 Cloudflare 的域名

## 快速开始：连接方式 1 本地配对

连接方式 1 是当前主要可用流程。它会在你的 Mac 上启动本地 relay 和 Node.js bridge，然后通过 bridge 打印出来的二维码，把 iPhone App 配对到这台 Mac。

### 1. 克隆并安装 Node 依赖

在仓库根目录执行：

先安装 bridge 和 relay 的 Node 依赖：

```sh
npm run bootstrap:node
```

这会分别安装 `phodex-bridge/` 和 `relay/` 的依赖。

### 2. 构建并安装 iOS App

然后从源码构建 iOS App：

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

在 Xcode 中：

1. 选择你自己的签名团队。
2. 选择一台真实 iPhone 作为运行目标。
3. 将 `CodexMobile` target 构建并运行到这台设备上。

建议先把 App 安装到手机上，再启动 bridge，这样二维码出现后可以立即扫码。

### 3. 启动本地 relay 和 bridge

接着在仓库根目录启动本地开发环境：

```sh
./run-local-remodex.sh
```

这个脚本会：

- 在 `0.0.0.0:9000` 启动本地 relay
- 自动选择一个 iPhone 可访问的局域网主机名写入二维码
- 从 `phodex-bridge/` 启动源码版 bridge
- 打印 relay URL、二维码和配对码
- 让 relay 在当前终端前台保持运行，直到你按 `Ctrl+C`

如果 iPhone 访问不到自动识别的主机名，请显式传入 Mac 的局域网 IP 或 `.local` 主机名：

```sh
./run-local-remodex.sh --hostname 192.168.1.23
```

也可以直接使用根目录脚本：

```sh
npm run dev:relay
npm run dev:bridge
npm run dev:local
```

如果你要执行 bridge 生命周期命令，优先使用仓库内置 CLI，不要依赖外部全局安装的 `remodex`：

```sh
npm run bridge:status
npm run bridge:up
```

### 4. 在 iPhone 上配对

当 `./run-local-remodex.sh` 打印二维码后：

1. 保持这个终端窗口打开。
2. 确认 iPhone 和 Mac 在同一个局域网内，或者确认二维码里的 relay 主机名能被 iPhone 访问。
3. 在 iPhone 上打开 App。
4. 选择连接方式 1，并扫描终端中的二维码。
5. 如果不方便扫码，可以在 App 提示时手动输入终端中的配对码。
6. 确认 App 显示 Mac 已连接。

每次重新执行 `bridge:up` 或 `run-local-remodex.sh` 都会生成新的配对会话和二维码。旧二维码和旧配对码都应视为已失效。

### 5. 从手机使用 Codex

连接成功后：

1. 在 iOS App 中新建或打开一个会话。
2. 在提示时选择或创建本地 workspace。
3. 从手机发送 prompt。
4. 在任务运行期间保持 Mac 唤醒，并保持 bridge 运行。
5. 确认 Codex 的回复、reasoning 和工具输出会实时返回到手机。

Codex 执行、文件访问、shell 命令和 Git 操作仍然都发生在你的 Mac 本地。手机只是远程 UI。

### 6. 使用 Remodex Web

Remodex Web 是连接方式 1 的浏览器版本。它和 iOS App 一样连接本地 relay + bridge，同时仍然让 Codex 在你的 Mac 上执行。

```sh
npm install --prefix web
npm run web:dev
```

然后打开 `http://127.0.0.1:5173/`。Web UI 会优先通过本地 bridge bootstrap endpoint 自动配对；如果不可用，也可以手动粘贴二维码里的 pairing payload JSON。

在手机浏览器中，项目和 channel 列表会折叠为左侧滑动菜单，可通过 thread 标题左侧按钮呼出。

完整 Web 用法、Docker、域名和 Cloudflare Tunnel 配置见 [Docs/WEB.zh-CN.md](Docs/WEB.zh-CN.md)。远程 Tunnel 方案仍然是本地优先：Cloudflare 只暴露你的本地 Web UI、relay 和 bridge bootstrap endpoint，Codex 仍然在你自己的机器上运行。

### Windows 使用注意

- 如果 bridge 宿主机是 Windows，请使用 `npm run bridge:up` 或 `npm run bridge:run`，不要使用 `./run-local-remodex.sh`。
- 当前 Windows bridge 路径以**前台运行**为主，macOS 的 launch agent 和相关 service 管理命令不适用于 Windows。
- Windows 上的配对和 relay 路由仍然可以工作，但 bridge 进程的常驻和重启需要你自己管理。
- 详细说明见 [Docs/windows-bridge-notes.zh-CN.md](Docs/windows-bridge-notes.zh-CN.md)。

## App 内的连接方式

设置页中会看到两个连接方式：

- **连接方式 1** 是当前主要可用的本地 bridge 流程，也就是上面描述的流程。普通开发和测试优先使用它。
- **连接方式 2** 是基于 `codexd` 和 Rust relay 骨架的 V2 beta 流程。它和连接方式 1 是刻意分开的，协议上也不兼容连接方式 1 的现有配对。

除非你正在专门验证 V2 daemon 或 relay，否则请使用连接方式 1。

## 手动运行 Bridge

如果你只想单独运行 bridge：

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="ws://<你的主机>:9000/relay" npm start
```

你也可以直接在仓库根目录执行同一套 bridge CLI，而不必安装任何外部全局包：

```sh
REMODEX_RELAY="ws://<你的主机>:9000/relay" npm run bridge:up
```

## 使用源码版 Bridge 连接自托管 Relay

如果你在调试配对、断线重连或自托管 relay，建议优先使用**仓库里的源码版 bridge**，不要直接用全局安装的 `remodex`。

本仓库已经把 bridge 这个 npm 包纳入 `phodex-bridge/` 目录统一维护，并通过根目录的 `./scripts/remodex-local.js` 暴露成仓库级命令。对仓库用户来说，不需要再额外安装一个外部维护的全局 `remodex` 包。

推荐命令：

```sh
REMODEX_RELAY="wss://relay.example.com/relay" npm run bridge:up
```

这条命令会同时完成以下事情：

- 把 relay 地址写入 `~/.remodex/daemon-config.json`
- 刷新 `~/.remodex/pairing-session.json`
- 把 macOS launch agent 改成指向 `./phodex-bridge/bin/remodex.js`
- 打印当前 bridge 会话对应的最新二维码和配对码

注意：

- 在验证本地 bridge 改动时，不要直接使用全局 `remodex up`
- 全局安装版会把 launch agent 改回 `/usr/local/lib/node_modules/remodex/bin/remodex.js`
- 一旦被改回去，你实际运行的就不是当前仓库里的 bridge 代码了

你可以用下面这条命令确认 launch agent 当前指向的是哪一份 bridge：

```sh
launchctl print gui/$(id -u)/com.remodex.bridge | sed -n '1,30p'
```

当你在验证仓库内源码时，`arguments` 里应该看到类似下面的路径：

```text
/Users/<你自己>/Documents/codex-remote/phodex-bridge/bin/remodex.js
```

如果你需要重新配对，请始终使用**刚刚那一次 `up` 打印出来的最新二维码或配对码**。每次重新执行 `up` 都会生成新的 pairing session，之前的码都应视为失效。

## 本地流程排查

- **扫码后手机连不上**：确认 Mac 和 iPhone 在同一网络，并尝试 `./run-local-remodex.sh --hostname <Mac 的局域网 IP>`。
- **9000 端口已被占用**：停止占用端口的进程，或改用 `./run-local-remodex.sh --port <空闲端口>`。
- **二维码失效**：重新执行 `npm run bridge:up` 或 `./run-local-remodex.sh`，扫描新打印的二维码。
- **App 连到了错误的 bridge**：先执行 `npm run bridge:status`，再从当前仓库执行 `npm run bridge:stop` 和 `npm run bridge:up`。
- **Codex 没有启动**：确认 `codex` CLI 已安装，并且 bridge 运行时所在的 shell 环境可以访问到它。

## 仓库结构

```text
.
├── CodexMobile/          iOS App 源码和 Xcode 工程
├── web/                  浏览器客户端和 Docker 打包
├── phodex-bridge/        本地 Node.js bridge 与 CLI 入口
├── relay/                可自托管的 WebSocket relay
├── Docs/                 项目说明，包含 Web 和 Tunnel 文档
├── package.json          bridge 与 relay 的根目录维护脚本
└── run-local-remodex.sh  本地 relay + bridge 启动脚本
```

## 项目状态

- 这个仓库仍在持续迭代中。
- 当前优先保证本地优先工作流。
- 部分命名和兼容细节仍在从上游代码迁移中。

## 致谢

本项目建立在 [`remodex`](https://github.com/Emanuele-web04/remodex) 这一开源项目的基础之上，原作者是 Emanuele Di Pietro。

本仓库中的不少设计思路、传输层方案以及部分实现都明显受益于上游项目。这里不是简单换名复制，但它确实建立在前人的开源工作之上。感谢原作者和所有贡献者。

如果你继续 fork、分发或二次修改本项目，请保留适用的上游版权与许可证声明。

## 许可证

本仓库采用 ISC 许可证发布，详见 [LICENSE](LICENSE)。
