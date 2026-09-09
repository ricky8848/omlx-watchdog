# omlx-watchdog — SKILL

> Keep a local [oMLX](https://github.com/jundot/omlx) inference server alive on macOS: detect wedged/stopped engines and recover them automatically, without false-positive restarts that would interrupt in-flight agent sessions.

## When to use this skill

- You run **oMLX** (local OpenAI-compatible LLM server for Apple Silicon) as the backend of an agent harness (DSH, OpenClaw, custom scripts).
- Long-running tasks must **survive oMLX crashes / Metal wedges** without human intervention.
- You previously hit any of these failure modes: engine accepts a request but never emits tokens (wedged), server process dies silently, restart leaves the port occupied so the next start fails forever, or a health check itself caused the crash it was meant to catch.

## One-click install (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

Options (env vars):

| Variable | Default | Meaning |
|---|---|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX API base URL (port parsed from here for port-cleanup) |
| `OMLX_WATCHDOG_STALL` | `900` | Seconds of token-counter stall (with requests in flight) before declaring the engine wedged |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX home directory (must contain `settings.json`) |

Uninstall:

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## What it does (4 checks, every 60s via launchd)

| Check | Method | Fires when | Why it's safe (no self-interference) |
|---|---|---|---|
| **A** reachability | `GET /api/status` (5s) | server down or response unparseable | instant read-only call, never queues work |
| **B** model registered | `GET /v1/models`, grep loaded model name | the actually-loaded model is missing from the registry (corrupt state) | dynamic: reads `loaded_models[0]` each tick — survives model switching; empty (nothing loaded) → check skipped, never force-loads |
| **C** idle completion probe | real `POST /v1/chat/completions` (`max_tokens=4`) | engine accepts the request but produces no tokens (Metal wedge) — **only when `active+waiting == 0`** | the queue is provably empty, so the probe can't collide with real work; this also triggers oMLX's lazy model load, keeping the first post-restart request fast |
| **D** stall detector | token counters from `/api/status` vs. last tick | `active+waiting > 0` **and** total token count frozen for ≥ `STALL_SECONDS` (default 900s) | only arms while work is in flight; a healthy idle server never trips it; counters resetting (external restart) re-arms the timer instead of false-firing |

Recovery ladder on any failure: `omlx restart --timeout 240` → if that fails, kill the **listener only** on the API port (`lsof -sTCP:LISTEN`, never client connections) and retry → last resort `open -a oMLX`. Then poll `/api/status` for up to 4 minutes and log `RECOVERED: oMLX up (loaded=<model>)`.

## Problems this solves (observed in the wild)

| # | Symptom | Root cause | Fix in this watchdog |
|---:|---|---|---|
| 1 | Request accepted, **no tokens for 30+ min** (engine wedged at the Metal layer) | GPU command buffer stalls; server process looks alive, logs look active | Check **C** (real completion probe) + Check **D** (counter stall ≥900s). v2-era "log mtime = busy" heuristics were defeated by cancelled-request self-interference — removed |
| 2 | oMLX process dies silently (SIGKILL, OOM) | memory pressure / crash reporter | Check **A** → restart ladder |
| 3 | Restart fails forever: "port 8000 already in use" | previous listener (or its children) still bound to the port; naive `lsof -ti` kill also killed *client* connections, killing freshly-started servers (v4 bug) | **PORT-CLEAN kills the LISTENER only** (`-sTCP:LISTEN`), waits 30s, then `kill -9`; clients are never touched |
| 4 | Endless restart loop after the user switched models (watchdog kept probing a stale model name) | hardcoded / `default_model`-based check after a default switch left the old name in place | **v6: model = `/api/status` `loaded_models[0]`** — follows whatever oMLX actually has loaded; nothing loaded → checks skipped, never force-loads |
| 5 | Watchdog itself causes the failure it monitors (probe collides with in-flight work; two watchdog ticks overlap) | probe fired while queue non-empty; StartInterval tick landed inside a slow previous run | Check C gated on `active+waiting == 0`; **PID lock file** re-entrancy guard |
| 6 | Agent harness (DSH) retries spin on a permanently dead model, or give up too early during the restart window | retry policy not sized to the recovery time | Pair with bounded retries at the harness layer: e.g. DSH `retryPolicy.maxRetries=40` + `streamIdleTimeoutMs=600000` covers the ~2–4 min restart + model auto-load window; permanent failures then fail explicitly instead of looping |

## Companion settings (DSH example)

The watchdog covers oMLX-side recovery. The agent harness side needs matching timeouts so it *waits through* the restart instead of erroring out:

```yaml
# ~/.dsh/settings.yaml — provider block (DSH example)
providers:
  omlx:
    baseURL: http://127.0.0.1:8000/v1
    defaultContextWindow: 128000     # declare the REAL window so auto-compaction triggers before omlx's memory guard
    streamIdleTimeoutMs: 600000      # 10 min idle = still waiting, not dead
    retryPolicy:
      maxRetries: 40                 # worst case ~35 min > watchdog restart (~2-4 min) + model auto-load
      retryableCodes: [TIMEOUT, TRANSPORT]
```

And on the oMLX side (`~/.omlx/settings.json`): `sampling.max_context_window`, `prefill_memory_guard` (tier/ceiling), and `max_concurrent_requests: 1` for single-user agent workloads.

## Files installed by the script

| Path | Purpose |
|---:|---|
| `~/.omlx/watchdog.sh` | the health-check script (env-overridable, no hardcoded model names) |
| `~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist` | launchd agent, `StartInterval=60`, runs at login load |
| `~/.omlx/logs/watchdog.log` | check/recovery log (auto-rotated at 10 MB) |

## Requirements & safety notes

- macOS (Apple Silicon), oMLX installed, `~/.omlx/settings.json` present with an API key.
- The watchdog reads the oMLX **API key** from `settings.json` for authenticated health probes — it is never logged or transmitted anywhere else.
- No network egress except to `127.0.0.1`. No telemetry.
- The probe (Check C) consumes a few tokens per idle tick — negligible cost; it is skipped whenever real work is in flight.

## License

MIT (see [LICENSE](./LICENSE)).
