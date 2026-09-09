# omlx-watchdog

**Mantén vivo tu servidor de inferencia local [oMLX](https://github.com/jundot/omlx).**

Un watchdog de salud basado en launchd para [oMLX](https://github.com/jundot/omlx) (servidor LLM local compatible con OpenAI para Apple Silicon). Detecta y recupera automáticamente motores wedged/detenido — **cero reinicios falsos** — para que las sesiones de agentes a largo plazo (DSH, OpenClaw…) sobrevivan sin supervisión tras cualquier caída.

Probado en producción durante más de una semana en **Apple M5 Max / 128 GB / macOS** sirviendo Qwen3.8-27B a un agente de codificación autónomo: cero intervenciones manuales; cada caída se autorreparó en ~2–4 minutos.

## Por qué existe — los problemas reales de oMLX

| # | Síntoma (observado) | Causa raíz | Solución de omlx-watchdog |
|---:|---|---|---|
| 1 | Solicitud aceptada pero **sin tokens durante 30+ min** (Metal wedge) | GPU command buffer atascado; el proceso "vive" y sigue escribiendo logs | **Check C**: una completion probe real (`max_tokens=4`) que prueba que el motor puede *generar*; **Check D**: contador de tokens congelado ≥900s con trabajo en vuelo = wedged |
| 2 | Proceso oMLX muere en silencio (SIGKILL bajo presión de memoria) | OOM / crash reporter mata al motor; nadie lo reinicia | **Check A** (alcanzabilidad de `/api/status`) → escalera completa de recuperación dentro del tick de 60s |
| 3 | Reinicio falla para siempre: *port in use*; la "corrección" mata conexiones de clientes | Un listener residual ocupa el puerto; un cleanup tipo `lsof -ti` también mata *sockets de cliente*, matando al servidor recién iniciado | **PORT-CLEAN solo mata el LISTENER** (`lsof -sTCP:LISTEN`), espera 30s, escala a `kill -9`; los clientes nunca se tocan |
| 4 | Bucle infinito de reinicios tras cambiar modelo — el watchdog sigue sondeando un nombre obsoleto | El check de modelo seguía `default_model`/hardcodeado mientras oMLX cargaba otro | **v6: modelo = `/api/status` → `loaded_models[0]`** — sigue lo que oMLX *realmente tiene cargado*; nada cargado → checks omitidos, nunca fuerza carga |
| 5 | El watchdog provoca la falla que monitoriza (probe colisiona con trabajo en vuelo; ticks solapados) | El probe se disparaba sin mirar la cola; un Check C lento cruzaba al siguiente tick de 60s | El probe **solo cuando `active+waiting == 0`** (cola demostrablemente vacía); lockfile PID contra reentrada |
| 6 | El harness del agente (DSH) hace retry en bucle o rinde demasiado pronto | Ventana de reintentos no dimensionada al tiempo de recuperación | Reintento acotado en el harness (ej. DSH `maxRetries=40`, ~35 min en el peor caso) que cubre los 2–4 min de reinicio + carga automática del modelo |

## Instalación con un clic (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| Variable | Por defecto | Significado |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | URL base de la API oMLX (el puerto se parsea de aquí para PORT-CLEAN) |
| `OMLX_WATCHDOG_STALL` | `900` | Segundos de contador de tokens congelado (con trabajo en vuelo) antes de declarar wedged |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | Home de oMLX (debe contener `settings.json`) |

**Desinstalar:**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## Cómo funciona — 4 checks, cada 60s

| Check | Método | Se dispara cuando | Por qué no se auto-interfiere |
|---:|---|---|---|
| **A** alcanzabilidad | `GET /api/status` (5s) | servidor caído o respuesta no parseable | llamada de solo lectura instantánea; nunca encola trabajo |
| **B** modelo registrado | `GET /v1/models`, grep del nombre cargado | el modelo realmente cargado no está en el registro (estado corrupto) | lee `loaded_models[0]` cada tick — seguro con cambio de modelo; vacío → omitido, nunca fuerza carga |
| **C** probe idle de completion | `POST /v1/chat/completions` real, `max_tokens=4` (90s) | el motor acepta pero no produce tokens (Metal wedge) — **solo si `active+waiting == 0`** | cola demostrablemente vacía → no colisiona con trabajo real; también calienta el modelo tras reinicios |
| **D** detector de stall | `total_prompt_tokens + total_completion_tokens` vs tick anterior | trabajo en vuelo **y** contador congelado ≥ `STALL_SECONDS` (def. 900s) | solo arma el temporizador con trabajo en vuelo; reset del contador (reinicio externo) re-arma sin falso positivo |

**Escalera de recuperación** (cualquier check falla): `omlx restart --timeout 240` → **PORT-CLEAN** (solo kill del listener, gracia de 30s, `kill -9`) + reintento → último recurso `open -a oMLX`. Luego sondea `/api/status` hasta 4 min; registra `RECOVERED: oMLX up (loaded=<model>)`.

## FAQ — ¿La pantalla tiembla cada minuto?

**Normalmente NO es omlx-watchdog.** El watchdog solo hace HTTP GET/POST (sin UI, sin manipulación de ventanas).

El culpable más común del temblor cada minuto es **otro agente launchd que hace `open -a` de una app GUI cada 60s**. Cómo identificarlo:

```bash
# 1. Lista agentes con StartInterval=60
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. Busca cuál relanza una app GUI (caso real: docker-watchdog.sh hace open -a Docker cada minuto)
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**Caso real (2026-09):** `com.ricky.docker-watchdog` ejecutaba `open -a Docker` cada minuto. La GUI de Docker Desktop (Electron) reactiva su ventana con cada `open -a` → la pantalla tiembla. Solución: reparar el daemon de Docker o añadir una guardia `pgrep -f "Docker Desktop" && exit 0`.

## License

[MIT](../LICENSE) © ricky8848. Sin afiliación con oMLX ni sus mantenedores; herramienta comunitaria independiente.
