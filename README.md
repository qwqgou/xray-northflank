# xray-northflank

在 **Northflank 免费层**上跑最新一代 Xray（VLESS + XHTTP + TLS）的一键部署项目，
用来替换已经过时的 [`V2-for-Koyeb`](https://github.com/qwqgou/V2-for-Koyeb)
（nginx + WebSocket + **v2ray-core**）。

> 一句话结论：**VLESS + Reality 在 Northflank 免费层上跑不起来**，因为 Northflank
> 的普通服务端口只公开 HTTP/HTTP2，且 TLS 在它自己的边缘负载均衡器上被终结；
> 而 Reality 要求原始 TCP 直通、TLS 由 Xray 自己完成。见下面「为什么不能用 Reality」。
> 本项目给你的是**在 Northflank 上真正可行、且是当前最新一代**的协议组合。

---

## 目录

- [为什么不能用 VLESS + Reality](#为什么不能用-vless--reality)
- [这个项目做了什么](#这个项目做了什么)
- [和你原来的项目对比](#和你原来的项目对比)
- [部署到 Northflank](#部署到-northflank)
- [环境变量](#环境变量)
- [客户端配置](#客户端配置)
- [你真的想要 Reality 怎么办](#你真的想要-reality-怎么办)
- [本地运行与验证](#本地运行与验证)
- [故障排查](#故障排查)
- [安全说明](#安全说明)
- [免责声明](#免责声明)

---

## 为什么不能用 VLESS + Reality

我去查了 Northflank 官方文档，结论是硬性的，不是配置问题：

**1. 普通服务端口只能公开 HTTP / HTTP2，TCP 和 UDP 不能公开。**

| Protocol | Uses | Public or VPC ingress? |
| --- | --- | --- |
| HTTP(S)/1.1 | Common web servers, websockets | Yes |
| HTTP(S)/2 | Modern web servers, gRPC, websockets | Yes |
| TCP | Common applications | **No** |
| UDP | Real-time communication, media and game servers, VoIP, DNS | **No** |

> Public ports allow your application to receive requests from clients on the
> internet. **Only HTTP and HTTP/2 ports can be publicly exposed.**
>
> — [Configure ports](https://northflank.com/docs/v1/application/network/configure-ports)

**2. TLS 在 Northflank 边缘就被终结了，容器里收到的是明文 HTTP。**

> HTTPS requests are terminated at the edge load-balancer and the request is
> then routed internally via Northflank's network. Northflank will expose your
> HTTP ports publicly on ports 80 and 443.
>
> — [Networking on Northflank](https://northflank.com/docs/v1/application/network/networking-on-northflank)

**这两条直接判了 Reality 死刑**，原因如下：

Reality 的工作方式是：客户端发一个真实浏览器的 TLS ClientHello 给**服务器 IP 的
原始 TCP 连接**，由 **Xray 自己**完成 TLS 握手——如果握手里的 SNI 不是你的域名
（也就是被探测了），Xray 就把这条连接**原样转发**给一个真实网站（`target`），
让探测者看到一个真实的 TLS 证书和页面。它必须满足：

1. 客户端能直连服务器的 **原始 TCP 端口**；
2. **TLS 握手必须由 Xray 亲自处理**，中间不能有人替它握手。

在 Northflank 免费层上：

- 第 1 条不成立 —— 你拿不到原始 TCP 端口；
- 第 2 条不成立 —— 客户端握手的是 **Northflank 边缘的证书**，Xray 根本看不到那个
  ClientHello，`dest` / `serverNames` / `privateKey` 全部无从谈起。

**有人说可以开 Layer 4 负载均衡器拿到原始 TCP（这也是唯一"可能"的路子），但：**

- 它是 **Cloud → Load balancers** 下的独立付费资源，不属于开发者沙箱（免费层）的
  2 services / 2 jobs / 1 addon 配额（[Pricing](https://northflank.com/docs/v1/application/billing/pricing-on-northflank)）；
- 即使付费开了 L4，负载均衡器**不做 TLS 终结**，你还得给 Northflank 的随机 IP 搞到
  一张可信证书——**Let's Encrypt 不给裸 IP 签证书**。Reality 需要一个真实域名指向它，
  而 Northflank 分配的 `*.code.run` 域名无法指向 L4 负载均衡器。

所以：**想在 Northflank 上用 Reality，不划算也不可靠。** 同样的推理适用于
VMess/Trojan/VLESS over **原始 TCP**、Shadowsocks、Hysteria2/QUIC —— 它们都需要
Northflank 不公开的 TCP/UDP。

## 这个项目做了什么

在 Northflank 免费层的能力范围内，用**最新一代**技术栈重建同一个需求：

```
客户端 ──TLS(443)──> Northflank 边缘负载均衡器 ──明文 HTTP──> 你的容器
                                                              ├── nginx :8080
                                                              │     ├── /xhttp  ──> Xray :10000  (VLESS + XHTTP)
                                                              │     ├── /ws     ──> Xray :10000  (VLESS + WS，可选)
                                                              │     └── 其它    ──> 伪装网页
```

- **Xray-core 26.3.27**（不是已停止维护的 v2ray-core），构建时用官方 `.dgst`
  文件做 **SHA-256 校验**；
- 默认传输是 **XHTTP**（Xray 官方推荐的当前一代 HTTP 传输，取代 WebSocket 与
  SplitHTTP）。Xray 26.x 已经明确警告：*"The feature WebSocket transport ... is
  deprecated, not recommended for using and might be removed. Please migrate to
  XHTTP H2 & H3"* —— 这正是你说"协议太老了"该换的东西；
- **ECC/x25519、TLS 1.3** 由 Northflank 边缘提供，域名是 `*.code.run`，证书合法；
- **可选**开启 WebSocket 传输（`ENABLE_WS=true`），兼容老客户端，但默认关闭；
- 伪装网页 + 只放行带 `Upgrade: websocket` 的握手，主动探测者拿到的是正常网页，
  而不是 Xray 的 `400 Bad Request` 指纹；
- 可选自动生成 **Clash Meta / v2rayN / sing-box 订阅**（`SUB_ENABLE=true`）；
- 启动时自动 `nginx -t` + `xray run -test` 校验配置，配置不合法直接拒绝启动。

## 和你原来的项目对比

| | V2-for-Koyeb（原项目） | xray-northflank（本项目） |
| --- | --- | --- |
| 内核 | v2ray-core（v5 已停止维护） | **Xray-core 26.3.27**（活跃维护） |
| 传输 | WebSocket（已弃用） | **XHTTP**（当前一代），WS 可选 |
| 协议 | VMess / VLESS | VLESS |
| TLS | Koyeb/Koyeb 边缘 | Northflank 边缘（HTTP/2 + TLS 1.3） |
| 二进制校验 | 无 | 官方 SHA-256 校验 |
| 探测防护 | 无 | 伪装站点 + WS 握手白名单 + 隐藏指纹 |
| 订阅 | 无 | Clash Meta / 明文链接（可选） |
| 配置校验 | 无 | 启动前自动校验，失败即拒绝启动 |
| Reality | 不支持 | **不支持（平台限制，见上）** |

## 部署到 Northflank

### 1. 把项目推到你的 GitHub

```bash
# 在本目录下
git init
git add .
git commit -m "xray-northflank: VLESS + XHTTP for Northflank"
git branch -M main
git remote add origin https://github.com/<你的用户名>/xray-northflank.git
git push -u origin main
```

### 2. 生成 UUID（**必做**，否则每次重启都换）

```bash
# 有 Docker
docker run --rm --entrypoint /opt/xnf/genkeys.sh xray-northflank:local

# 或者本地有 Xray
xray uuid

# 或者任意在线 UUID 生成器（不要用示例里的那个）
```

### 3. 在 Northflank 创建服务

1. 登录 [app.northflank.com](https://app.northflank.com) → 选一个 project；
2. **Create Service → Deployment**；
3. **Repository**：选你刚推的仓库，分支 `main`；
4. **Build**：选 **Dockerfile**（Build context 保持默认 `/`）；
5. **Networking**：
   - 确认存在端口 **8080**，Protocol 选 **HTTP**，Accessibility 选 **Public**；
   - Northflank 会自动把 8080 映射到公网 **80 / 443** 并签发证书；
6. **Environment**（关键变量，见下一节）：

   | 变量 | 值 |
   | --- | --- |
   | `UUID` | 第 2 步生成的那个 UUID |
   | `PUBLIC_HOST` | 你的公网域名，如 `p01--xnf--abc123.code.run` |
   | `ENABLE_WS` | `false`（默认，只用 XHTTP） |

   `PUBLIC_HOST` 在服务的 **Networking** 面板里能看到，创建完第一次部署后补填、
   重新部署一次即可（也可以先不填，用日志里的提示手动拼链接）。

7. **Resources**：免费层给 0.1 vCPU / 256 MB 就够跑这个（镜像很轻）；
8. **Deploy**，然后看 **Logs** —— 日志里会直接打印**可以直接导入的 VLESS 链接**。

> ⚠️ 免费层只有 **2 个 service**。如果你原来的 `V2-for-Koyeb` 服务还占着一个，
> 先把它删掉或暂停，不然会创建失败。

### 4. 拿链接

部署成功后，日志底部长这样：

```
================================================================================
  xray-northflank is up
================================================================================
  Xray core       : Xray 26.3.27
  container port  : 8080  (Northflank maps this to public 443)
  UUID            : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  XHTTP path      : /xhttp
  public host     : p01--xnf--abc123.code.run
  [1] VLESS + XHTTP + TLS   <- recommended, current-generation transport
      vless://xxxxxxxx-...@p01--xnf--abc123.code.run:443?encryption=none&...
```

把 `vless://` 开头的整条链接复制到客户端导入即可。

## 环境变量

| 变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `UUID` | **建议必填** | 随机生成 | 用户 ID。不填则每次重启都变，链接失效 |
| `PUBLIC_HOST` | **建议必填** | 空 | 公网域名，用于生成客户端链接；填 `xxx.code.run`（不要带 `https://`） |
| `LISTEN_PORT` | 否 | `8080` | 容器监听端口，要和 Northflank 的端口配置一致 |
| `PORT` | 否 | — | 若平台注入 `PORT`，优先于 `LISTEN_PORT` |
| `XHTTP_PATH` | 否 | `/xhttp` | XHTTP 路径，建议改成自己的随机路径 |
| `ENABLE_WS` | 否 | `false` | 是否额外开启 WebSocket 传输（已弃用，仅为兼容老客户端） |
| `WS_PATH` | 否 | `/ws` | WebSocket 路径，仅在 `ENABLE_WS=true` 时有意义 |
| `XRAY_PORT` | 否 | `10000` | Xray 内部监听端口（仅本机回环），保持默认即可 |
| `SUB_ENABLE` | 否 | `false` | 是否生成订阅文件 |
| `SUB_TOKEN` | 否 | 空 | 订阅文件名令牌，**开了订阅就该设**，否则文件名可由 UUID 推出 |
| `NODE_TAG` | 否 | `NF` | 客户端里显示的节点名前缀 |

> 建议把 `XHTTP_PATH` 也改成一个只有你知道的长随机路径，例如
> `XHTTP_PATH=/a7f3c91e2b`。

## 客户端配置

**协议参数（手工配置时用）**

| 项 | 值 |
| --- | --- |
| 协议 | `vless` |
| 地址 / 端口 | 你的 `PUBLIC_HOST` / `443` |
| 用户 ID | 你的 `UUID` |
| 流控 flow | 留空（XHTTP/WS 都不能用 `xtls-rprx-vision`） |
| 传输 | `xhttp`（老客户端选 `ws`，并开 `ENABLE_WS=true`） |
| 路径 | `/xhttp`（即 `XHTTP_PATH`） |
| TLS | 开启 |
| SNI / Host | 你的 `PUBLIC_HOST` |
| ALPN | `http/1.1` |
| 指纹 | `chrome`（或 `random`） |

**支持的客户端**：v2rayN / v2rayNG（1.8.0+，需支持 XHTTP）、NekoBox、sing-box、
Shadowrocket、Clash Meta / mihomo（`xhttp-opts`）、Karing 等。

**订阅**：设 `SUB_ENABLE=true` 和 `SUB_TOKEN=<随机串>` 后重新部署，日志会打印

```
Clash Meta : https://<你的域名>/sub-xxxxxxxxxxxxxxxx.yaml
plain links: https://<你的域名>/sub-xxxxxxxxxxxxxxxx.txt
```

> 注意：订阅地址是**公开可访问**的 URL（就是你的域名），任何人拿到就能得到你的
> UUID。所以要么别开订阅，要么一定设一个足够长的 `SUB_TOKEN`，要么在 Northflank
> 的 **Security policies** 里给这个路径加 IP 白名单 / Basic Auth。

## 你真的想要 Reality 怎么办

Reality 是目前抗封锁最强的方案之一，我完全理解你为什么想要它。但它的前提是
**你能拿到一台有公网原始 TCP 端口、能自己绑证书的机器**，PaaS 免费层给不了。
可行路线，按推荐程度排序：

1. **买一台便宜 VPS，直接跑官方脚本**（最省事、Reality 体验最好）：
   ```bash
   bash <(curl -L https://github.com/crazypeace/xray-vless-reality/raw/main/install.sh) 4
   ```
   你发的第二个链接 `qwqgou/xray-vless-reality` 就是这套脚本的 fork。
   VPS 有独立 IP + 独立 443 + root，Reality 才能按设计工作。

2. **保持 Northflank 当落地，前面加一层**：例如 VPS 上跑 Reality 专线到 Northflank
   容器，或直接用 Cloudflare Tunnel / Argo 把流量引进来。复杂度和成本都上去了，
   通常不如方案 1。

3. **在 Northflank 上升级到付费并开 L4 负载均衡器**：需要你有一个能指向该
   Northflank L4 公网 IP 的域名 + 一张能用的证书，配置繁琐且证书是硬伤。不推荐。

4. **如果只是嫌 WebSocket 老**：本项目已经把事情办了 —— 换成 XHTTP 就是当前
   Xray 官方推荐的现代 HTTP 传输，客户端兼容性也在快速跟进。这也是在
   "HTTP-only 平台" 上能做到的最接近 Reality 的效果。

## 本地运行与验证

```bash
# 起一个本地实例（明文 HTTP，:8080）
docker compose up --build
curl http://localhost:8080/healthz     # -> ok
curl http://localhost:8080/            # -> 伪装网页
```

`tests/` 目录下是我用来验证这个项目的脚本（不属于镜像内容）：

| 文件 | 作用 |
| --- | --- |
| `tests/render-and-test.sh` | 渲染 nginx/Xray 模板，检查标记清理、括号平衡、`xray run -test` |
| `tests/integration.sh` | 起真实 nginx + Xray，验证「客户端 → nginx → Xray → 互联网」全链路 |
| `tests/e2e-xhttp.sh` | 只验证 XHTTP 隧道本身 |
| `tests/run-all.sh` | 跑上面全部用例，含一个 nginx 负向对照 |
| `tests/fetch-nginx.sh` | 免 root 拉取 nginx 二进制（用于本地验证） |

## 故障排查

**日志里 `public host : <not detected - set PUBLIC_HOST>`**
Northflank 不会自动注入域名。去 **Networking** 复制端口对应的域名，填进
`PUBLIC_HOST` 重新部署。

**连不上 / 一直转圈**
1. 先 `curl -v https://<你的域名>/healthz`，确认容器本身活着、边缘证书正常；
2. 确认客户端 **路径** 和 `XHTTP_PATH` 完全一致（区分大小写，带 `/`）；
3. 确认客户端 **ALPN 是 `http/1.1`**、`Host` = 你的域名；
4. 用 `ENABLE_WS=true` + 客户端选 `ws` 交叉验证一下，判断是传输问题还是账号问题。

**重启后链接失效**
没设 `UUID`，容器每次重启都生成新的。补上 `UUID` 环境变量。

**能导入但访问不了网站**
看日志里有没有 `xray exited immediately`。若配置非法容器会拒绝启动，
把日志贴出来即可定位。

**免费层限制**
2 个 service / 2 个 job / 1 个 addon；服务空闲一段时间会被休眠，Cold start
会有几秒延迟，属正常。

## 安全说明

- 不要在公开仓库里提交你的 `UUID` / `SUB_TOKEN` —— 用 Northflank 的
  Environment 变量（可标记为 secret）注入；
- 本项目是**自用代理**，不是公共网关。别把 UUID 泄露出去；
- 建议改掉默认的 `XHTTP_PATH`；
- Northflank 里可以给端口加 **IP 白名单 / Basic Auth / SSO** 策略，
  但注意别把代理路径一起挡掉；
- 容器内 Xray 只监听 `127.0.0.1`，公网只能通过 nginx 的受控路径进入。

## 免责声明

本项目仅供**学习与研究网络协议**使用。请遵守你所在国家/地区以及服务器所在地的
法律法规，不得用于任何非法用途。使用者需自行承担全部责任，作者不对任何不当使用
负责。请在下载后 24 小时内删除。
