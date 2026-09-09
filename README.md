# omlx-watchdog

![Platform](https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-5A67D8?logo=apple&logoColor=white)
![oMLX](https://img.shields.io/badge/oMLX-%3E%3D0.6.4-2EA44F)
![launchd](https://img.shields.io/badge/scheduler-launchd-FFD43B?logo=apple&logoColor=black)
![Version](https://img.shields.io/badge/version-v6-007EC6)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![Python](https://img.shields.io/badge/python-3.9+-2C4F7C?logo=python&logoColor=white)
![Bash](https://img.shields.io/badge/bash-3.2+-121011?logo=gnubash&logoColor=white)

**Keep your local [oMLX](https://github.com/jundot/omlx) inference server alive.**

A launchd-based health watchdog for [oMLX](https://github.com/jundot/omlx) (local OpenAI-compatible LLM server for Apple Silicon). It detects wedged/stopped engines and recovers them automatically — with **zero false-positive restarts**, so long-running agent sessions (DSH, OpenClaw, …) survive crashes without human intervention and without the watchdog itself causing the failures it monitors.

Battle-tested for a week+ on **Apple M5 Max / 128 GB / macOS** serving Qwen3.8-27B for an autonomous coding agent: zero manual recoveries, every crash self-healed within ~2–4 minutes.

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
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX home (must contain `settings.json`) |

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

### Result after a week of production use

- Every observed failure (Metal wedge, SIGKILL, port conflict) self-healed in **≤ 4 min**, unattended.
- Zero false-positive restarts (v6). Earlier versions: 2 incidents → both fixed and documented above (#3, #4 in the table).
- Agent sessions (DSH) resumed automatically through every recovery; no task lost.

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

## Version history (what each version fixed)

| v | Date | Change |
|---:|---|---|
| 3/4 | 2026-09-07 | Checks A–D introduced; PORT-CLEAN added (v4) — killed *all* port-8000 holders incl. clients → could kill a freshly started server |
| 5 | 2026-09-08 | PORT-CLEAN restricted to **LISTENER only** (`lsof -sTCP:LISTEN`); model follows `default_model`; fixes the stale-model restart loop |
| 6 | 2026-09-08 | Model = `/api/status` **`loaded_models[0]`** (multi-model switching safe; nothing loaded → checks skipped, never force-loads); env-overridable paths/port/stall threshold |

## Related

- [jundot/omlx](https://github.com/jundot/omlx) — the inference server this watchdog protects (Apache-2.0, ⭐ 21k+)
- [ricky8848/mac-m5-128g-omlx-settings](https://github.com/ricky8848/mac-m5-128g-omlx-settings) — full M5 Max 128 GB + DSH long-running setup (also posted as [jundot/omlx#3496](https://github.com/jundot/omlx/issues/3496))

## License

[MIT](./LICENSE) © ricky8848. No affiliation with oMLX or its maintainers; this is an independent community tool.
