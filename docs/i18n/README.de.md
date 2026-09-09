# omlx-watchdog

**Halte deinen lokalen [oMLX](https://github.com/jundot/omlx)-Inferenz-Server am Leben.**

Ein launchd-basierter Health-Watchdog für [oMLX](https://github.com/jundot/omlx) (lokaler OpenAI-kompatibler LLM-Server für Apple Silicon). Erkennt und repariert automatisch wedged/gestoppte Engines — **null falsche Neustarts** — damit lange Agent-Sessions (DSH, OpenClaw…) nach jedem Crash unbeaufsichtigt überleben.

Über eine Woche im Produktivbetrieb getestet auf **Apple M5 Max / 128 GB / macOS** mit Qwen3.8-27B für einen autonomen Coding-Agent: null manuelle Interventionen; jeder Crash heilte sich in ~2–4 Minuten selbst.

## Warum es existiert — die echten Probleme von oMLX

| # | Symptom (beobachtet) | Ursache | Lösung durch omlx-watchdog |
|---:|---|---|---|
| 1 | Anfrage akzeptiert, aber **30+ Min. ohne Tokens** (Metal wedge) | GPU-Command-Buffer hängt; Prozess „lebt" und schreibt weiter Logs | **Check C**: echte Completion-Probe (`max_tokens=4`), die beweist, dass die Engine *generieren* kann; **Check D**: Token-Zähler ≥900s eingefroren bei laufender Arbeit = wedged |
| 2 | oMLX-Prozess stirbt still (SIGKILL unter Speicherdruck) | OOM / Crash-Reporter tötet die Engine; niemand startet sie neu | **Check A** (Erreichbarkeit von `/api/status`) → komplette Recovery-Leiter innerhalb des 60s-Ticks |
| 3 | Neustart scheitert ewig: *Port in use*; das „Fixen" tötet Client-Verbindungen | Ein zurückgebliebener Listener hält den Port; `lsof -ti`-Style-Cleanup tötet auch *Client*-Sockets und damit den gerade gestarteten Server | **PORT-CLEAN tötet nur den LISTENER** (`lsof -sTCP:LISTEN`), wartet 30 s, eskaliert zu `kill -9`; Clients werden nie angefasst |
| 4 | Endlosschleife nach Modellwechsel — Watchdog soniert einen veralteten Namen weiter | Modell-Check folgte `default_model`/war hartkodiert, während oMLX ein anderes Modell geladen hatte | **v6: Modell = `/api/status` → `loaded_models[0]`** — folgt dem, was oMLX *tatsächlich geladen* hat; nichts geladen → Checks übersprungen, niemals Zwangs-Load |
| 5 | Der Watchdog löst die Störung aus, die er überwacht (Probe kollidiert mit laufender Arbeit; überlappende Ticks) | Probe feuerte ohne Blick auf die Queue; eine langsame Check C überschritt in den nächsten 60s-Tick | Probe **nur wenn `active+waiting == 0`** (nachweisbar leere Queue); PID-Lockfile gegen Re-Entrance |
| 6 | Agent-Harness (DSH) macht Retry-Schleifen oder gibt zu früh auf | Retry-Fenster nicht an die Recovery-Zeit dimensioniert | Begrenztes Retry im Harness (z. B. DSH `maxRetries=40`, ~35 Min. im Worst Case) deckt die 2–4 Min. Neustart + Modell-Autoload ab |

## Installation mit einem Klick (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| Variable | Standard | Bedeutung |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX-API-Basis-URL (Port wird hieraus für PORT-CLEAN geparst) |
| `OMLX_WATCHDOG_STALL` | `900` | Sekunden eingefrorener Token-Zähler (bei laufender Arbeit) bis wedged-Deklaration |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX-Home (muss `settings.json` enthalten) |

**Deinstallieren:**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## So funktioniert es — 4 Checks, alle 60 s

| Check | Methode | Löst aus wenn | Warum keine Selbst-Interferenz |
|---:|---|---|---|
| **A** Erreichbarkeit | `GET /api/status` (5 s) | Server down oder Antwort nicht parsbar | sofortiger Read-only-Call; landet nie in der Queue |
| **B** Modell registriert | `GET /v1/models`, grep des geladenen Namens | tatsächlich geladene Modell fehlt im Registry (korrupter Zustand) | liest `loaded_models[0]` jeden Tick — sicher bei Modellwechsel; leer → übersprungen, niemals Zwangs-Load |
| **C** Idle-Completion-Probe | echte `POST /v1/chat/completions`, `max_tokens=4` (90 s) | Engine akzeptiert, produziert aber keine Tokens (Metal wedge) — **nur wenn `active+waiting == 0`** | nachweisbar leere Queue → keine Kollision mit echter Arbeit; dient zugleich als Modell-Warmup nach Neustart |
| **D** Stall-Detektor | `total_prompt_tokens + total_completion_tokens` vs. vorheriger Tick | laufende Arbeit **und** Zähler ≥ `STALL_SECONDS` (Std. 900 s) eingefroren | armt den Timer nur bei laufender Arbeit; Zähler-Reset (externer Neustart) armt neu, ohne False Positive |

**Recovery-Leiter** (jeder Check schlägt fehl): `omlx restart --timeout 240` → **PORT-CLEAN** (nur Listener kill, 30 s Gnadenfrist, `kill -9`) + Retry → letzte Instanz `open -a oMLX`. Danach pollt es `/api/status` bis zu 4 Min.; loggt `RECOVERED: oMLX up (loaded=<model>)`.

## FAQ — Zittert der Bildschirm jede Minute?

**Meistens ist es NICHT omlx-watchdog.** Der Watchdog macht nur HTTP GET/POST (kein UI, keine Fenster-Manipulation).

Der häufigste Verursacher des Minutentritts ist **ein anderer launchd-Agent, der jede Minute `open -a` auf eine GUI-App ausführt**. So findest du ihn:

```bash
# 1. Liste der Agenten mit StartInterval=60
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. Suche, wer eine GUI-App neu startet (realer Fall: docker-watchdog.sh führt jede Minute open -a Docker aus)
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**Realer Fall (2026-09):** `com.ricky.docker-watchdog` führte jede Minute `open -a Docker` aus. Die GUI von Docker Desktop (Electron) aktiviert bei jedem `open -a` ihr Fenster neu → der Bildschirm zittert. Lösung: Docker-Daemon reparieren oder eine Wächterzeile `pgrep -f "Docker Desktop" && exit 0` hinzufügen.

## Lizenz

[MIT](../LICENSE) © ricky8848. Keine Affiliation mit oMLX oder seinen Maintainern; unabhängiges Community-Tool.
