# omlx-watchdog

**Gardez votre serveur d'inférence local [oMLX](https://github.com/jundot/omlx) en vie.**

Un watchdog de santé basé sur launchd pour [oMLX](https://github.com/jundot/omlx) (serveur LLM local compatible OpenAI pour Apple Silicon). Détecte et répare automatiquement les moteurs wedged/arrêtés — **zéro faux redémarrage** — pour que vos sessions d'agents de longue durée (DSH, OpenClaw…) survivent sans supervision après toute panne.

Testé en production plus d'une semaine sur **Apple M5 Max / 128 GB / macOS** servant Qwen3.8-27B à un agent de codage autonome : zéro intervention manuelle ; chaque panne s'est auto-réparée en ~2–4 minutes.

## Pourquoi ça existe — les vrais problèmes d'oMLX

| # | Symptôme (observé) | Cause racine | Solution omlx-watchdog |
|---:|---|---|---|
| 1 | Requête acceptée mais **aucun token pendant 30+ min** (Metal wedge) | GPU command buffer bloqué ; le processus « vit » et continue d'écrire des logs | **Check C** : une completion probe réelle (`max_tokens=4`) qui prouve que le moteur peut *générer* ; **Check D** : compteur de tokens gelé ≥900s avec du travail en vol = wedged |
| 2 | Processus oMLX meurt silencieusement (SIGKILL sous pression mémoire) | OOM / crash reporter tue le moteur ; personne ne le redémarre | **Check A** (atteignabilité de `/api/status`) → échelle complète de récupération dans le tick de 60s |
| 3 | Redémarrage qui échoue éternellement : *port in use* ; la « correction » tue les connexions clients | Un listener résiduel occupe le port ; un cleanup type `lsof -ti` tue aussi les *sockets clients*, tuant le serveur fraîchement démarré | **PORT-CLEAN ne tue que le LISTENER** (`lsof -sTCP:LISTEN`), attend 30s, escalade en `kill -9` ; les clients ne sont jamais touchés |
| 4 | Boucle de redémarrage infinie après changement de modèle — le watchdog sonde un nom obsolète | Le check de modèle suivait `default_model`/était codé en dur alors qu'oMLX chargeait un autre modèle | **v6 : modèle = `/api/status` → `loaded_models[0]`** — suit ce qu'oMLX a *réellement chargé* ; rien de chargé → checks sautés, jamais de chargement forcé |
| 5 | Le watchdog provoque la panne qu'il surveille (probe qui entre en collision avec le travail en vol ; ticks qui se chevauchent) | La probe se déclenchait sans regarder la file ; un Check C lent débordait sur le tick suivant | La probe **uniquement si `active+waiting == 0`** (file démontrablement vide) ; lockfile PID contre la ré-entrée |
| 6 | Le harness agent (DSH) fait des retries en boucle ou abandonne trop tôt | Fenêtre de retry non dimensionnée au temps de récupération | Retry borné côté harness (ex. DSH `maxRetries=40`, ~35 min au pire) couvrant les 2–4 min de redémarrage + chargement auto du modèle |

## Installation en un clic (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| Variable | Défaut | Signification |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | URL de base de l'API oMLX (le port est parsé d'ici pour PORT-CLEAN) |
| `OMLX_WATCHDOG_STALL` | `900` | Secondes de compteur de tokens gelé (avec travail en vol) avant de déclarer wedged |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | Home d'oMLX (doit contenir `settings.json`) |

**Désinstaller :**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## Comment ça marche — 4 checks, toutes les 60s

| Check | Méthode | Se déclenche quand | Pourquoi pas d'auto-interférence |
|---:|---|---|---|
| **A** atteignabilité | `GET /api/status` (5s) | serveur down ou réponse non parseable | appel lecture seule instantané ; n'entre jamais dans la file |
| **B** modèle enregistré | `GET /v1/models`, grep du nom chargé | le modèle réellement chargé n'est pas dans le registre (état corrompu) | lit `loaded_models[0]` à chaque tick — sûr avec changement de modèle ; vide → sauté, jamais de chargement forcé |
| **C** probe idle de completion | `POST /v1/chat/completions` réel, `max_tokens=4` (90s) | le moteur accepte mais ne produit pas de tokens (Metal wedge) — **uniquement si `active+waiting == 0`** | file démontrablement vide → pas de collision avec le travail réel ; sert aussi à préchauffer le modèle après redémarrage |
| **D** détecteur de stall | `total_prompt_tokens + total_completion_tokens` vs tick précédent | travail en vol **et** compteur gelé ≥ `STALL_SECONDS` (déf. 900s) | n'arme le minuteur que si du travail est en vol ; reset des compteurs (redémarrage externe) ré-arme sans faux positif |

**Échelle de récupération** (tout check en échec) : `omlx restart --timeout 240` → **PORT-CLEAN** (kill du listener uniquement, grâce de 30s, `kill -9`) + nouvelle tentative → dernier recours `open -a oMLX`. Puis sonde `/api/status` jusqu'à 4 min ; enregistre `RECOVERED: oMLX up (loaded=<model>)`.

## FAQ — L'écran tremble-t-il chaque minute ?

**Normalement ce n'est PAS omlx-watchdog.** Le watchdog ne fait que des HTTP GET/POST (pas d'UI, pas de manipulation de fenêtres).

Le coupable le plus fréquent du tremblement chaque minute est **un autre agent launchd qui fait `open -a` d'une app GUI toutes les 60s**. Comment l'identifier :

```bash
# 1. Liste des agents avec StartInterval=60
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. Cherche qui relance une app GUI (cas réel : docker-watchdog.sh fait open -a Docker chaque minute)
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**Cas réel (2026-09) :** `com.ricky.docker-watchdog` exécutait `open -a Docker` chaque minute. La GUI de Docker Desktop (Electron) réactive sa fenêtre à chaque `open -a` → l'écran tremble. Solution : réparer le daemon Docker ou ajouter une garde `pgrep -f "Docker Desktop" && exit 0`.

## License

[MIT](../LICENSE) © ricky8848. Sans affiliation avec oMLX ni ses mainteneurs ; outil communautaire indépendant.
