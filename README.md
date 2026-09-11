# omlx-watchdog

**[oMLX](https://github.com/jundot/omlx) Watchdog** — self-healing health monitor for local LLM inference on Apple Silicon

| | |
|---|---|
| **Build** | [![CI](https://github.com/ricky8848/omlx-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/ricky8848/omlx-watchdog/actions/workflows/ci.yml) [![Auto-Reply](https://github.com/ricky8848/omlx-watchdog/actions/workflows/auto-reply.yml/badge.svg)](https://github.com/ricky8848/omlx-watchdog/actions/workflows/auto-reply.yml) |
| **Release** | [![Version](https://img.shields.io/github/v/release/ricky8848/omlx-watchdog?label=version)](https://github.com/ricky8848/omlx-watchdog/releases) [![DOI](https://zenodo.org/badge/22675074.svg)](https://doi.org/10.5281/zenodo.22675075) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE) [![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-5A67D8?logo=apple&logoColor=white)](https://github.com/ricky8848/omlx-watchdog) |
| **Community** | [![Issues](https://img.shields.io/github/issues/ricky8848/omlx-watchdog?label=issues)](https://github.com/ricky8848/omlx-watchdog/issues) [![Issues closed](https://img.shields.io/github/issues-closed/ricky8848/omlx-watchdog?label=issues%20closed)](https://github.com/ricky8848/omlx-watchdog/issues?q=is%3Aissue+is%3Aclosed) [![Contributors](https://img.shields.io/github/contributors/ricky8848/omlx-watchdog?label=contributors)](https://github.com/ricky8848/omlx-watchdog/graphs/contributors) |
| **Activity** | [![Last commit](https://img.shields.io/github/last-commit/ricky8848/omlx-watchdog?label=last%20commit)](https://github.com/ricky8848/omlx-watchdog/commits) [![Repo size](https://img.shields.io/github/repo-size/ricky8848/omlx-watchdog?label=repo%20size)](https://github.com/ricky8848/omlx-watchdog) [![L10n](https://img.shields.io/badge/l10n-7%20languages-blueviolet)](docs/i18n/) |
| **Social** | [![Stars](https://img.shields.io/github/stars/ricky8848/omlx-watchdog?style=social)](https://github.com/ricky8848/omlx-watchdog/stargazers) [![Forks](https://img.shields.io/github/forks/ricky8848/omlx-watchdog?style=social)](https://github.com/ricky8848/omlx-watchdog/forks) [![Sponsor](https://img.shields.io/badge/sponsor-❤️-support-green?logo=github-sponsors)](https://github.com/sponsors/ricky8848) |

**Keep your local [oMLX](https://github.com/jundot/omlx) inference server alive.**

A launchd-based health watchdog for [oMLX](https://github.com/jundot/omlx) (local OpenAI-compatible LLM server for Apple Silicon). It detects wedged/stopped engines and recovers them automatically — with **zero false-positive restarts**, so long-running agent sessions (DSH, OpenClaw, …) survive crashes without human intervention and without the watchdog itself causing the failures it monitors.


**📖 Documentation in your language / 多语言文档:**

| 🇬🇧 English | 🇨🇳 简体中文 | 🇯🇵 日本語 | 🇰🇷 한국어 |
|:---:|:---:|:---:|:---:|
| [README](./README.md) *(this file)* | [简体中文](docs/i18n/README.zh-CN.md) | [日本語](docs/i18n/README.ja.md) | [한국어](docs/i18n/README.ko.md) |

| 🇪🇸 Español | 🇫🇷 Français | 🇩🇪 Deutsch |
|:---:|:---:|:---:|
| [Español](docs/i18n/README.es.md) | [Français](docs/i18n/README.fr.md) | [Deutsch](docs/i18n/README.de.md) |

Battle-tested for a week+ on **Apple M5 Max / 128 GB / macOS** serving Qwen3.8-27B for an autonomous coding agent: zero manual recoveries, every crash self-healed within ~2–4 minutes.

> **📄 Technical Report:** [A Self-Healing Watchdog for Local LLM Inference Servers on Apple Silicon — A Field Study of oMLX Failure Modes and Bounded Recovery](https://doi.org/10.5281/zenodo.22675075) (English + 简体中文, PDF on [Zenodo](https://zenodo.org/records/22675075); LaTeX source in [`docs/paper/`](./docs/paper/)). 13-day production trace: six formalized failure classes, a self-interference-free four-check health model, and a bounded escalation ladder — MTTD ≤ 60 s, MTTR < 4 min over 18,516 ticks.

## Why this exists — the problems oMLX actually has

Running a local inference server 24/7 for agent workloads produces failure modes that "it's just a process" doesn't cover:

| # | Symptom (observed) | Root cause | How omlx-watchdog handles it |
|---:|---|---|---|
| 1 | Request accepted, **no tokens for 30+ min** — engine wedged at the Metal layer | GPU command buffer stalls; process looks alive, logs keep writing (busy-looking) | **Check C**: a real completion probe (`max_tokens=4`) proves the engine can actually *generate*; **Check D**: token-counter stall ≥ 900 s with work in flight = wedged. (Naive "log mtime" heuristics are defeated by cancelled requests — v2 learned this the hard way.) |
| 2 | oMLX process dies silently (SIGKILL under memory pressure) | OOM / crash reporter kills the engine; nothing restarts it | **Check A** (`/api/status` reachability) → full recovery ladder within one 60 s tick |
| 3 | Restart fails forever: *port 8000 already in use* — and "fixing" it kills client connections | A leftover listener (or child) holds the port; `lsof -ti`-style cleanup also matches *client* sockets, killing freshly started servers | **PORT-CLEAN kills the LISTENER only** (`lsof -sTCP:LISTEN`), waits 30 s, escalates to `kill -9`; clients are never touched |
| 4 | Endless restart loop after switching models — watchdog kept probing a stale model name and "recovered" into the same broken state | Model check hardcoded to / following `default_model` while oMLX actually loaded a different one | **v6: model = `/api/status` → `loaded_models[0]`** — follows whatever oMLX *actually has loaded*; nothing loaded → model checks skipped, never force-loads |
| 5 | The watchdog itself triggers the failure it monitors (probe collides with in-flight work; two ticks overlap) | Probe fired while the queue was non-empty; a slow Check C spanned into the next 60 s tick | Probe **gated on `active+waiting == 0`** (queue provably empty); PID lock file prevents overlapping runs |
| 6 | Agent harness retries spin forever on a dead model — or give up during the restart window | Harness retry policy not sized to recovery time (too aggressive = death loop; too short = task dies mid-restart) | Documented companion settings: bounded retries (e.g. DSH `maxRetries=40`, ~35 min worst case) covering the 2–4 min restart + model auto-load, with explicit failure for permanent faults |

### The first-principle this design protects

> **After any oMLX restart, the model must be re-recognized so in-flight tasks continue to completion.**

oMLX auto-loads a model on first request (~7 s for a 27B). Check C's idle probe runs exactly when the queue is empty — so it *is* that first request right after recovery, warming the model before your real task resumes. The harness-side bounded retry window is sized to cover: watchdog tick (≤60 s) + restart (~2–4 min) + model auto-load (~10 s).

## One-click install (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

With options:

```bash
OMLX_WATCHDOG_API=http://127.0.0.1:8000 OMLX_WATCHDOG_STALL=900 \
  curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| Variable | Default | Meaning |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX API base URL (port parsed from here for port-cleanup) |
| `OMLX_WATCHDOG_STALL` | `900` | Seconds of token-counter stall (with work in flight) before declaring wedged |
| `OMLX_WATCHDOG_RESTART_COOLDOWN` | `300` | Seconds after any restart during which no further restart is triggered (v9) |
| `OMLX_WATCHDOG_DOCKER` | `/usr/local/bin/docker` | Absolute path to Docker CLI (launchd has minimal PATH; v8) |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX home (must contain `settings.json`) |
| `OMLX_WATCHDOG_LAUNCHD_LABEL` | `com.ricky8848.omlx-watchdog` | launchd agent label for self-heal (v8) |

The installer:
1. Verifies macOS + oMLX presence (`~/.omlx/settings.json`), locates the `omlx` CLI (Homebrew or PATH).
2. Downloads [`scripts/watchdog.sh`](./scripts/watchdog.sh) → `~/.omlx/watchdog.sh` (backs up any previous version).
3. Writes a launchd plist → `~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist` (`StartInterval=60`, `RunAtLoad`).
4. Loads the agent and verifies registration.

**Uninstall:**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## How it works — 4 checks, every 60 s

| Check | Method | Fires when | Why it can't self-interfere |
|---:|---|---|---|
| **A** reachability | `GET /api/status` (5 s timeout) | server down, or response unparseable | instant read-only call; never queues work |
| **B** model registered | `GET /v1/models`, grep the loaded name | actually-loaded model missing from registry (corrupt state) | reads `loaded_models[0]` each tick — survives model switching; empty → skipped, never force-loads |
| **C** idle completion probe | real `POST /v1/chat/completions`, `max_tokens=4` (90 s timeout) | engine accepts but produces no tokens (Metal wedge) — **only when `active+waiting == 0`** | queue provably empty → no collision with real work; doubles as post-restart model warm-up (triggers lazy load) |
| **D** stall detector | `total_prompt_tokens + total_completion_tokens` vs last tick | work in flight **and** counter frozen ≥ `STALL_SECONDS` (default 900 s) | only arms while work is in flight; counter reset (external restart) re-arms the timer instead of false-firing |

**Recovery ladder** (any check fails): `omlx restart --timeout 240` → **PORT-CLEAN** (listener-only kill, 30 s grace, `kill -9`) + retry → last resort `open -a oMLX`. Then poll `/api/status` for up to 4 min; log `RECOVERED: oMLX up (loaded=<model>)` and reset stall state.

### v9: Multi-agent restart-loop protection (2026-09-11)

When multiple agents share one oMLX instance, a restart drops all in-flight requests. Without protection, Check D re-fires every 60 s tick while agents are queued → **infinite restart loop**.

| Feature | How it works |
|---:|---|
| **Restart cooldown** (300 s) | `do_restart()` checks `/tmp/omlx-watchdog-cooldown` (epoch of last restart). Within the window, all checks skip restarting — agents recover on their own via DSH retry. Cooldown ends → stall state cleared, 900 s timer re-arms from zero |
| **Model-load poll** (v9.1, 30 s) | After restart recovery, omlx v0.6.x lazy-loads the model on first real request. The watchdog polls `loaded_models` for up to 30 s before warm-up, so the agent's first post-restart request hits a hot model |
| **Warm-up request** (`max_tokens=1`) | After the model appears in `loaded_models`, one inference primes VRAM + Metal kernels. Subsequent agent requests: TTFT < 3 s (vs ~25 s cold load for a 16.6 GB model) |

**Tested:** 3 concurrent SSE agents + `omlx restart` → 2 interrupted (expected, rc=18), system recovered in ~22 s, **zero second restart** during cooldown. 8/8 checks pass.

### v9: Docker Desktop + launchd self-heal (merged from docker-watchdog)

| Feature | How it works |
|---:|---|
| **Docker Desktop guard** | Every tick: `pgrep -f "Docker Desktop"` → daemon check via absolute-path CLI. Only launches Docker if *both* process and daemon are absent |
| **launchd self-heal** | `launchctl print gui/$(id -u)/<label>` — if the agent is not registered (Docker Desktop upgrade / macOS reboot silently drops LaunchAgents), re-bootstrap from the plist on disk |

### Result after a week of production use

- Every observed failure (Metal wedge, SIGKILL, port conflict) self-healed in **≤ 4 min**, unattended.
- Zero false-positive restarts (v6). Earlier versions: 2 incidents → both fixed and documented above (#3, #4 in the table).
- Agent sessions (DSH) resumed automatically through every recovery; no task lost.

## FAQ — Screen jitters once per minute?

**Usually it's NOT omlx-watchdog.** The watchdog itself only does HTTP GET/POST (no UI, no window manipulation), and in the current version it triggers zero restarts on a healthy server.

The most common culprit of once-per-minute jitter is **another launchd agent that runs `open -a <GUI App>` every 60 s**. How to find it:

```bash
# 1. List all agents with StartInterval=60
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. Find which one re-launches a GUI app (real case: docker-watchdog.sh ran open -a Docker every minute)
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**Real case (Sept 2026):** `com.ricky.docker-watchdog` executed `open -a Docker` every minute. The Docker Desktop GUI (Electron) re-activates its window on each `open -a` → screen jitters. Even with the Docker daemon UP, the script's probe failed in certain windows and fired every minute. Fix: repair the Docker daemon / add a `pgrep -f "Docker Desktop" && exit 0` guard to the script.

## Companion settings (agent harness side, DSH example)

The watchdog covers oMLX-side recovery. The **harness** must be sized to wait through it:

```yaml
# ~/.dsh/settings.yaml — provider block (example)
providers:
  omlx:
    baseURL: http://127.0.0.1:8000/v1
    defaultContextWindow: 128000   # declare the REAL window → auto-compaction triggers before omlx's memory guard rejects
    streamIdleTimeoutMs: 600000    # 10 min idle = still waiting through a restart, not dead
    retryPolicy:
      maxRetries: 40               # worst case ~35 min > restart (~2-4 min) + model auto-load
      retryableCodes: [TIMEOUT, TRANSPORT]
```

oMLX side (`~/.omlx/settings.json`): `sampling.max_context_window`, `prefill_memory_guard` (tier + ceiling), and for single-user agent workloads `max_concurrent_requests: 1` (long-context concurrency=2 measurably *slows* each request).

## Files

| Path | Purpose |
|---:|---|
| [`scripts/watchdog.sh`](./scripts/watchdog.sh) | the health-check script (env-overridable, no hardcoded model names or paths beyond defaults) |
| [`scripts/install.sh`](./scripts/install.sh) | one-click installer (preflight checks, backup, launchd registration) |
| [`SKILL.md`](./SKILL.md) | agent-consumable skill description (when to use, install, problem catalog) |
| `~/.omlx/logs/watchdog.log` (runtime) | check/recovery log, auto-rotated at 10 MB |

## Requirements & safety notes

- macOS (Apple Silicon), [oMLX](https://github.com/jundot/omlx) ≥ 0.6.x, `~/.omlx/settings.json` present with an API key.
- The watchdog reads the oMLX **API key** from `settings.json` for authenticated health probes. It is never logged, written anywhere else, or transmitted off-machine.
- **No network egress** except to `127.0.0.1`. No telemetry, no phoning home.
- The idle probe (Check C) costs a few tokens per tick while the server is idle; it is skipped whenever real work is in flight.
- The script only ever touches: `~/.omlx/` (its own log), `/tmp/omlx-watchdog-*` state files, and the oMLX process via `omlx restart`.

## Auto-maintenance (GitHub Actions)

| Workflow | What it does |
|---:|---|
| [`CI`](.github/workflows/ci.yml) | ShellCheck on both scripts + YAML lint of issue templates (runs on every push/PR — the "CI" badge above) |
| [`Auto-Reply`](.github/workflows/auto-reply.yml) | On a **new issue**: posts a bilingual draft reply asking for the 4 diagnostic items (omlx version, macOS+chip, watchdog log tail, version line) and labels it `auto-reply-draft`. On a **new issue comment**: posts an acknowledgement. Maintainer notification to Gmail happens via GitHub's built-in email notifications (Settings → Notifications) — no extra credentials in the repo |

Issue templates ([`.github/ISSUE_TEMPLATE`](.github/ISSUE_TEMPLATE)): structured **bug report** (symptom dropdown, required environment block) and **question**.

> To route auto-replies to a specific Gmail address: GitHub already emails you on every issue/comment by default. For *custom* automated email (e.g. a dedicated inbox), add an SMTP step to the workflow — but that requires storing credentials in GitHub Secrets, which this repo deliberately avoids.

## Version history (what each version fixed)

| v | Date | Change |
|---:|---|---|
| 3/4 | 2026-09-07 | Checks A–D introduced; PORT-CLEAN added (v4) — killed *all* port-8000 holders incl. clients → could kill a freshly started server |
| 5 | 2026-09-08 | PORT-CLEAN restricted to **LISTENER only** (`lsof -sTCP:LISTEN`); model follows `default_model`; fixes the stale-model restart loop |
| 6 | 2026-09-08 | Model = `/api/status` **`loaded_models[0]`** (multi-model switching safe; nothing loaded → checks skipped, never force-loads); env-overridable paths/port/stall threshold |
| 8 | 2026-09-11 | **Merged docker-watchdog** into single script; launchd self-heal (`launchctl print gui/uid/label` → re-bootstrap if dropped); Docker Desktop guard |
| **9** | **2026-09-11** | **Multi-agent restart-loop protection**: 300 s cooldown after any restart; warm-up request (`max_tokens=1`) cuts TTFT from ~25 s to <3 s |
| **9.1** | **2026-09-11** | **Model-load poll after restart** (30 s) — ensures warm-up fires only when the model is actually loaded; fixes v9 edge case where `model=none` (lazy load) caused warm-up to be skipped |

## Works with

| Tool | Role | Integration |
|---:|---|---|
| [oMLX](https://github.com/jundot/omlx) ≥ 0.6.x | Inference server (Metal/ANE, MTP, TurboQuant KV) | `omlx restart` primitive; `/api/status`, `/v1/models` probes |
| [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/DeepSeek-Harness) | Agent harness (client-side retry budget `maxRetries=40`) | Bounded retries span the 2–4 min restart window |
| [mac-m5-128g-omlx-settings](https://github.com/ricky8848/mac-m5-128g-omlx-settings) | Full M5 Max 128 GB config (oQ4e + MTP + TQKV) | Companion repo; also posted as [jundot/omlx#3496](https://github.com/jundot/omlx/issues/3496) |
| [Homebrew tap](https://github.com/ricky8848/homebrew-tap) | Package distribution (`brew install ricky8848/tap/omlx-watchdog`) | Formula auto-updates on each release tag |

## Related

## License

[MIT](./LICENSE) © ricky8848. No affiliation with oMLX or its maintainers; this is an independent community tool.
