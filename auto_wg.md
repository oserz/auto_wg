## auto_wg – Auto WireGuard VPN Controller

### English

#### What is this?

**auto_wg** is a small helper script to **automatically connect/disconnect WireGuard** on Linux, designed for home‑network scenarios where:

- **IPv4 is CGNAT** (no public IPv4, only public IPv6 is available)
- You sometimes want **only intranet access (local mode)**, sometimes **full Internet via home router (global mode)**
- **UDP may be throttled or blocked**, so you need to **wrap WireGuard UDP in udp2raw (fake TCP)**

Instead of manually picking which `*.conf` to use each time and worrying about routing loops, `auto_wg.sh` chooses the right config, manages `udp2raw`, and fixes routing for you with a **single command**.

---

#### Why use this script?

the real‑world problems are:

- **No public IPv4**:  
  - IPv4 side may rely on FRP or similar tunnels.  
  - Only IPv6 can directly reach your home router.
- **Different traffic scopes**:
  - Sometimes you only need **LAN** (NAS, printers, etc.).
  - Sometimes you want **all traffic** to go through the home router (ad‑blocking, region routing, etc.).
- **UDP might be blocked**:
  - Native WireGuard UDP packets cannot pass; you need **udp2raw faketcp** to disguise them.

To handle this, for each WireGuard peer you end up with several configuration files:

- **udp2raw over IPv6**: `aio_p1_globals.conf`, `aio_p1_locals.conf`
- **IPv4 FRP**: `aio_p1_v4global.conf`, `aio_p1_v4local.conf`
- **IPv6 direct**: `aio_p1_v6global.conf`, `aio_p1_v6local.conf`

Managing these by hand is error‑prone:

- You must remember **which config** to use in which network.
- In **udp2raw global mode**, `AllowedIPs = 0.0.0.0/0, ::/0` will capture even the traffic from the client to `udp2raw` itself, causing a **routing loop** and making the connection fail unless you fix routing by hand.

**auto_wg.sh solves all of this**:

- **Automatically selects config** based on:
  - IPv4/IPv6 availability
  - Local vs global mode
  - Node (peer) name
- **Starts/stops udp2raw** in server/loopback mode and:
  - Saves your original IPv6 default gateway
  - Creates a dedicated routing table (`wgbypass`, table id `200`)
  - Adds routes and `ip -6 rule` so **udp2raw’s own traffic bypasses WireGuard**
- Works as a **toggle**:
  - If an auto_wg WireGuard interface is already up, it will **shut it down** (and clean up udp2raw + routing).
  - If not, it will **bring up** the requested mode.

---

#### How it works (config naming + modes)

auto_wg assumes your WireGuard configs live in:

- **Config directory**: `/etc/wireguard`
- **Naming pattern** (from the best‑practice doc):

For *normal modes* (no udp2raw started by the script):

- **Template**:  
  - `tags_node_{v4|v6}{local|global}.conf`
- Example with defaults `tags = aio`, `node = p1`:
  - `aio_p1_v4global.conf` – IPv4 FRP, global traffic
  - `aio_p1_v4local.conf` – IPv4 FRP, LAN only
  - `aio_p1_v6global.conf` – IPv6 DDNS, global traffic
  - `aio_p1_v6local.conf` – IPv6 DDNS, LAN only

For *server/loopback (udp2raw) mode*:

- **Template**:  
  - `tags_node_{globals|locals}.conf`
- Example:
  - `aio_p1_globals.conf` – udp2raw global traffic
  - `aio_p1_locals.conf` – udp2raw LAN only

The script **builds the interface/config name** like this:

- Normal mode (`auto_wg.sh` or `auto_wg.sh -l`):
  - Detects IPv6 with `ping6`:
    - If IPv6 works → `v6`
    - Else → `v4`
  - Chooses suffix:
    - Global: `global`
    - Local: `local`
  - Interface name (and config file):  
    - `${IFACE_TAG}_${NODE}_${ip_mode}${traffic}`  
    - e.g. `aio_p1_v6global` → `/etc/wireguard/aio_p1_v6global.conf`
- Server/loopback mode (`-s`):
  - With `-l`: `aio_p1_locals` → `/etc/wireguard/aio_p1_locals.conf`
  - Without `-l`: `aio_p1_globals` → `/etc/wireguard/aio_p1_globals.conf`

You must create these `.conf` files yourself; **auto_wg does not generate WireGuard configs**, it only selects and brings them up/down.

---

#### Requirements

- **Linux** with:
  - `bash`
  - `ip`, `ip -6`, `ip rule`, `ip route` (from `iproute2`)
  - `ping6`, `getent`, `dig` (for IPv6 detection/resolve)
  - `wg-quick` in `PATH`
- **Root privileges**:
  - The script exits if not run as root.
- **udp2raw client binary** for server/loopback mode:
  - Default path in the repo: `./udp2raw/udp2raw_amd64_hw_aes`
  - Adjust `UDP2RAW_BIN` in the script if your path is different.
- A reachable **IPv6 domain** for your home router:
  - Configured via `V6_DOMAIN` in the script (e.g. DDNS AAAA record).

---

#### Script options

From the script header:

```bash
auto_wg.sh [-l] [-s] [-p <node>] [-t <tag>]

  -l          Local traffic mode (default: global traffic)
  -s          Server/loopback mode (requires IPv6, starts udp2raw tunnel)
  -p <node>   Specify node (e.g., p1, p2, default: p1)
  -t <tag>    Specify interface tag (default: aio)
  -h          Show help
```

- **`-l` (local)**:
  - Use LAN‑only configs (`*local*.conf` or `*locals.conf`).
  - Typical `AllowedIPs` only include your LAN (`192.168.x.0/24`, WireGuard subnet).
- **No `-l` (global)**:
  - Use global configs (`*global*.conf` or `*globals.conf`).
  - Typical `AllowedIPs = 0.0.0.0/0, ::/0`.
- **`-s` (server/loopback)**:
  - Requires an IPv6‑capable network.
  - Resolves `V6_DOMAIN` to IPv6, generates a temporary udp2raw config in `/tmp`, and starts udp2raw client listening on `127.0.0.1:20828`.
  - Sets up a dedicated routing table so that traffic to the remote IPv6 udp2raw server **never goes through WireGuard**, avoiding routing loops.
- **`-p <node>`**:
  - Choose which peer node configs to use.
  - Example: `p1`, `p2`, `p3` → must match your config filenames (`aio_p2_v6global.conf`, etc.).
- **`-t <tag>`**:
  - Customize the prefix for interface/config names.
  - Default: `aio`.

---

#### Usage examples

Assuming:

- Your configs follow the patterns above.
- You are in the directory where `auto_wg.sh` lives.
- Script is executable: `chmod +x auto_wg.sh`.

**1. Toggle p1 global mode (IPv4 or IPv6 auto‑detected)**

```bash
sudo ./auto_wg.sh
```

- If no WireGuard interface with tag `aio` is up:
  - Checks IPv6:
    - If IPv6 OK → uses `aio_p1_v6global.conf`
    - Else → uses `aio_p1_v4global.conf`
  - Brings interface up via `wg-quick up`.
- If one is already up:
  - Brings it down (`wg-quick down`) and exits.

**2. Toggle p1 local mode**

```bash
sudo ./auto_wg.sh -l
```

- Same logic, but uses `aio_p1_v6local.conf` or `aio_p1_v4local.conf`.

**3. Use another node (p2)**

```bash
sudo ./auto_wg.sh -p p2        # global
sudo ./auto_wg.sh -l -p p2     # local
```

- Uses configs like `aio_p2_v6global.conf`, `aio_p2_v6local.conf`, etc.

**4. Server/loopback (udp2raw) global mode**

```bash
sudo ./auto_wg.sh -s
```

- Checks IPv6; exits with error if not available.
- Resolves `V6_DOMAIN` to an IPv6 address.
- Generates `/tmp/u2raw_client_runtime.conf`, starts udp2raw (logs to `/tmp/udp2raw.log`).
- Saves current default IPv6 gateway, sets up routing table `wgbypass` so that:
  - Traffic to the udp2raw server’s IPv6 goes via original gateway, not via WireGuard.
- Uses `aio_p1_globals.conf` and brings up WireGuard.
- To disconnect, run **any** `auto_wg.sh` command again:
  - It detects an active interface, stops udp2raw, brings WireGuard down, removes bypass routes/rules.

**5. Server/loopback local mode**

```bash
sudo ./auto_wg.sh -s -l
```

- Same as above but uses `aio_p1_locals.conf`.

---

#### Notes & customization

- **Edit hard‑coded parameters** in `auto_wg.sh` to match your environment:
  - `V6_DOMAIN` – your IPv6 DDNS domain.
  - `UDP2RAW_*` – ports, addresses, binary path.
  - `BYPASS_TABLE_ID` / `BYPASS_TABLE` – routing table id/name.
- The script uses `iproute2` policy routing (`/etc/iproute2/rt_tables`, `ip -6 rule`, `ip -6 route`) instead of nftables.  
  The idea is the same as in the best‑practice document: **ensure only a specific target IP keeps using the original gateway** so that global WireGuard does not break the udp2raw tunnel itself.
- The script does **not** manage your server‑side udp2raw/WireGuard; you still need to configure those (for example via an OpenWrt init script as described in the original document).

---

### 中文说明

#### 这是做什么的？

**auto_wg** 是一个在 Linux 上运行的 **WireGuard 自动接入脚本**，主要针对以下家庭宽带场景设计：

- **IPv4 在运营商 NAT 后**，拿不到公网 IPv4，只能通过 **IPv6 直连** 家里路由；
- 有时只需要访问 **家庭内网（局域网模式 local）**，有时又希望 **所有流量（global）都走家里的路由器**；
- **UDP 可能被限流/封锁**，需要用 **udp2raw 把 WireGuard 的 UDP 伪装成 TCP 流量** 才能穿透。

平时你可能会为每个接入点和场景准备多份 WireGuard 配置文件，手动切换非常麻烦，而且容易因为路由配置不当导致死循环。  
**auto_wg.sh 的目标就是：一条命令，根据当前网络环境和参数自动选择合适的配置，管理 udp2raw，并且自动处理“全局模式下的路由绕行问题”。**

---

#### 为什么要用这个脚本？

WireGuard 接入总结下来有几个痛点：

- **家宽没有公网 IPv4**：
  - IPv4 侧可能要借助 FRP 等隧道；
  - 只有 IPv6 可以直连家里的 OpenWrt/路由。
- **不同使用场景需要不同流量范围**：
  - 只查 NAS / 打印机时，只需要 LAN 内网（local）；
  - 想用家里路由做广告过滤、分流时，需要全局走家里路由（global）。
- **运营商/校园网等环境可能封 UDP**：
  - 原生 WireGuard UDP 发不出去，需要用 **udp2raw faketcp** 把 UDP 伪装成 TCP。

为此，你通常会为每个 Peer 准备多份配置，例如文档中的命名：

- **udp2raw over IPv6**：`aio_p1_globals.conf`, `aio_p1_locals.conf`
- **IPv4 FRP**：`aio_p1_v4global.conf`, `aio_p1_v4local.conf`
- **IPv6 直连**：`aio_p1_v6global.conf`, `aio_p1_v6local.conf`

问题在于：

- 手动接入时，要记住“现在应该用哪一个配置”；
- 尤其在 **udp2raw 全局模式** 下，`AllowedIPs = 0.0.0.0/0, ::/0` 会把 **发往本地 udp2raw 的流量也劫持进 WireGuard**，容易形成 **路由环路**，导致完全连不上 unless 你手动改路由 / nftables。

**auto_wg.sh 做的事情是：**

- **自动选择 WireGuard 配置文件**：
  - 检测当前是否支持 IPv6；
  - 根据 global/local、IPv4/IPv6、节点（如 p1/p2）拼出正确的 config 名；
- 在 **服务器/回环模式（-s）下自动管理 udp2raw**：
  - 解析 IPv6 域名，生成临时配置；
  - 启动 udp2raw 客户端；
  - 使用独立路由表 `wgbypass` 保存原始 IPv6 默认网关，通过 `ip -6 route` + `ip -6 rule` **让发往 udp2raw 服务器的流量永远走原网关，不走 WireGuard**，避免全局模式下的自环；
- 提供一个 **“开关一体”** 的体验：
  - 如果已经有以指定 tag 命名的 WireGuard 接口在运行，再执行脚本就会 **先关掉当前连接（顺带关闭 udp2raw 并恢复路由）**；
  - 否则就按照参数 **建立新连接**。

---

#### 配置命名与模式说明

脚本约定 WireGuard 配置放在：

- **目录**：`/etc/wireguard`
- **命名规则**（与最佳实践文档保持一致）：

**普通模式（不由脚本启动 udp2raw）**：

- 模板：  
  - `tags_node_{v4|v6}{local|global}.conf`
- 默认示例（`tags = aio`, `node = p1`）：
  - `aio_p1_v4global.conf` – 通过 IPv4 FRP 的全局模式
  - `aio_p1_v4local.conf` – 通过 IPv4 FRP 的内网模式
  - `aio_p1_v6global.conf` – 通过 IPv6 DDNS 的全局模式
  - `aio_p1_v6local.conf` – 通过 IPv6 DDNS 的内网模式

**服务器 / 回环（udp2raw）模式**：

- 模板：  
  - `tags_node_{globals|locals}.conf`
- 示例：
  - `aio_p1_globals.conf` – udp2raw 全局接入
  - `aio_p1_locals.conf` – udp2raw 内网接入

脚本内部通过函数组合出接口名（同时也是配置名，不带 `.conf`）：

- 普通模式下（不加 `-s`）：
  - 先检测 IPv6：
    - 支持 → `v6`
    - 不支持 → `v4`
  - 根据是否 `-l` 得出 `local` 或 `global`；
  - 最终接口名：`${IFACE_TAG}_${NODE}_${ip_mode}${traffic}`  
    如：`aio_p1_v6global` → `/etc/wireguard/aio_p1_v6global.conf`
- 服务器模式下（加 `-s`）：
  - 加 `-l` → `aio_p1_locals`；
  - 不加 `-l` → `aio_p1_globals`。

**注意：脚本本身不会生成 WireGuard 配置文件，你需要提前按以上规则准备好 `.conf` 文件。**

---

#### 环境与依赖

- **操作系统**：任意常见 Linux 发行版；
- 需要的命令：
  - `bash`
  - `ip`, `ip -6`, `ip rule`, `ip route`（来自 `iproute2`）
  - `ping6`, `getent`, `dig`（用于 IPv6 探测和解析）
  - `wg-quick`（在 `PATH` 中）
- **必须以 root 身份运行**（脚本会检查 UID，不是 root 会直接退出）；
- **udp2raw 客户端**（仅在 `-s` 模式需要）：
  - 默认路径：`./udp2raw/udp2raw_amd64_hw_aes`；
  - 如路径不同，请修改脚本中的 `UDP2RAW_BIN`。
- **IPv6 域名**：
  - 在脚本中通过 `V6_DOMAIN` 配置，如指向家中 OpenWrt 的 AAAA 记录。

---

#### 脚本参数

脚本头部注释对应的用法：

```bash
auto_wg.sh [-l] [-s] [-p <node>] [-t <tag>]

  -l          本地流量模式（默认是全局流量）
  -s          服务端/回环模式（需要 IPv6，会拉起 udp2raw）
  -p <node>   指定节点（例如 p1, p2，默认 p1）
  -t <tag>    接口前缀 tag（默认 aio）
  -h          显示帮助
```

- **`-l`（local 本地模式）**：
  - 使用 `*local*.conf` 或 `*locals.conf` 等局域网配置；
  - 一般 `AllowedIPs` 只包含内网网段和 wg 子网。
- **不加 `-l`（global 全局模式）**：
  - 使用 `*global*.conf` 或 `*globals.conf` 等全局配置；
  - 一般 `AllowedIPs = 0.0.0.0/0, ::/0`。
- **`-s`（服务器 / 回环模式）**：
  - 要求当前网络支持 IPv6；
  - 会解析 `V6_DOMAIN`，生成 `/tmp/u2raw_client_runtime.conf`，启动 udp2raw 客户端监听 `127.0.0.1:20828`；
  - 记录当前 IPv6 默认网关，创建路由表 `wgbypass`，给目标 IPv6 加路由并通过 `ip -6 rule` **强制走原始网关**，避免全局模式下的自环；
  - 配合 `aio_p1_globals.conf` / `aio_p1_locals.conf` 进行 wg 接入。
- **`-p <node>`**：
  - 指定使用哪个 Peer 节点的配置（如 p1/p2/p3），需要与配置文件名一致；
  - 例如 `-p p2` 会使用 `aio_p2_v6global.conf` 等。
- **`-t <tag>`**：
  - 支持自定义接口前缀；
  - 默认为 `aio`。

---

#### 使用示例

假设：

- 配置命名按上文约定；
- `auto_wg.sh` 在当前目录且已赋予执行权限：`chmod +x auto_wg.sh`。

**1. p1 的全局模式（自动判断 IPv4/IPv6）**

```bash
sudo ./auto_wg.sh
```

- 如果当前没有以 `aio` 开头的 WireGuard 接口：
  - 检测 IPv6：
    - 支持 → 使用 `aio_p1_v6global.conf`
    - 不支持 → 使用 `aio_p1_v4global.conf`
  - 使用 `wg-quick up` 拉起接口。
- 如果已有接口在运行：
  - 直接 `wg-quick down` 关闭该接口并退出。

**2. p1 的内网模式**

```bash
sudo ./auto_wg.sh -l
```

- 与上类似，但使用 `aio_p1_v6local.conf` 或 `aio_p1_v4local.conf`。

**3. 切换到 p2 节点**

```bash
sudo ./auto_wg.sh -p p2        # p2 全局
sudo ./auto_wg.sh -l -p p2     # p2 内网
```

- 用的是 `aio_p2_v6global.conf`、`aio_p2_v6local.conf` 等配置。

**4. udp2raw 全局接入（服务器/回环模式）**

```bash
sudo ./auto_wg.sh -s
```

- 检查 IPv6，失败则报错退出；
- 解析 `V6_DOMAIN` 得到 IPv6 地址；
- 写入 `/tmp/u2raw_client_runtime.conf` 并启动 udp2raw（日志在 `/tmp/udp2raw.log`）；
- 通过 `save_default_gateway` 记录当前默认 IPv6 网关，在 `wgbypass` 表中为该 IPv6 目标添加路由，并设置 `ip -6 rule` 实现流量绕行；
- 使用 `aio_p1_globals.conf` 拉起 WireGuard；
- 之后再执行任意一次 `./auto_wg.sh`：
  - 脚本会检测到已有 wg 接口，先停止 udp2raw，关闭 wg，再清理绕行路由与规则。

**5. udp2raw 内网接入**

```bash
sudo ./auto_wg.sh -s -l
```

- 逻辑同上，但使用 `aio_p1_locals.conf`。

---

#### 注意事项与定制

- 可以根据自己环境修改脚本中的参数：
  - `V6_DOMAIN` – 改成你自己的 IPv6 DDNS 域名；
  - `UDP2RAW_LOCAL_PORT` / `UDP2RAW_REMOTE_PORT` / `UDP2RAW_BIN` 等；
  - `BYPASS_TABLE_ID` / `BYPASS_TABLE` 等路由表配置。
- 当前脚本用的是 **`iproute2` 的策略路由**（`/etc/iproute2/rt_tables` + `ip -6 rule` + `ip -6 route`），和文档中提到通过 nftables 指定“某个目标 IP 走原网关”的思路是一致的，只是实现方式不同。
- 服务器端的 udp2raw 和 WireGuard（例如在 OpenWrt 中的 `/etc/init.d/udp2raw_service` 和 `u2raw_server.conf`）仍需要按文档示例单独配置，本脚本只负责客户端侧的“自动接入”。
