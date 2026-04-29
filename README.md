# flow_captcha_service

`flow_captcha_service` 是给 `flow2api` 使用的自托管打码服务。

它的目标不是接第三方打码平台，而是自己托管 `Playwright + Chromium`
有头浏览器能力，并支持单机、主从集群、用户门户、管理后台和额度体系。

如果你只想快速理解一句话，可以直接记住下面这句：

> `standalone` 本地自己打码，`master` 只调度不本地打码，
> `subnode` 负责执行浏览器打码并向 `master` 上报心跳。

---

## 与 flow2api 内置打码的深度对比分析

### 两种打码路径概览

`flow2api` 提供两条并行的打码路径：

```text
路径 A（内置模式）：
flow2api → 本地 browser_captcha.py (Playwright) 或 browser_captcha_personal.py (nodriver)

路径 B（外部服务模式）：
flow2api → remote_browser → flow_captcha_service HTTP API
```

路径 A 将打码能力直接嵌入 `flow2api` 进程内，是零网络开销的本地调用。  
路径 B 将打码拆分为独立服务，由 `flow_captcha_service` 统一管理。

---

### 技术实现对比

#### flow2api 内置打码（路径 A）

| 项目 | 细节 |
|------|------|
| 技术栈 | Playwright（browser 模式）/ nodriver（personal 模式） |
| 生命周期 | 随 flow2api 进程启动/关闭，不可独立运维 |
| 并发控制 | 由 `browser_count` 控制 slot 数量，仅限本机 |
| 指纹策略 | UA 随机化 + viewport 随机化，每 slot 维护独立 profile |
| 会话协议 | 无独立会话生命周期，token 取完即用 |
| 用户管理 | 无，依赖 flow2api 的 token 管理 |
| 部署方式 | 与 flow2api 共生，仅单机 |
| 可观测性 | 依赖 flow2api 日志 |

#### flow_captcha_service 打码（路径 B）

| 项目 | 细节 |
|------|------|
| 技术栈 | Playwright（browser 模式）/ nodriver（personal 模式） |
| 生命周期 | 独立服务，独立部署、升级、重启 |
| 并发控制 | `browser_count` 控制 slot，支持多 subnode 水平扩容 |
| 指纹策略 | 同 flow2api；额外支持 project 亲和（同 project 优先复用相同 slot） |
| 会话协议 | `solve → finish/error` 完整会话协议，浏览器 context 保活至业务完成 |
| 用户管理 | 用户门户 + API Key + 额度 + CDK 兑换 |
| 部署方式 | standalone / master / subnode 三种角色，支持跨机器集群 |
| 可观测性 | 独立管理后台、请求日志、子节点心跳历史、错误历史 |

---

### 关键设计差异

#### 1. 会话保活语义（Session Lifecycle）

`flow2api` 内置模式取到 token 后浏览器 context 即可释放或复用，上游业务是否成功与打码层无关。

`flow_captcha_service` 实现了 **`solve → finish/error` 会话协议**：

- `POST /api/v1/solve`：获取 token，同时在 `SessionRegistry` 中注册会话
- `POST /api/v1/sessions/{id}/finish`：上游业务成功，打码层做正常收尾
- `POST /api/v1/sessions/{id}/error`：上游命中验证码失败，打码层回收对应 browser slot

这意味着打码层能感知上游业务结果，在失败时主动回收 slot、触发重新热身，而不是等到空闲超时才发现 slot 失效。

#### 2. Standby Token 预热池

`flow_captcha_service` 实现了 **standby token pool**（`browser_standby_token_pool_*` 系列配置）：

- 后台持续往 bucket 里预先生成 token
- 上游 `solve` 请求到达时直接从池中取，几乎零等待
- `flow2api` 内置模式没有这层预热，每次请求都需实时启动浏览器流程

#### 3. 请求 Bucket 亲和调度（Bucket Affinity）

集群模式下，`master` 会对相同 `project_id + action` 的请求建立 **节点亲和**——即优先把同类请求路由给上次成功处理该 bucket 的 subnode，减少跨节点的 context 重建开销。`flow2api` 内置模式因为不跨机器，不存在这个问题。

#### 4. 集群路由与心跳

`flow_captcha_service` 的集群路由完全基于 HTTP（不依赖 Redis/消息队列），通过：

- subnode 定时向 master 发送心跳（`POST /api/cluster/heartbeat`）
- master 维护节点健康状态和活跃并发数
- 按权重 + 空闲并发做加权选择

`flow2api` 内置模式没有集群概念。

#### 5. YesCaptcha 兼容协议层

`flow_captcha_service` 实现了 `createTask / getTaskResult / getBalance` 兼容接口，支持多种 task.type（reCAPTCHA V2/V3/Enterprise、Turnstile 等）。

这使得除 flow2api 之外的其他系统也可以直接以 YesCaptcha 协议格式接入，而 `flow2api` 内置模式不暴露任何外部协议。

---

### 优劣势总结

#### flow_captcha_service 相比内置模式的优势

| 优势 | 说明 |
|------|------|
| **水平扩容** | master + subnode 模式可跨多台机器分散浏览器压力，突破单机并发上限 |
| **服务解耦** | 打码服务与 flow2api 独立部署，打码层重启/升级不影响主服务 |
| **会话保活** | `finish/error` 让浏览器 context 与上游业务生命周期对齐，失败可立即回收 slot |
| **Standby 预热** | 提前生成 token，请求命中时近零等待 |
| **多租户额度** | 用户门户 + API Key + 配额，适合多团队共用一套打码基础设施 |
| **协议兼容** | YesCaptcha 协议可让非 flow2api 上游系统直接接入 |
| **可观测性** | 独立后台可查子节点状态、请求历史、错误统计，不依赖 flow2api 日志 |
| **节点健康检测** | master 实时感知 subnode 存活，自动剔除失效节点 |

#### flow_captcha_service 相比内置模式的劣势

| 劣势 | 说明 |
|------|------|
| **部署复杂度更高** | 需要额外运维一个独立服务，增加了基础设施复杂度 |
| **额外网络延迟** | flow2api 每次取 token 需发 HTTP 请求，比进程内直接调用多一层网络往返 |
| **依赖链更长** | flow2api + flow_captcha_service 组合比单体部署多一个故障点 |
| **集群配置工作量** | `cluster_key`、`node_public_base_url` 等需精确配置，否则子节点无法注册 |
| **小规模场景性价比低** | 单机单用户时，直接用 flow2api 内置 `browser`/`personal` 更简单 |

---

### 选型建议

| 场景 | 推荐方案 |
|------|---------|
| 个人本地使用，单机单用户 | flow2api 内置 `browser` 或 `personal` 模式 |
| 单机多用户，需要额度管控 | flow_captcha_service `standalone` |
| 多台机器、高并发生产环境 | flow_captcha_service `master + subnode` 集群 |
| 需要对外统一提供打码能力 | flow_captcha_service（YesCaptcha 协议统一接入） |
| 希望最小化基础设施复杂度 | flow2api 内置模式（减少外部依赖） |

---

---

## Windows 本地集群快速启动

如果你在 **多台 Windows 电脑** 上跑集群，推荐使用以下一键启动脚本。

| 脚本 | 角色 | 用途 |
|------|------|------|
| `start.bat` | standalone | 单机模式，一键启动，适合个人本地使用 |
| `master_start.bat` | master | 主节点，只负责调度，不执行本地浏览器打码 |
| `sub_start.bat` | subnode | 子节点，执行本地有头浏览器打码，向 master 注册 |

---

### 集群模式 vs 单节点模式

#### 单节点（standalone）的适用场景

- 个人本地使用
- 单台机器，并发需求不高
- 不需要多台机器协同
- 所有功能（调度 + 打码）集中在一个进程

#### 集群模式（master + subnode）的优势

| 优势 | 说明 |
|------|------|
| **水平扩容** | 增加 subnode 即可线性提升并发打码能力，突破单机资源上限 |
| **故障隔离** | 某台 subnode 崩溃，master 自动停止向其路由，其他节点继续工作 |
| **统一入口** | 上游（flow2api）只对接 master 一个地址，subnode 上下线对上游透明 |
| **资源分离** | master 轻量运行（无浏览器），可部署在低配机器或共享服务器上 |
| **节点健康监控** | master 后台实时显示各 subnode 的状态、活跃并发、心跳时间 |
| **Bucket 亲和调度** | master 会把同 project 的请求路由到同一 subnode，减少 context 重建 |

---

### 集群部署步骤

#### 第一步：在主节点机器上启动 master

1. 将完整项目目录复制到主节点机器
2. 双击运行 `master_start.bat`
3. 首次运行会创建 `data\master\setting.toml` 并暂停，编辑该文件：

   ```toml
   [cluster]
   role = "master"
   master_cluster_key = "your-secret-cluster-key"   # 设置一个强密钥

   [admin]
   password = "your-admin-password"   # 修改管理员密码
   ```

4. 保存后重新运行 `master_start.bat`
5. 验证主节点正常运行：访问 `http://主节点IP:8060/admin`

> **获取 cluster_key**：在管理后台 → 系统配置 中查看，或直接看 `data\master\setting.toml` 里的 `master_cluster_key`

#### 第二步：在每台子节点机器上启动 subnode

1. 将完整项目目录复制到子节点机器
2. 双击运行 `sub_start.bat`
3. 首次运行会创建 `sub_node.env` 并暂停，编辑该文件：

   ```ini
   # 主节点地址（子节点访问 master 的地址）
   FCS_CLUSTER_MASTER_BASE_URL=http://192.168.1.100:8060

   # 集群密钥（与主节点 master_cluster_key 一致）
   FCS_CLUSTER_MASTER_CLUSTER_KEY=your-secret-cluster-key

   # 本节点对外地址（master 回调此地址，不能填 127.0.0.1）
   FCS_CLUSTER_NODE_PUBLIC_BASE_URL=http://192.168.1.101:8061

   # 本节点认证 Key（随机字符串，每台子节点可以不同）
   FCS_CLUSTER_NODE_API_KEY=subnode1-secret-key

   # 节点名称（在 master 管理后台中显示）
   FCS_NODE_NAME=subnode-1

   # 服务端口
   FCS_SERVER_PORT=8061

   # 浏览器槽位数
   FCS_BROWSER_COUNT=2
   ```

4. 保存后重新运行 `sub_start.bat`
5. 几秒内，主节点后台 → 集群管理 中应出现该子节点

#### 第三步：验证集群连通

在主节点管理后台检查：

```text
http://主节点IP:8060/admin
→ 集群管理
→ 子节点列表中是否出现新节点
→ 心跳时间是否持续更新
→ 节点状态是否为健康
```

也可以用 API 快速验证：

```bash
# 验证主节点健康
curl http://主节点IP:8060/api/v1/health

# 验证子节点健康
curl http://子节点IP:8061/api/v1/health
```

---

### 多子节点配置示例

同一台机器上不想跑两个实例（因为 `sub_node.env` 是共用文件），推荐直接在不同电脑上各跑一个 subnode，通过 `FCS_NODE_NAME` 和 `FCS_SERVER_PORT` 区分。

如果确实需要同机多节点（测试场景），可以复制一份项目目录，各自维护独立的 `sub_node.env` 和 `.venv`。

---

### 重要注意事项

- `FCS_CLUSTER_NODE_PUBLIC_BASE_URL` **不能填 `127.0.0.1`、`localhost` 或 `0.0.0.0`**——这是主节点回调子节点的地址，必须是主节点网络真正可达的 IP/域名
- 每台子节点的 `FCS_CLUSTER_NODE_API_KEY` 可以相同也可以不同，建议不同以便审计
- 如果主节点或子节点重启，子节点会在下次心跳时自动重新注册
- `sub_node.env` 中的值不要包含引号，直接填值即可（`KEY=value` 格式）

---



第一次部署，建议只走脚本入口，不要先手动 `mkdir` / `cp` / `docker compose -f ...`。

### PowerShell

先跑单机：

```powershell
.\scripts\deploy.ps1 standalone
```

想本机验证最小集群：

```powershell
.\scripts\deploy.ps1 stack
```

单独部署子节点：

```powershell
.\scripts\deploy.ps1 subnode `
  -MasterBaseUrl http://host.docker.internal:8060 `
  -MasterClusterKey <你的主节点 key> `
  -NodePublicBaseUrl http://host.docker.internal:8061
```

### Bash

```bash
bash ./scripts/deploy.sh standalone
bash ./scripts/deploy.sh stack
```

### 脚本会自动处理什么

- 创建 `data` / `data/master` / `data/subnode`
- 不存在时自动复制 `config/setting_example.toml`
- 为 `stack` / `subnode` 自动生成本地 env 文件
- 执行对应的 `docker compose up -d --build`
- 等待健康检查通过后再打印访问地址

### 两条重要规则

- 第一次建议先跑 `standalone`，跑通后再尝试 `stack`
- 配置优先级始终是：环境变量 > `data/setting.toml` > 默认值

另外需要注意：

- `stack` 更适合本机演示集群，不等于跨机器生产部署
- `subnode` 跨机器部署时，`node_public_base_url` 必须填主节点真正能访问到的地址，不能填 `127.0.0.1` / `localhost` / `0.0.0.0`

---

## 项目介绍

### 这个项目解决什么问题

`flow2api` 在某些场景下需要一个独立的、有头浏览器驱动的验证码服务。
`flow_captcha_service` 就是为这个场景准备的独立服务端。

它提供：

- 有头浏览器打码能力
- `solve -> finish/error` 会话协议
- `YesCaptcha` 兼容协议（`createTask / getTaskResult / getBalance`）
- 浏览器槽位复用与空闲回收
- `standalone / master / subnode` 三种部署角色
- 用户门户、管理员后台、API Key、额度和日志
- 主从集群调度

它不提供：

- `capsolver` 等其它第三方平台协议
- 子节点上的用户注册/登录首页

---

## 架构与角色

### 架构关系

```text
flow2api
   |
   | HTTP
   v
[standalone]                     直接本地打码

或

flow2api
   |
   | HTTP
   v
[master]                         只调度，不本地起浏览器
   |
   | 路由转发
   v
[subnode]                        本地执行有头浏览器打码
```

### 三种角色说明

#### 1. `standalone`

- 单机模式
- 本地直接执行浏览器打码
- 适合本地调试、单机部署、小规模使用

#### 2. `master`

- 只负责调度和转发
- 不执行本地浏览器打码
- 适合集群入口节点

#### 3. `subnode`

- 执行本地浏览器打码
- 向 `master` 注册和发送心跳
- 首页是**子节点状态页**，不是用户登录/注册页

### 访问入口差异

#### `standalone` / `master`

- `/`：用户门户
- `/portal`：用户门户别名
- `/admin`：管理后台
- `/api/v1/health`：健康检查

#### `subnode`

- `/`：子节点状态页
- `/portal`：同样返回子节点状态页
- `/subnode`：子节点状态页显式入口
- `/admin`：管理后台
- `/api/v1/health`：健康检查

> 从这个版本开始，`subnode` 不再展示用户注册/登录首页。
> 子节点首页只展示角色、健康状态和后台入口。

---

## 核心调用流程

### 标准链路

1. 上游调用 `POST /api/v1/solve`
2. 服务返回 `session_id`、`token`、`node_name`
3. 上游拿着 token 继续完成图片/视频等后续业务
4. 业务成功后调用 `POST /api/v1/sessions/{session_id}/finish`
5. 业务失败后调用 `POST /api/v1/sessions/{session_id}/error`

### 重要语义

- `solve` 只负责拿 token，不代表整个上游业务已经完成
- `finish/error` 是业务会话回收协议
- 成功时不会强制关闭共享浏览器
- 只有明确命中验证码失败类错误时，才会回收对应浏览器槽位

### 集群下的 `session_id`

如果当前角色是 `master`，返回的 `session_id` 可能是：

```text
nodeId:childSessionId
```

这表示：

- 前半段是 master 侧的节点路由信息
- 后半段是 subnode 的真实会话 ID
- 之后的 `finish/error` 会按这个路由再转发回原子节点

---

## 部署前准备

### 运行环境

- Python 本地运行：建议 `Python 3.11`
- Docker 部署：需要 `Docker` 和 `Docker Compose`
- 有头浏览器模式依赖 `Playwright + Chromium`

### 目录准备

如果你使用前面的 Docker 脚本入口，这一步会自动完成。

只有在你准备走本地 Python 或手工命令时，才需要自己准备运行目录：

```bash
mkdir -p data
cp config/setting_example.toml data/setting.toml
```

### 本地 Python 模式额外安装

本地非 Docker 启动时，除了安装 Python 依赖，还要安装 Chromium：

```bash
pip install -r requirements.txt
python -m playwright install chromium
```

说明：

- `requirements.txt` 已包含 `playwright` 和 `nodriver`
- 如果你要使用 `personal` 内置浏览器模式，必须先安装最新依赖

Linux 如果缺系统依赖，可以改用：

```bash
python -m playwright install --with-deps chromium
```

---

## 配置文件与环境变量

### 配置文件位置

- 模板文件：`config/setting_example.toml`
- 运行配置：`data/setting.toml`
- 兼容迁移：如果存在旧的 `config/setting.toml`，启动时会迁移到
  `data/setting.toml`

### 配置优先级

建议记住这一条：

```text
环境变量 > data/setting.toml > 默认配置
```

`config/setting_example.toml` 只是初始化模板，不是最终优先级来源。

如果你想看按角色拆开的详细填写说明，直接看：

- `docs/ROLE_CONFIG_GUIDE.md`

### 常用环境变量

#### 通用

- `FCS_CONFIG_FILE`
- `FCS_SERVER_HOST`
- `FCS_SERVER_PORT`
- `FCS_DB_PATH`
- `FCS_ADMIN_USERNAME`
- `FCS_ADMIN_PASSWORD`
- `FCS_LOG_LEVEL`
- `FCS_NODE_NAME`

#### 日志存储（可选 Redis）

- `FCS_LOG_STORAGE_BACKEND`
- `FCS_LOG_REDIS_URL`
- `FCS_LOG_REDIS_KEY_PREFIX`
- `FCS_LOG_REDIS_MAX_ENTRIES`
- `FCS_LOG_STARTUP_CLEAR_ON_BOOT`

#### 浏览器与打码

- `FCS_BROWSER_COUNT`
- `FCS_BROWSER_PROXY_ENABLED`
- `FCS_BROWSER_PROXY_URL`
- `FCS_BROWSER_LAUNCH_BACKGROUND`
- `FCS_BROWSER_FINGERPRINT_POOL_EXTRA_COUNT`
- `FCS_BROWSER_CUSTOM_PAGE_CACHE_MAX_PAGES`
- `FCS_BROWSER_CUSTOM_PAGE_IDLE_TTL_SECONDS`
- `FCS_BROWSER_PROJECT_AFFINITY_MAX_KEYS`
- `FCS_BROWSER_PROJECT_AFFINITY_TTL_SECONDS`
- `FCS_BROWSER_FLOW_WEBSITE_KEY`
- `FCS_BROWSER_AUTO_WARM_PROJECT_ID`
- `FCS_BROWSER_AUTO_WARMUP_ACTION`
- `FCS_BROWSER_SCORE_DOM_WAIT_SECONDS`
- `FCS_BROWSER_RECAPTCHA_SETTLE_SECONDS`
- `FCS_BROWSER_STANDBY_TOKEN_POOL_ENABLED`
- `FCS_BROWSER_STANDBY_TOKEN_TTL_SECONDS`
- `FCS_BROWSER_STANDBY_TOKEN_POOL_DEPTH`
- `FCS_BROWSER_STANDBY_BUCKET_MAX_COUNT`
- `FCS_BROWSER_STANDBY_BUCKET_IDLE_TTL_SECONDS`
- `FCS_BROWSER_STANDBY_REFILL_IDLE_SECONDS`
- `FCS_BROWSER_SCORE_TEST_WARMUP_SECONDS`
- `FCS_BROWSER_IDLE_TTL_SECONDS`
- `FCS_BROWSER_RETRY_MAX_ATTEMPTS`
- `FCS_BROWSER_RETRY_BACKOFF_SECONDS`
- `FCS_BROWSER_EXECUTE_TIMEOUT_SECONDS`
- `FCS_BROWSER_RELOAD_WAIT_TIMEOUT_SECONDS`
- `FCS_BROWSER_CLR_WAIT_TIMEOUT_SECONDS`
- `FCS_BROWSER_IDLE_REAPER_INTERVAL_SECONDS`
- `FCS_BROWSER_REQUEST_FINISH_IMAGE_WAIT_SECONDS`
- `FCS_BROWSER_REQUEST_FINISH_NON_IMAGE_WAIT_SECONDS`
- `FCS_BROWSER_AUTO_WARM_WEBSITE_URL`
- `FCS_BROWSER_AUTO_WARM_WEBSITE_KEY`
- `FCS_BROWSER_AUTO_WARM_ACTION`
- `FCS_FLOW_TIMEOUT`
- `FCS_UPSAMPLE_TIMEOUT`
- `FCS_SESSION_TTL_SECONDS`

#### 集群

- `FCS_CLUSTER_ROLE`
- `FCS_CLUSTER_MASTER_BASE_URL`
- `FCS_CLUSTER_MASTER_CLUSTER_KEY`
- `FCS_CLUSTER_NODE_PUBLIC_BASE_URL`
- `FCS_CLUSTER_NODE_API_KEY`
- `FCS_CLUSTER_HEARTBEAT_INTERVAL_SECONDS`
- `FCS_CLUSTER_NODE_WEIGHT`
- `FCS_CLUSTER_NODE_MAX_CONCURRENCY`
- `FCS_CLUSTER_MASTER_NODE_STALE_SECONDS`
- `FCS_CLUSTER_MASTER_DISPATCH_TIMEOUT_SECONDS`

### 可选 Redis 日志存储

默认行为：

- `storage_backend = "sqlite"` 时，继续走 SQLite
- `storage_backend = "redis"` 时，请求日志、子节点心跳历史、子节点错误历史写入 Redis
- `cluster_nodes` 的当前节点状态快照仍保留在 SQLite，因为它是覆盖写，不是历史累积日志
- `startup_clear_on_boot = true` 时，服务启动后会自动清理 SQLite 历史日志，并执行数据库压缩
- `auto_clear_interval_minutes > 0` 时，服务会按间隔自动清空请求日志、子节点心跳历史和子节点错误历史
  - 不会清空用户剩余次数、已用次数，也不会删除 `session_quota_events`

配置示例：

```toml
[log]
level = "INFO"
storage_backend = "redis"   # sqlite | redis
redis_url = "redis://127.0.0.1:6379/0"
redis_key_prefix = "fcs"
redis_max_entries = 20000
startup_clear_on_boot = true
auto_clear_interval_minutes = 0
```

等价环境变量：

- `FCS_LOG_STORAGE_BACKEND=redis`
- `FCS_LOG_REDIS_URL=redis://127.0.0.1:6379/0`
- `FCS_LOG_REDIS_KEY_PREFIX=fcs`
- `FCS_LOG_REDIS_MAX_ENTRIES=20000`
- `FCS_LOG_STARTUP_CLEAR_ON_BOOT=true`
- `FCS_LOG_AUTO_CLEAR_INTERVAL_MINUTES=30`

关闭 Redis，恢复默认 SQLite：

- `FCS_LOG_STORAGE_BACKEND=sqlite`

说明：

- `subnode` 接收来自 `master` 的内部调用时，不再持久化请求日志，避免重复写入
- `redis_max_entries` 用于限制 Redis 历史日志长度，避免 Redis 继续无限增长
- 定时清理日志只删除日志历史，不会影响额度扣减结果和用户使用次数统计

### 一个容易忽略的点

```text
cluster.node_max_concurrency = 0
```

实际含义是：

- 不单独指定固定并发
- 自动跟随 `browser_count`

### 自动补池与预热

如果你希望 `flow2api` 的 `remote_browser` 模式尽量把“取 token 等待”前移，可以在 `flow_captcha_service` 里直接开启预热：

- `browser_auto_warm_project_id`
  - `browser` 模式建议填写真实的 Flow `project_id`，用于持续维护原生 Flow token 池
  - `personal` 模式留空时，也会自动创建通用 resident 预热页；填写后会优先保留该项目的 affinity
- `browser_auto_warmup_action`
  - 指定原生池优先预热 `IMAGE_GENERATION` 还是 `VIDEO_GENERATION`
- `browser_auto_warm_website_url` + `browser_auto_warm_website_key`
  - 填写后，会持续维护自定义/custom 目标的 token 池
- `browser_auto_warm_action`
  - 自定义/custom 目标的 action，默认 `homepage`
- `browser_standby_token_pool_*`
  - 控制 standby token 池深度、TTL、bucket 回收与补池节奏

示例：

```toml
[captcha]
browser_flow_website_key = "6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV"
browser_auto_warm_project_id = "46a52124-04fa-4db0-99ba-61c240490584"
browser_auto_warmup_action = "IMAGE_GENERATION"
browser_standby_token_pool_enabled = true
browser_standby_token_pool_depth = 2
browser_auto_warm_website_url = ""
browser_auto_warm_website_key = ""
browser_auto_warm_action = "homepage"
```

说明：

 - `browser` 模式的原生 Flow 预热最好使用真实 `project_id`
 - `personal` 模式留空时，仍会创建 `warmup-1`、`warmup-2` 这类通用 resident 预热页
 - 自定义预热适合 `custom-token` / `yescaptcha` 兼容链路的固定目标站点
 - 上面两类预热都留空时，服务仍可正常按需打码，只是不主动补池

---

## 手工启动

### 方式一：本地单机 `standalone`

如果你只是想把服务跑起来，优先用前面的脚本入口。
这一节只保留“不使用脚本时”的手工命令。

#### 1. 创建虚拟环境

```bash
python -m venv .venv
```

Windows：

```powershell
.venv\Scripts\activate
```

Linux / macOS：

```bash
source .venv/bin/activate
```

#### 2. 安装依赖

```bash
pip install -r requirements.txt
python -m playwright install chromium
```

说明：

- `requirements.txt` 会同时安装 `playwright` 和 `nodriver`
- 切到 `personal` 模式前，先确认当前虚拟环境已经更新到最新依赖

#### 3. 准备配置

```bash
mkdir -p data
cp config/setting_example.toml data/setting.toml
```

确认 `data/setting.toml` 中：

```toml
[cluster]
role = "standalone"
```

#### 4. 启动服务

```bash
python main.py
```

#### 5. 启动后访问

- 用户门户：`http://127.0.0.1:8060/`
- 管理后台：`http://127.0.0.1:8060/admin`
- 健康检查：`http://127.0.0.1:8060/api/v1/health`

### 方式二：Docker 单机 `standalone`

对应文件：`docker-compose.headed.yml`

推荐脚本：

```powershell
.\scripts\deploy.ps1 standalone
```

手工方式：

```bash
mkdir -p data
cp config/setting_example.toml data/setting.toml
docker compose -f docker-compose.headed.yml up -d --build
```

访问：

- 用户门户：`http://127.0.0.1:8060/`
- 管理后台：`http://127.0.0.1:8060/admin`
- 健康检查：`http://127.0.0.1:8060/api/v1/health`

说明：

- 该模式使用 `Dockerfile.headed`
- 镜像内已安装 `Playwright Chromium + nodriver + Xvfb + fluxbox`
- 容器启动时会自动把 `BROWSER_EXECUTABLE_PATH` 指向 Playwright Chromium，供 `personal` 模式直接复用
- 默认角色是 `standalone`
- `./data:/app/data` 必须保留，否则数据库、日志、密钥等状态会丢失
- 如果节点刚切到 `personal` 模式，务必重新执行一次 `docker compose ... up -d --build`，或重新拉取最新 `headed` 镜像

---

## 使用教程

下面这部分是“服务已经启动之后，怎么真正接入”。

### 教程 A：管理员第一次初始化

#### 1. 打开管理后台

访问：

```text
http://127.0.0.1:8060/admin
```

默认管理员账号通常是：

```text
admin / admin
```

首次登录后建议马上修改。

#### 2. 创建对接方式

你有两种常见用法：

- 直接在后台创建服务 API Key，给上游程序直接调用
- 让用户走门户注册/登录，再在门户里创建自己的 API Key

### 教程 B：用户门户模式

只适用于 `standalone` 或 `master`。

#### 1. 打开门户

```text
http://127.0.0.1:8060/
```

#### 2. 注册或登录

门户支持：

- 登录
- 注册
- 查看额度
- 兑换 CDK
- 查看调用记录
- 自助创建自己的 API Key

#### 3. 创建个人 API Key

登录后进入 `API Key` 页面，创建自己的 Key。

### 教程 C：服务 API 直连模式

下面是最常见的接入方式。

#### 1. 调用 `solve`

```bash
curl -X POST "http://127.0.0.1:8060/api/v1/solve" \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "project_id": "demo-project",
    "action": "IMAGE_GENERATION"
  }'
```

返回示例：

```json
{
  "success": true,
  "session_id": "123456",
  "token": "recaptcha-token",
  "fingerprint": {},
  "node_name": "standalone-node",
  "expires_in_seconds": 1200
}
```

如果当前入口是 `master`，`session_id` 可能是：

```text
12:child-session-id
```

这属于正常现象，后续 `finish/error` 原样带回即可。

#### 2. 业务成功后调用 `finish`

```bash
curl -X POST "http://127.0.0.1:8060/api/v1/sessions/<SESSION_ID>/finish" \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "success"
  }'
```

#### 3. 业务失败后调用 `error`

```bash
curl -X POST "http://127.0.0.1:8060/api/v1/sessions/<SESSION_ID>/error" \
  -H "Authorization: Bearer <YOUR_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "error_reason": "upstream_error"
  }'
```

### 教程 D：`custom-score`

如果你要做自定义 score 调试，可以调用：

```text
POST /api/v1/custom-score
```

请求体包含：

- `website_url`
- `website_key`
- `verify_url`
- `action`
- `enterprise`

### 教程 E：`YesCaptcha` 兼容接口

如果上游已经按 `YesCaptcha` 的请求格式接入，可以直接调用：

```text
POST /createTask
POST /getTaskResult
POST /getBalance
```

当前支持的 `task.type`：

- `NoCaptchaTaskProxyless`
- `RecaptchaV2TaskProxyless`
- `RecaptchaV2EnterpriseTaskProxyless`
- `RecaptchaV3TaskProxyless`
- `RecaptchaV3TaskProxylessM1`
- `RecaptchaV3TaskProxylessM1S7`
- `RecaptchaV3TaskProxylessM1S9`
- `RecaptchaV3EnterpriseTaskProxyless`
- `TurnstileTaskProxyless`
- `TurnstileTaskProxylessM1`
- `TurnstileTaskProxylessM1S1`
- `TurnstileTaskProxylessM1S2`
- `TurnstileTaskProxylessM1S3`

#### `task.type` 对照说明

- `NoCaptchaTaskProxyless`、`RecaptchaV2TaskProxyless`
  - 本地统一映射为 `reCAPTCHA V2`
  - 默认按 `isInvisible=true` 走 invisible；如果请求里显式传 `isInvisible=false`，会按普通 V2 widget 方式执行
  - 返回 `solution.gRecaptchaResponse` 和 `solution.token`

- `RecaptchaV2EnterpriseTaskProxyless`
  - 本地映射为 `reCAPTCHA V2 Enterprise`
  - 仍然支持 `isInvisible`
  - 返回 `solution.gRecaptchaResponse` 和 `solution.token`

- `RecaptchaV3TaskProxyless`、`RecaptchaV3TaskProxylessM1`、`RecaptchaV3TaskProxylessM1S7`、`RecaptchaV3TaskProxylessM1S9`
  - 本地统一映射为同一条 `reCAPTCHA V3` 求解链路
  - `pageAction`、`action`、`websiteAction` 会被归一化成同一个 `action`
  - 这些 `M1 / S7 / S9` 在当前服务里只是协议兼容别名，不额外承诺官方同名任务的特殊求解策略
  - 返回 `solution.gRecaptchaResponse` 和 `solution.token`

- `RecaptchaV3EnterpriseTaskProxyless`
  - 本地映射为 `reCAPTCHA V3 Enterprise`
  - `pageAction`、`action`、`websiteAction` 会被归一化成同一个 `action`
  - 返回 `solution.gRecaptchaResponse` 和 `solution.token`

- `TurnstileTaskProxyless`、`TurnstileTaskProxylessM1`、`TurnstileTaskProxylessM1S1`、`TurnstileTaskProxylessM1S2`、`TurnstileTaskProxylessM1S3`
  - 本地统一映射为同一条 `Cloudflare Turnstile` 求解链路
  - 这些 `M1 / S1 / S2 / S3` 在当前服务里也是协议兼容别名，不额外区分不同本地策略
  - 返回 `solution.token`
  - `Turnstile` 不会返回 `solution.gRecaptchaResponse`

说明：

- 原有 `/api/v1/solve`、`/finish`、`/error` 保持不变
- 当前只支持 `proxyless` 的通用 token 任务
- 当前不支持 `hCaptcha`、`FunCaptcha`、代理型任务
- `getBalance` 返回的是当前 API Key 剩余次数；无限额度 Key 会返回 `999999999`
- `YesCaptcha` 兼容层是标准轮询模式，只保证 `token ready`
  - 如果你需要“打码后继续等待上游业务请求完成再回收”的会话语义，请继续使用原生 `/api/v1/solve -> finish/error`

#### 等待逻辑说明

- `createTask` 只是创建异步任务，不会像原生 `/api/v1/solve` 一样建立一条等待 `finish/error` 回收的业务会话
- `getTaskResult` 返回 `status = ready`，表示当前 `token` 已经可用
- `ready` 不代表你的上游业务请求已经成功，也不代表服务还会继续替你等待真实业务完成
- 标准 `YesCaptcha` 协议本身没有 `finish/error` 这类回调，所以它天然无法完整复刻原生接口“获取 token 后继续等待上游完成”的语义
- 如果你的业务必须依赖“同一浏览器上下文继续保活，直到真实请求结束”，请继续使用原生 `/api/v1/solve -> finish/error`
- 如果你的业务只是想兼容 `YesCaptcha createTask/getTaskResult` 的调用格式，并且目标只是拿到可用 `token`，直接用当前兼容层即可

#### 1. 创建任务

```bash
curl -X POST "http://127.0.0.1:8060/createTask" \
  -H "Content-Type: application/json" \
  -d '{
    "clientKey": "<YOUR_API_KEY>",
    "task": {
      "type": "RecaptchaV3TaskProxyless",
      "websiteURL": "https://example.com/login",
      "websiteKey": "site-key",
      "pageAction": "login"
    }
  }'
```

返回示例：

```json
{
  "errorId": 0,
  "taskId": 1774442208718
}
```

#### 2. 轮询任务结果

```bash
curl -X POST "http://127.0.0.1:8060/getTaskResult" \
  -H "Content-Type: application/json" \
  -d '{
    "clientKey": "<YOUR_API_KEY>",
    "taskId": 1774442208718
  }'
```

处理中：

```json
{
  "errorId": 0,
  "taskId": 1774442208718,
  "status": "processing"
}
```

完成后，如果是 `reCAPTCHA`，返回示例：

```json
{
  "errorId": 0,
  "taskId": 1774442208718,
  "status": "ready",
  "solution": {
    "gRecaptchaResponse": "token-value",
    "token": "token-value",
    "userAgent": "Mozilla/5.0 ..."
  }
}
```

完成后，如果是 `Turnstile`，返回示例：

```json
{
  "errorId": 0,
  "taskId": 1774442208718,
  "status": "ready",
  "solution": {
    "token": "turnstile-token",
    "userAgent": "Mozilla/5.0 ..."
  }
}
```

#### 3. 查询余额

```bash
curl -X POST "http://127.0.0.1:8060/getBalance" \
  -H "Content-Type: application/json" \
  -d '{
    "clientKey": "<YOUR_API_KEY>"
  }'
```

---

## 手工集群部署

如果你只是想先把集群跑起来，优先使用前面的脚本入口。

这一节只保留：

- 每种集群模式适用于什么场景
- 手工排查时最短的 compose 命令
- 哪些关键变量必须自己确认

### 1. Docker 部署 `master`

对应文件：`docker-compose.cluster.master.yml`

#### 适用场景

- 作为集群统一入口
- 只调度，不本地打码
- 镜像更轻，不安装 Chromium

推荐脚本：

```powershell
.\scripts\deploy.ps1 master
```

手工方式：

```bash
mkdir -p data/master
cp config/setting_example.toml data/master/setting.toml
docker compose -f docker-compose.cluster.master.yml up -d --build
```

默认访问入口：

- 管理后台：`http://127.0.0.1:8060/admin`
- 用户门户：`http://127.0.0.1:8060/`
- 健康检查：`http://127.0.0.1:8060/api/v1/health`

说明：

- `master` 使用 `Dockerfile.master`
- 不安装 `Playwright/Chromium`
- 当前 compose 默认挂载是 `./data/master:/app/data`
- 当前 compose 会同时启动 `Redis`
- 当前 compose 默认将日志后端设为 `redis`
- 如果你不想启用 Redis，可在启动前覆盖：
  - `FCS_LOG_STORAGE_BACKEND=sqlite`
  - 或直接改 `data/master/setting.toml`

### 2. Docker 部署 `subnode`

对应文件：`docker-compose.cluster.subnode.yml`

#### 适用场景

- 集群执行节点
- 本地有头浏览器打码
- 向 `master` 注册与发送心跳

推荐脚本：

```powershell
.\scripts\deploy.ps1 subnode `
  -MasterBaseUrl http://host.docker.internal:8060 `
  -MasterClusterKey <你的主节点 key> `
  -NodePublicBaseUrl http://host.docker.internal:8061
```

手工方式：

```bash
mkdir -p data/subnode deploy
cp config/setting_example.toml data/subnode/setting.toml
cp deploy/subnode.env.example deploy/subnode.env.local
```

然后修改 `deploy/subnode.env.local`。

必须确认以下 4 个值：

- `FCS_CLUSTER_MASTER_BASE_URL`
  - 子节点访问主节点的地址
- `FCS_CLUSTER_MASTER_CLUSTER_KEY`
  - 主节点当前使用的 cluster key
- `FCS_CLUSTER_NODE_PUBLIC_BASE_URL`
  - 主节点回调当前子节点的地址
- `FCS_CLUSTER_NODE_API_KEY`
  - 子节点内部认证 key

最后启动：

```bash
docker compose --env-file deploy/subnode.env.local -f docker-compose.cluster.subnode.yml up -d --build
```

默认访问入口：

- 子节点状态页：`http://127.0.0.1:8061/`
- 管理后台：`http://127.0.0.1:8061/admin`
- 健康检查：`http://127.0.0.1:8061/api/v1/health`

非常重要的注意事项：

- `FCS_CLUSTER_NODE_PUBLIC_BASE_URL` 不能填 `127.0.0.1`
- 不能填 `localhost`
- 不能填 `0.0.0.0`
- 必须是 `master` 真正能访问到的地址

另外：

- `host.docker.internal` 只适合本机开发或 Docker Desktop 场景
- Linux 服务器或跨机器部署时，应改成真实地址

### 3. 一键启动 `master + subnode`

对应文件：`docker-compose.cluster.stack.yml`

这是最推荐的最小集群示例。

推荐脚本：

```powershell
.\scripts\deploy.ps1 stack
```

手工方式：

```bash
mkdir -p data/master data/subnode deploy
cp config/setting_example.toml data/master/setting.toml
cp config/setting_example.toml data/subnode/setting.toml
cp deploy/stack.env.example deploy/stack.env.local
```

然后修改 `deploy/stack.env.local`。

至少要确认这些值：

- `FCS_CLUSTER_MASTER_CLUSTER_KEY`
- `FCS_CLUSTER_NODE_API_KEY`
- 如果不是容器内互联场景，还要改
  `FCS_CLUSTER_MASTER_BASE_URL` 和 `FCS_CLUSTER_NODE_PUBLIC_BASE_URL`

最后启动：

```bash
docker compose --env-file deploy/stack.env.local -f docker-compose.cluster.stack.yml up -d --build
```

访问：

- master 用户门户：`http://127.0.0.1:8060/`
- master 管理后台：`http://127.0.0.1:8060/admin`
- master 健康检查：`http://127.0.0.1:8060/api/v1/health`
- subnode 状态页：`http://127.0.0.1:8061/`
- subnode 健康检查：`http://127.0.0.1:8061/api/v1/health`

这个 compose 的优点

- 已把 `master` 和 `subnode` 的数据目录拆开
- 已内置 `Redis` 服务给日志/心跳/错误历史使用
- 默认更适合作为第一次验证集群调度的示例
- 默认会把日志后端设为 `redis`
- 如果你想退回 SQLite，把 `deploy/stack.env.local` 里的
  `FCS_LOG_STORAGE_BACKEND=sqlite`

挂载如下：

- `./data/master:/app/data`
- `./data/subnode:/app/data`
- `./data/redis:/data`

---

## 每种模式必须改什么

### `standalone`

- 一般可以直接启动
- 按需调整 `browser_count`
- 按需调整代理
- 建议修改管理员账号密码

### `master`

- 建议修改 `FCS_NODE_NAME`
- 建议修改管理员账号密码
- 如果有多个子节点，建议统一规划 cluster key
- 如果不想使用 Redis 日志后端，显式设置 `FCS_LOG_STORAGE_BACKEND=sqlite`

### `subnode`

- 必改 `FCS_CLUSTER_MASTER_BASE_URL`
- 必改 `FCS_CLUSTER_MASTER_CLUSTER_KEY`
- 必改 `FCS_CLUSTER_NODE_PUBLIC_BASE_URL`
- 必改 `FCS_CLUSTER_NODE_API_KEY`
- 建议修改 `FCS_NODE_NAME`
- 推荐放在 `deploy/subnode.env.local`

### `stack`

- 必改 `FCS_CLUSTER_MASTER_CLUSTER_KEY`
- 必改 `FCS_CLUSTER_NODE_API_KEY`
- 如果不是容器内互联场景，要改 master/subnode 的实际对外地址
- 默认已启用 Redis 日志后端；如需退回 SQLite，改 `FCS_LOG_STORAGE_BACKEND=sqlite`
- 推荐放在 `deploy/stack.env.local`

---

## 启动后怎么验证

### 验证 1：服务是否存活

```bash
curl http://127.0.0.1:8060/api/v1/health
```

返回示例：

```json
{
  "success": true,
  "status": "ok",
  "node_name": "master-1",
  "role": "master"
}
```

### 验证 2：页面是否符合角色预期

- `standalone`：`/` 应该是用户门户
- `master`：`/` 应该是用户门户
- `subnode`：`/` 应该是子节点状态页

### 验证 3：集群是否连通

在 `master` 管理后台查看：

- 子节点是否出现
- 心跳是否持续更新
- 有效容量是否正常
- 节点是否健康

---

## GHCR 镜像

仓库支持通过 GHCR 发布镜像：

- `ghcr.io/<owner>/flow_captcha_service-master`
- `ghcr.io/<owner>/flow_captcha_service-headed`

拉取示例：

```bash
docker pull ghcr.io/genz27/flow_captcha_service-master:latest
docker pull ghcr.io/genz27/flow_captcha_service-headed:latest
```

说明：

- `master` 镜像用于主节点
- `headed` 镜像用于 `standalone` 或 `subnode`
- `headed` 镜像同时支持 `browser` 和 `personal` 两种本地打码模式

---

## 常见问题

### 1. 为什么子节点首页没有登录/注册？

这是当前版本的设计。

`subnode` 首页现在是**子节点状态页**，只用于：

- 看当前角色
- 看健康状态
- 进后台排查

用户门户只应该放在 `master` 或 `standalone`。

### 2. 为什么主节点和子节点不能共用一个 `data` 目录？

因为会共用：

- 数据库
- API Key
- 集群状态
- 日志

结果会导致状态混乱。

### 3. 本地 Python 启动后浏览器起不来怎么办？

优先检查：

1. 是否执行过 `python -m playwright install chromium`
2. Linux 是否缺依赖，必要时使用
   `python -m playwright install --with-deps chromium`
3. 如果正在使用 `personal` 模式，确认当前环境已经安装 `nodriver`
4. Docker `headed` 镜像会自动注入 Playwright Chromium 路径；如果你是手工运行，请确认 `BROWSER_EXECUTABLE_PATH` 或系统 Chrome/Chromium 可执行文件可用
5. 代理或显示环境是否异常

### 4. `cluster.node_max_concurrency = 0` 是什么意思？

表示：

- 不手动固定并发值
- 自动跟随 `browser_count`

### 5. `master` 会不会本地执行浏览器打码？

不会。

`master` 只负责调度和转发，真正执行浏览器打码的是 `subnode`
或者 `standalone`。

---

## 总结

如果你是第一次接触这个项目，最推荐的顺序是：

1. 先跑 `standalone`
2. 用 `/admin` 创建 API Key
3. 用 `solve -> finish/error` 跑通一遍
4. 再尝试 `master + subnode` 集群

如果你看到子节点首页不是登录页，而是状态页，这不是异常，
而是当前版本的预期行为。
