# omlx-watchdog

**让你的本地 [oMLX](https://github.com/jundot/omlx) 推理服务器保持存活。**

基于 launchd 的健康看门狗（watchdog），专为 [oMLX](https://github.com/jundot/omlx)（Apple Silicon 本地 OpenAI 兼容 LLM 服务器）设计。自动检测 wedged/停止的引擎并恢复——**零误杀重启**，让长时间运行的 Agent 会话（DSH、OpenClaw…）在崩溃后无人值守地存活，且看门狗本身不会触发它所监控的故障。

已在 **Apple M5 Max / 128 GB / macOS** 上实战验证一周以上：Qwen3.8-27B 服务自主编码 Agent，零人工干预恢复，每次崩溃 ~2–4 分钟自愈。

## 为什么需要它 —— oMLX 实际存在的问题

| # | 现象（实测） | 根因 | omlx-watchdog 的解决方案 |
|---:|---|---|---|
| 1 | 请求被接受但 **30+ 分钟无 token**（引擎 Metal wedge） | GPU command buffer 卡死；进程"活着"、日志还在写（看起来在忙） | **Check C**：真实 completion probe（`max_tokens=4`）证明引擎真的能*生成*；**Check D**：有在途请求时 token 计数器停滞 ≥900s = wedged。（"日志 mtime=忙"的朴素启发式会被取消请求自干扰击败，v2 已弃用） |
| 2 | oMLX 进程静默死亡（内存压力下 SIGKILL） | OOM / crash reporter 杀掉引擎，无人重启 | **Check A**（`/api/status` 可达性）→ 60s tick 内触发完整恢复阶梯 |
| 3 | 重启永远失败：*port 8000 already in use*；"修复"时误杀客户端连接 | 残留 listener（或其子进程）占着端口；`lsof -ti` 式清理会匹配 *client* socket，杀掉刚启动的服务 | **PORT-CLEAN 只杀 LISTENER**（`lsof -sTCP:LISTEN`），等 30s，再升级 `kill -9`；客户端永不触碰 |
| 4 | 切换模型后无限重启循环 —— 看门狗一直拿旧模型名探测，"恢复"到同样坏的状态 | 模型检查硬编码/跟随 `default_model`，而 oMLX 实际加载的是另一个 | **v6：模型 = `/api/status` → `loaded_models[0]`** —— 跟随 oMLX *实际加载*的模型；无模型 → 跳过检查，绝不强制加载 |
| 5 | 看门狗自己触发它要监控的故障（probe 撞在途请求；两个 tick 重叠） | probe 未看队列状态就发；慢 Check C 跨入下一个 60s tick | probe **仅在 `active+waiting == 0`**（队列可证为空）时执行；PID lockfile 防重入 |
| 6 | Agent harness（DSH）重试死循环或过早放弃 | 重试窗口与恢复时间不匹配（太激进=死亡循环；太短=restart 中途任务死） | 配套 harness 配置：有界重试（如 DSH `maxRetries=40`，最坏 ~35min）覆盖 2–4 min restart + 模型自动加载；永久故障显式失败 |
| 7 | **多 Agent 并发时无限重启循环**：Check D 触发 restart → 所有 in-flight agent 断开 → token counter 停滞 → Check D 再次触发 | restart 后模型未加载（lazy load），agent 排队等 token，watchdog 每 60s tick 都看到 stall → **无限循环** | **v9：300s 冷却期 + warm-up 请求**。restart 后 5min 内不再触发第二次 restart；agent 通过 DSH retry 自行恢复。warm-up（`max_tokens=1`）将 TTFT 从 ~25s 降至 <3s |
| 8 | Docker Desktop 升级/macOS 重启后 LaunchAgent 静默丢失，watchdog 停止运行 | `~/Library/LaunchAgents/` plist 被系统移除或不被加载 | **v8：launchd self-heal** —— 每次 tick 检查自身注册状态（`launchctl print gui/uid/label`），未注册则从磁盘 plist 重新 bootstrap |

### 设计第一性原理

> **任何 oMLX restart 之后，模型必须被重新识别，让在途任务继续完成。**

oMLX 首次请求时自动加载模型（27B ~7s）。Check C 的空闲 probe 恰好在队列为空时运行——因此它在恢复后*就是*第一个请求，在真实任务回来之前把模型预热好。harness 侧的有界重试窗口覆盖：watchdog tick（≤60s）+ restart（~2–4min）+ 模型自动加载（~10s）。

## 一键安装（macOS，Apple Silicon）

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

带选项：

| 变量 | 默认值 | 含义 |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX API 地址（端口从这里解析，用于 PORT-CLEAN） |
| `OMLX_WATCHDOG_STALL` | `900` | 有在途请求时，token 计数器停滞多少秒判定 wedged |
| `OMLX_WATCHDOG_RESTART_COOLDOWN` | `300` | 任何 restart 后多少秒内不再触发第二次（v9） |
| `OMLX_WATCHDOG_DOCKER` | `/usr/local/bin/docker` | Docker CLI 绝对路径（launchd PATH 最小；v8） |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX 家目录（必须含 `settings.json`） |
| `OMLX_WATCHDOG_LAUNCHD_LABEL` | `com.ricky8848.omlx-watchdog` | launchd agent label（self-heal 用；v8） |

安装器会：
1. 预检 macOS + oMLX（`~/.omlx/settings.json`），定位 `omlx` CLI。
2. 下载 [`scripts/watchdog.sh`](../scripts/watchdog.sh) → `~/.omlx/watchdog.sh`（自动备份旧版）。
3. 写 launchd plist → `~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist`（`StartInterval=60`，登录自启）。
4. 加载 agent 并验证注册成功。

**卸载：**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## 工作原理 —— 4 项检查，每 60s

| Check | 方法 | 触发条件 | 为什么不会自干扰 |
|---:|---|---|---|
| **A** 可达性 | `GET /api/status`（5s） | 服务挂掉或响应不可解析 | 瞬时只读调用，永不排队 |
| **B** 模型在册 | `GET /v1/models` grep 已加载名 | 实际加载的模型不在注册表（状态损坏） | 每 tick 读 `loaded_models[0]`——切换模型安全；空 → 跳过，绝不强制加载 |
| **C** 空闲 completion probe | 真实 `POST /v1/chat/completions`，`max_tokens=4`（90s） | 引擎接受但不产 token（Metal wedge）——**仅当 `active+waiting == 0`** | 队列可证为空 → 不与真实工作冲突；兼作 restart 后的模型预热（触发 lazy load） |
| **D** 停滞检测器 | `total_prompt_tokens + total_completion_tokens` vs 上 tick | 有在途请求 **且** 计数器冻结 ≥ `STALL_SECONDS`（默认 900s） | 仅在有工作在途时计时；计数器重置（外部 restart）重新装填定时器而非误报 |

**恢复阶梯**（任一 check 失败）：`omlx restart --timeout 240` → **PORT-CLEAN**（只杀 listener，30s 宽限，`kill -9`）+ retry → 最后 `open -a oMLX`。然后轮询 `/api/status` 最多 4min；记录 `RECOVERED: oMLX up (loaded=<model>)` 并重置停滞状态。

### v9：多 Agent 重启循环防护（2026-09-11）

多个 agent 共享一个 oMLX 实例时，restart 会断开所有 in-flight 请求。没有保护机制的话，Check D 每 60s tick 重复触发 → **无限重启循环**。

| 特性 | 机制 |
|---:|---|
| **重启冷却期**（300s） | `do_restart()` 入口检查 `/tmp/omlx-watchdog-cooldown`（上次 restart 的 epoch）。冷却期内所有 check 跳过重启——agent 通过 DSH retry 自行恢复。冷却期结束后 stall state 清零，900s 计时器从零重新积累 |
| **模型加载轮询**（v9.1，30s） | restart 恢复后，omlx v0.6.x lazy-load：模型在第一个真实请求时才加载。watchdog 轮询 `loaded_models` 最多 30s，确保 warm-up 在模型实际加载后才执行 |
| **Warm-up 请求**（`max_tokens=1`） | 模型出现在 `loaded_models` 后，发一个推理请求预热 VRAM + Metal kernel。后续 agent 请求 TTFT <3s（vs 16.6GB 模型冷加载 ~25s） |

**实测：** 3 agent 并发 SSE + `omlx restart` → 2 agent 被中断（预期，rc=18），系统 ~22s 恢复，**冷却期内零第二次重启**。8/8 检查通过。

### v9：Docker Desktop + launchd self-heal（合并自 docker-watchdog）

| 特性 | 机制 |
|---:|---|
| **Docker Desktop guard** | 每次 tick：`pgrep -f "Docker Desktop"` → daemon check（绝对路径 CLI）。仅当进程和 daemon 都不存在时才 `open -a Docker` |
| **launchd self-heal** | `launchctl print gui/$(id -u)/<label>` —— agent 未注册（Docker Desktop 升级 / macOS 重启静默移除 LaunchAgents）时从磁盘 plist 重新 bootstrap |

### 一周生产实测结果

- 所有观察到的故障（Metal wedge、SIGKILL、端口冲突）全部 **≤4min 无人自愈**。
- v6：零误杀重启。早期版本有 2 起事故 → 均已修复并记录在上方表格（#3、#4）。
- Agent 会话（DSH）穿过每次恢复自动续跑；无任务丢失。

## FAQ —— 屏幕每分钟抖动一下？

**通常不是 omlx-watchdog。** 看门狗自身只做 HTTP GET/POST（无 UI、无窗口操作），且当前版本下不会触发任何重启。

每分钟一次的抖动，最常见的元凶是**另一个 launchd agent 每分钟 `open -a` 一个 GUI App**。排查方法：

```bash
# 1. 列出所有每 60s 运行的 agent
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. 看哪个在反复启动 GUI App（本案例：docker-watchdog.sh 每分钟 open -a Docker）
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null

# 3. 找到后：修好目标服务，或给脚本加"已运行则跳过"的守卫
```

**本案例实录（2026-09）：** `com.ricky.docker-watchdog` 每分钟执行 `open -a Docker`。Docker Desktop 的 GUI（Electron）每次被 `open -a` 都会重新激活窗口 → 屏幕抖一下。即使 Docker daemon 已 UP，脚本的 `docker info` 探测在特定窗口期仍失败 → 每分钟都触发。修复：修好 Docker daemon / 给脚本加 `pgrep -f "Docker Desktop" && exit 0` 守卫。

## 配套配置（Agent harness 侧，DSH 示例）

```yaml
# ~/.dsh/settings.yaml — provider block（示例）
providers:
  omlx:
    baseURL: http://127.0.0.1:8000/v1
    defaultContextWindow: 128000   # 声明真实窗口 → 自动压缩先于 omlx memory guard
    streamIdleTimeoutMs: 600000    # 10min idle = 还在等 restart，不是死了
    retryPolicy:
      maxRetries: 40               # 最坏 ~35min > restart(~2-4min) + 模型自动加载
      retryableCodes: [TIMEOUT, TRANSPORT]
```

oMLX 侧（`~/.omlx/settings.json`）：`sampling.max_context_window`、`prefill_memory_guard`（tier + ceiling）、单用户 Agent 场景 `max_concurrent_requests: 1`。

## 文件清单 / Requirements & 安全说明

- macOS（Apple Silicon）、oMLX ≥0.6.x、`~/.omlx/settings.json` 含 API key。
- watchdog 从 `settings.json` **运行时读取** oMLX API key（用于认证健康探测）——永不写日志、不落盘其他位置、不离开本机。
- **无网络外发**（除 `127.0.0.1`）。无遥测。
- 空闲 probe（Check C）每次 idle tick 消耗几个 token；有真实工作在途时跳过。
- 脚本只触碰：`~/.omlx/`（自身日志）、`/tmp/omlx-watchdog-*` 状态文件、通过 `omlx restart` 控制 oMLX 进程。

## License

[MIT](../LICENSE) © ricky8848. 与 oMLX 及其维护者无隶属关系；独立的社区工具。
