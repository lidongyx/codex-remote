# Remodex Web

Remodex Web 是连接方式 1 的本地优先网页版客户端。它和 iOS App 使用同一套 relay + bridge 配对方式，只是把远程 Codex 体验渲染到浏览器里。

## 哪些东西运行在哪里

- Web UI 在开发时由 Vite 提供，远程访问时可以由 `web/` Docker 镜像提供。
- Codex 执行、文件访问、shell 命令和 Git 操作仍然运行在本地 bridge 宿主机上。
- 浏览器作为远程 UI 连接 relay，并通过现有安全传输发送加密 JSON-RPC 消息。
- bridge 会提供一个本地 bootstrap endpoint，这样浏览器和 bridge 在同一台机器上时，不需要手动粘贴二维码 JSON。

## 本地开发

首次安装依赖：

```sh
npm install --prefix web
```

启动本地 relay 和 bridge：

```sh
./run-local-remodex.sh
```

启动 Web UI：

```sh
npm run web:dev
```

打开：

```text
http://127.0.0.1:5173/
```

Web UI 会优先读取 `http://127.0.0.1:8787/local-web/bootstrap`。如果这个 endpoint 不可用，可以把 bridge 二维码里的 pairing payload JSON 粘贴到连接框里。

## Web 端基础用法

1. 从本仓库启动 relay 和 bridge。
2. 打开 Web UI。
3. 让页面通过本地 bootstrap 自动配对，或者手动粘贴 pairing payload。
4. 打开已有 thread、新建 chat，或者从本地文件夹创建项目。
5. 在底部输入框发送 prompt。输入框支持文本、图片、文本文件、模型选择、推理强度、计划模式、权限模式，以及运行时支持时的本地 skill 选择。

在手机浏览器中，项目和 channel 列表默认折叠为左侧滑动菜单，可通过标题左侧按钮呼出。

## 使用 Cloudflare Tunnel、域名和 Docker 远程访问

这套方案仍然保持本地优先：Docker 只负责提供 Web UI，`cloudflared` 负责把本地 Web UI、relay 和 bridge bootstrap endpoint 暴露到你自己的 Cloudflare 域名下。Codex 执行不会搬到 Cloudflare。

### 前提条件

- 一个接入 Cloudflare DNS 的域名。
- 一个在 Cloudflare Dashboard 中创建的 Tunnel。
- 用 Cloudflare Access 或其他认证层保护公网 hostname。
- Docker 和 Docker Compose。
- 本地 relay 和 bridge 已经在宿主机上运行。

Cloudflare 参考文档：

- [Cloudflare Tunnel 入门](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/get-started/)
- [用 Docker 运行 cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/deployment-guides/docker/)
- [Tunnel public hostnames](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/routing-to-tunnel/)
- [Cloudflare Access applications](https://developers.cloudflare.com/cloudflare-one/applications/)

### 1. 启动本地 relay 和 bridge

在仓库根目录执行：

```sh
./run-local-remodex.sh
```

保持这个进程运行。默认情况下，relay 使用 `9000` 端口，bridge bootstrap endpoint 使用 `8787` 端口。

### 2. 创建 remotely managed Tunnel

在 Cloudflare Dashboard 中：

1. 进入 Zero Trust。
2. 创建 Tunnel。
3. 选择 `cloudflared` connector。
4. 复制生成的 tunnel token。
5. 添加一个 public hostname，例如 `codex.example.com`。

按下面顺序配置 public hostname routes：

```text
codex.example.com/relay*       -> http://host.docker.internal:9000
codex.example.com/local-web/*  -> http://host.docker.internal:8787
codex.example.com              -> http://web:8080
```

如果 Dashboard 把 hostname 和 path 分开填写，就对每条 route 使用同一个 hostname，并把 `/relay*` 和 `/local-web/*` 填到 path 字段。根路径 route 指向 Docker 服务名 `web`。

### 3. 保护公网 hostname

启动 tunnel 之前，请先为这个 public hostname 创建 Cloudflare Access application。可以限制为你的账号、邮箱域、身份提供商分组，或其他私有策略。

不要把这个 UI 作为无认证的公开网站暴露出去。它可以控制本地 Codex runtime。

### 4. 运行 Docker Compose

在本地创建 `web/.env`：

```sh
CLOUDFLARE_TUNNEL_TOKEN=替换成你的 token
```

从仓库根目录启动 Web 容器和 tunnel：

```sh
docker compose -f web/docker-compose.cloudflare.yml --env-file web/.env up --build
```

然后打开受保护的域名：

```text
https://codex.example.com/
```

### 5. 验证流程

1. 确认 Cloudflare Access 会先要求登录。
2. 登录后确认 Web UI 能正常加载。
3. 确认状态变为 connected。
4. 打开或创建一个 thread，发送一个小 prompt。
5. 任务运行期间保持本地 Mac 唤醒。

### 6. 运维注意事项

- 不要提交 `.env`、tunnel token、pairing payload、relay session ID 或私有域名。
- 如果 token 泄露，立即轮换 tunnel token。
- 建议为 Web UI 使用专用子域名。
- 如果 Docker 运行在 Linux 上且 `host.docker.internal` 不可用，请保留 `web/docker-compose.cloudflare.yml` 里的 `host-gateway` 映射，或把 route 的 service target 改成本机局域网 IP。
- 如果浏览器无法连接 relay，检查 `/relay*` route 是否指向 relay origin，并确认 tunnel 支持 WebSocket 流量。
