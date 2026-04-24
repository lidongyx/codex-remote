# Windows Bridge 使用说明

当前项目仍以 Mac 为主路径，但 bridge 在 Windows 上可以跑通核心的配对和 relay 流程。

## 可用范围

- 用 `npm run bridge:up` 或 `npm run bridge:run` 前台启动 bridge
- 通过 Windows 兼容的启动路径拉起 `codex app-server`
- 在 iPhone App 里扫码配对
- 使用 relay 传输，并把可信设备状态持久化到 `~/.remodex`

## 不建议的做法

- 不要在 Windows 上使用 `./run-local-remodex.sh`。这条脚本是给本地 Mac 工作流准备的。
- 不要把 macOS 的 launch agent 命令当成 Windows 用法。`bridge:start`、`bridge:restart`、`bridge:stop`、`bridge:status` 主要对应 macOS service 流程。
- 不要默认认为 Mac 专属的桌面能力在 Windows 上也可用。

## 推荐的 Windows 使用方式

1. 安装 Node.js 18+，并确认 `codex` 已经在 `PATH` 中可用。
2. 启动一个 iPhone 可以访问到的 relay。
3. 把 `REMODEX_RELAY` 设成该 relay 地址。
4. 以前台方式启动 bridge：

```sh
REMODEX_RELAY="ws://<your-host>:9000/relay" npm run bridge:up
```

5. 配对和使用期间保持这个终端窗口处于运行状态。

## 运行注意事项

- 内建的后台 daemon 路径目前只支持 macOS。
- 如果你希望 Windows 上的 bridge 在注销、重启或关闭终端后继续存活，需要自行接入进程管理器或 Windows service 包装层。
- 如果你重启了 bridge 并生成了新的 pairing session，请重新扫描最新的二维码或配对码。

## 相关文档

- [README.zh-CN.md](../README.zh-CN.md)
- [Docs/self-hosting.md](self-hosting.md)
- [Docs/windows-bridge-notes.md](windows-bridge-notes.md)
