# 联机服务器（自建大厅 + 专用房间）

联机用的是 Azahar（Citra）的房间协议：每个房间模拟一片 3DS 本地无线网络，游戏之间的数据包经房间转发（ENet over UDP）。本目录提供两样东西：

| 组件 | 作用 | 端口 |
|---|---|---|
| `lobby/` | **大厅**：列出公开房间，给房间和玩家发 JWT。兼容 Azahar 桌面版/安卓版的 “Web API URL”。 | TCP 5000（HTTP） |
| `room/` | **专用房间**：官方 `azahar-room` 程序，跑在 VPS 上，24 小时在线，不依赖某台手机。 | UDP 24872 |

不部署服务器也能联机：同一 Wi-Fi 下 App 会自动发现房间；外网可以直连房主的 IP（房主需做 UDP 端口转发）。服务器只是让外网联机更省事、更稳定。

## 一键部署（Docker）

```bash
cd Server
cp .env.example .env        # 把 PUBLIC_ADDRESS 改成 VPS 的公网 IP 或域名
docker compose up -d --build
```

防火墙放行 **TCP 5000** 和 **UDP 24872**。第一次构建 `room` 镜像要编译 Azahar，大约 10–20 分钟。

在 App 里：设置 › 联机 › 大厅服务器 填 `http://你的服务器:5000`。Azahar 桌面版：设置 › Web › Web API URL 填同一个地址，就能在同一个大厅里看到彼此的房间。

> Azahar 的 HTTP 客户端只支持明文 `http://`（它直接用主机和端口建连接），所以大厅不要放在 HTTPS 后面。

## 不用 Docker

```bash
pip install "pyjwt[crypto]"
LOBBY_PORT=5000 LOBBY_PUBLIC_ADDRESS=你的公网IP python3 lobby/lobby.py
```

房间服务器用 Azahar 官方的 `azahar-room`（Azahar 发布页的 Linux 包里就有，或按 `room/Dockerfile` 编译）：

```bash
azahar-room --room-name "我的房间" --port 24872 --max_members 16 \
  --preferred-app "Any" --preferred-app-id 0 \
  --web-api-url http://127.0.0.1:5000 --username server --token 任意令牌
```

## 大厅配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `LOBBY_PORT` | 5000 | 监听端口 |
| `LOBBY_DATA_DIR` | ./data | 存放 JWT 签名密钥 |
| `LOBBY_USERS_FILE` | 空 | 设置后变成**封闭大厅**：文件每行 `用户名:令牌`，只有这些账号能公开房间。为空时是**开放大厅**，任何非空令牌都行（App 会自动生成一个）。 |
| `LOBBY_ROOM_TTL` | 60 | 房间多少秒没心跳就下线（房间每 15 秒发一次） |
| `LOBBY_TRUST_PROXY` | 空 | 设为 `1` 时从 `X-Forwarded-For` 取客户端地址 |
| `LOBBY_PUBLIC_ADDRESS` | 空 | 从内网/本机地址注册的房间（比如同一台 VPS 上 Docker 里的房间）对外显示成这个地址 |

## 接口（与 Citra/Azahar Web API 兼容）

```
POST   /jwt/internal              头 x-username / x-token → JWT
POST   /jwt/external/<房间UID>     Bearer JWT → 房间专用 JWT（房间用来验证玩家身份）
GET    /jwt/external/key.pem      公钥
GET    /lobby                     房间列表（匿名）
POST   /lobby                     公开一个房间
POST   /lobby/<id>                心跳 + 更新玩家列表
DELETE /lobby/<id>                下线房间
GET    /health                    状态
```

已在本仓库的主机测试里验证：App 的联机层和官方 `azahar-room` 都能向这个大厅注册、心跳、被列出、被加入（见 `scripts/run-host-tests.sh`）。
