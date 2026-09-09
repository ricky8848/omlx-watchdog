# Security Policy

## Supported Versions

| Version | Supported |
|:-:|:-:|
| v6.1.x (main) | ✅ Yes |
| ≤ v5 | ❌ Legacy — upgrade via `install.sh` (backs up old script as `.bak.TIMESTAMP`) |

## Reporting a Vulnerability

**Please do NOT open public issues for security vulnerabilities.**

Report via GitHub private vulnerability reporting:
[Report a vulnerability →](https://github.com/ricky8848/omlx-watchdog/security/advisories/new)

Or email: ricky8848 (GitHub DM — Settings → Notifications → contact preference).

### What we consider security-relevant
- Any path that could execute arbitrary code on the host (the watchdog runs as your user via launchd)
- Log/credential leakage: `~/.omlx/logs/watchdog.log` must never contain the oMLX API key (the script reads it from `~/.omlx/settings.json` at runtime and never writes it)
- Install-time behavior of `scripts/install.sh` (it must be idempotent and back up existing state)

### What we do NOT consider vulnerabilities
- oMLX server-side issues (report to [jundot/omlx](https://github.com/jundot/omlx/issues))
- The watchdog restarting oMLX (that is its job)

## Security-relevant design notes
- **No network exfiltration**: the watchdog only talks to `127.0.0.1:8000` (oMLX) and writes to `~/.omlx/logs/`. No telemetry, no phone-home.
- **No privileged operations**: runs as your user; `kill`/`kill -9` targets only the PID listening on port 8000 (verified via `lsof -sTCP:LISTEN`), never system processes.
- **API key handling**: read from `~/.omlx/settings.json` at runtime; never logged, never committed (`.gitignore` + install.sh never touches it).
