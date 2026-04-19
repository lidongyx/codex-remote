# Codex Remote

Codex Remote is a local-first workspace for controlling Codex from iPhone while keeping execution, git operations, and repository access on your own Mac.

Codex Remote 是一个本地优先的工作区，用于让 iPhone 连接 Codex，同时把实际执行、Git 操作和仓库访问保留在你自己的 Mac 上。

This repository focuses on local and self-hosted workflows. It does not assume a hosted production service or hardcoded public endpoint.

本仓库只面向本地运行和自托管场景，不预设托管服务，也不依赖硬编码公共服务地址。

> Note
> The repository name is `codex-remote`, while some app names, CLI commands, package names, bundle identifiers, and internal paths still use `remodex` or `phodex`. Those compatibility names remain in place during the ongoing rename.
>
> 说明
> 当前仓库名是 `codex-remote`，但部分 App 名称、CLI 命令、包名、Bundle Identifier 和内部路径仍保留 `remodex` 或 `phodex`。这些兼容性命名在重命名过程中会暂时继续保留。

## English

### Overview

This repository currently contains:

- an iOS client in `CodexMobile/`
- a local Node.js bridge in `phodex-bridge/`
- a self-hostable relay in `relay/`
- root maintenance scripts in `package.json`
- a local bootstrap script in `./run-local-remodex.sh`

The intended flow is simple:

1. Start the local relay and bridge on your Mac.
2. Build the iOS app from source.
3. Pair the iPhone with the Mac by scanning the QR code.
4. Use the phone as a remote Codex client while the Mac remains the execution host.

### Prerequisites

- macOS for the primary local workflow
- Node.js 18+
- [Codex CLI](https://github.com/openai/codex) installed and available in `PATH`
- Xcode 16+ if you want to build the iOS app from source
- an iPhone for on-device pairing and testing

### Quick Start

Install Node dependencies for the bridge and relay:

```sh
npm run bootstrap:node
```

Build the iOS app from source:

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

In Xcode:

1. Select your signing team.
2. Build the `CodexMobile` target onto your device.

Start the local development stack from the repository root:

```sh
./run-local-remodex.sh
```

You can also use the root scripts directly:

```sh
npm run dev:relay
npm run dev:bridge
npm run dev:local
```

After startup:

1. Open the app on your iPhone.
2. Scan the QR code shown in the terminal from inside the app.
3. Start a thread and verify that Codex responses stream back through your Mac.

If you only want to run the bridge manually:

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="ws://<your-host>:9000/relay" npm start
```

### Repository Layout

```text
.
├── CodexMobile/          iOS app source and Xcode project
├── phodex-bridge/        local Node.js bridge and CLI entrypoint
├── relay/                self-hostable WebSocket relay
├── Docs/                 project notes and supplementary docs
├── package.json          root scripts for bridge and relay maintenance
└── run-local-remodex.sh  local launcher for relay + bridge
```

### Project Status

- This is still an actively evolving codebase.
- Local-first behavior is the priority.
- Some naming and compatibility details are still being migrated from upstream.

### Acknowledgements

This project builds on the open-source work of [`remodex`](https://github.com/Emanuele-web04/remodex) by Emanuele Di Pietro.

Many design decisions, transport ideas, and parts of the implementation originated from that upstream project. This repository is not just a rebranded copy, but it clearly benefits from that earlier work. Thanks to the original author and contributors.

If you fork, redistribute, or continue adapting this codebase, keep the applicable upstream copyright and license notices intact.

### License

This repository is distributed under the ISC license. See [LICENSE](LICENSE).


## 中文说明

### 项目简介

这个仓库目前包含：

- 位于 `CodexMobile/` 的 iOS 客户端
- 位于 `phodex-bridge/` 的本地 Node.js bridge
- 位于 `relay/` 的可自托管 relay
- 位于根目录 `package.json` 中的维护脚本
- 用于本地启动的 `./run-local-remodex.sh`

推荐工作流很直接：

1. 在 Mac 上启动本地 relay 和 bridge。
2. 从源码构建 iOS App。
3. 通过扫描二维码完成 iPhone 与 Mac 的首次配对。
4. 后续用手机作为 Codex 的远程客户端，而 Mac 仍是实际执行端。

### 运行前提

- 主要本地工作流建议使用 macOS
- Node.js 18+
- 已安装并可在 `PATH` 中访问的 [Codex CLI](https://github.com/openai/codex)
- 如果要从源码构建 iOS App，需要 Xcode 16+
- 需要一台 iPhone 用于真机配对和测试

### 快速开始

先安装 bridge 和 relay 的 Node 依赖：

```sh
npm run bootstrap:node
```

然后从源码构建 iOS App：

```sh
cd CodexMobile
open CodexMobile.xcodeproj
```

在 Xcode 中：

1. 选择你自己的签名团队。
2. 将 `CodexMobile` target 构建并安装到真机。

接着在仓库根目录启动本地开发环境：

```sh
./run-local-remodex.sh
```

也可以直接使用根目录脚本：

```sh
npm run dev:relay
npm run dev:bridge
npm run dev:local
```

启动之后：

1. 在 iPhone 上打开 App。
2. 在 App 内扫描终端中的二维码。
3. 新建会话，确认 Codex 的响应可以经由你的 Mac 实时返回到手机。

如果你只想单独运行 bridge：

```sh
cd phodex-bridge
npm install
REMODEX_RELAY="ws://<你的主机>:9000/relay" npm start
```

### 仓库结构

```text
.
├── CodexMobile/          iOS App 源码和 Xcode 工程
├── phodex-bridge/        本地 Node.js bridge 与 CLI 入口
├── relay/                可自托管的 WebSocket relay
├── Docs/                 项目说明和补充文档
├── package.json          bridge 与 relay 的根目录维护脚本
└── run-local-remodex.sh  本地 relay + bridge 启动脚本
```

### 项目状态

- 这个仓库仍在持续迭代中。
- 当前优先保证本地优先工作流。
- 部分命名和兼容细节仍在从上游代码迁移中。

### 致谢

本项目建立在 [`remodex`](https://github.com/Emanuele-web04/remodex) 这一开源项目的基础之上，原作者是 Emanuele Di Pietro。

本仓库中的不少设计思路、传输层方案以及部分实现都明显受益于上游项目。这里不是简单换名复制，但它确实建立在前人的开源工作之上。感谢原作者和所有贡献者。

如果你继续 fork、分发或二次修改本项目，请保留适用的上游版权与许可证声明。

### 许可证

本仓库采用 ISC 许可证发布，详见 [LICENSE](LICENSE)。
