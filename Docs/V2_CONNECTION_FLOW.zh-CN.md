有这两个现象，我们其实已经把范围缩得很小了。

`NSURLErrorDomain -1011` 在现在这套 V2 代码里，基本就是“HTTP 请求到了服务，但服务回了非 2xx”。不是单纯连不上网。  
对应代码在 [CodexV2PreviewClient.swift](/Users/lidong/Documents/codex-remote/CodexMobile/CodexMobile/Services/V2/CodexV2PreviewClient.swift)，它会在 `health` 或 `v2/session/resolve` 不是 200 时直接报这个错。  
而 V2 relay 的 `resolve` 端点如果没找到 live presence，会返回 404，这个逻辑在 [server.rs](/Users/lidong/Documents/codex-remote/codex-relay-rs/src/server.rs)。

最常见的真实原因是这两个之一：

1. `codexd` 还活着，但没有成功向 relay 注册 live presence  
2. 你之前成功那次对应的 V2 进程后来停了，Debug 页还在拿当前地址继续请求，于是 `/v2/session/resolve` 开始返回 404

你按下面顺序自己跑一下就行，我来帮你读结果。

**第一步：确认 V2 进程是不是还活着**

```bash
lsof -nP -iTCP:9910 -sTCP:LISTEN
lsof -nP -iTCP:9911 -sTCP:LISTEN
```

你想看到的是：
- `9910` 有 `codex-relay-rs`
- `9911` 有 `codexd`

**第二步：确认你真机要访问的地址本身是通的**

```bash
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
echo "$IP"

curl -i "http://$IP:9910/health"
curl -i "http://$IP:9911/health"
```

你想看到的应该是两个 `HTTP/1.1 200`。

**第三步：确认问题是不是卡在 `session/resolve`**

先取出 `macDeviceId`：

```bash
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
MAC_ID="$(curl --silent "http://$IP:9911/health" | python3 -c 'import sys,json; print(json.load(sys.stdin)["macDeviceId"])')"
echo "$MAC_ID"
```

然后测试 resolve：

```bash
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
MAC_ID="$(curl --silent "http://$IP:9911/health" | python3 -c 'import sys,json; print(json.load(sys.stdin)["macDeviceId"])')"

curl -i \
  -X POST "http://$IP:9910/v2/session/resolve" \
  -H 'content-type: application/json' \
  -d "{\"mac_device_id\":\"$MAC_ID\",\"phone_device_id\":\"iphone-debug\"}"
```

**怎么判断结果**

- 如果这里返回 `200`，那后端基本没问题，问题更可能是 iPhone 端地址没填对或被改回去了
- 如果这里返回 `404`，而且 body 里有类似 `presence_unavailable`，那就说明 `codexd` 没有 live presence，这几乎就是 `-1011` 的根因

**如果第三步是 404，直接这样重启 V2**

注意，这次要一直保留这个终端开着，不要关：

```bash
cd "/Users/lidong/Documents/codex-remote"
IP="$(ipconfig getifaddr en0 || ipconfig getifaddr en1)"
./scripts/dev-down.sh
RELAY_BIND_ADDR="0.0.0.0:9910" \
DAEMON_HEALTH_BIND_ADDR="0.0.0.0:9911" \
RELAY_HTTP_URL="http://$IP:9910" \
RELAY_WS_BASE_URL="ws://$IP:9910" \
./scripts/dev-up.sh
```

然后立刻再跑一次上面的 `session/resolve` 测试。

**iPhone 这边再确认一次**

在 `Open V2 Debug` 里，地址应该是这三项：

```text
Relay HTTP URL:  http://<你的IP>:9910
Relay WS URL:    ws://<你的IP>:9910
Daemon Health:   http://<你的IP>:9911/health
```

并且：
- 不要点 `Use Saved Pair`
- 不要点 `Use Local V2 Demo`

你把下面这三条命令的输出贴给我，我就能直接告诉你卡在哪一层：

```bash
lsof -nP -iTCP:9910 -sTCP:LISTEN
curl -i "http://$IP:9911/health"
curl -i -X POST "http://$IP:9910/v2/session/resolve" -H 'content-type: application/json' -d "{\"mac_device_id\":\"$MAC_ID\",\"phone_device_id\":\"iphone-debug\"}"
```
