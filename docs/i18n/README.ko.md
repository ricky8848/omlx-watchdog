# omlx-watchdog

**로컬 [oMLX](https://github.com/jundot/omlx) 추론 서버를 항상 살아있게 유지합니다.**

launchd 기반 헬스 워치독. [oMLX](https://github.com/jundot/omlx)（Apple Silicon용 로컬 OpenAI 호환 LLM 서버）를 위한 것입니다. wedged/정지된 엔진을 자동 감지·복구하며 **잘못된 재시작은 0**입니다. 장시간 에이전트 세션(DSH, OpenClaw…)이 크래시 후에도 무인 상태로 살아남고, 워치독自身が 감시 대상 장애를 일으키는 일도 없습니다.

**Apple M5 Max / 128 GB / macOS**에서 Qwen3.8-27B를 자율 코딩 에이전트에 제공하며 1주 이상 실전 검증: 수동 개입 0, 모든 크래시가 약 2–4분 내 자가 복구.

## 왜 필요한가 — oMLX에 실제로 존재하는 문제

| # | 증상(실측) | 근본 원인 | omlx-watchdog 해결책 |
|---:|---|---|---|
| 1 | 요청은 수락되는데 **30분+ 토큰 없음**(Metal wedge) | GPU 커맨드 버퍼 스태킹; 프로세스는 "살아있고" 로그도 계속 기록 | **Check C**: 실물 completion probe(`max_tokens=4`)로 엔진이 실제로 *생성*할 수 있음을 증명; **Check D**: 진행 중 요청이 있을 때 토큰 카운터 ≥900초 정지 = wedged |
| 2 | oMLX 프로세스 무음 사망(메모리 압력 하 SIGKILL) | OOM / crash reporter가 엔진을 kill, 아무도 재시작 안 함 | **Check A**(`/api/status` 도달성) → 60초 tick 내 완전한 복구 래더 발동 |
| 3 | 재시작이 영원히 실패: *port in use*; "수정" 시 클라이언트 연결을 오-kill | 잔존 listener가 포트 점유; `lsof -ti`형 클리닝은 *client* 소켓도 매칭하여 방금 시작한 서버를 kill | **PORT-CLEAN은 LISTENER만 kill**(`lsof -sTCP:LISTEN`), 30초 대기, `kill -9`로 에스컬레이션; 클라이언트는 절대 건드리지 않음 |
| 4 | 모델 전환 후 무한 재시작 루프 — 워치독이 오래된 모델명으로 계속 탐사 | 모델 체크가 `default_model` 추종/하드코딩, oMLX는 실제로 다른 모델을 로드 중 | **v6: 모델 = `/api/status` → `loaded_models[0]`** — oMLX가 *실제로 로드한* 모델을 추종; 없으면 체크 스킵, 강제 로드하지 않음 |
| 5 | 워치독이 자신이 감시하는 장애를 스스로 유발(probe가 진행 중 요청과 충돌; tick 중복) | probe가 큐 상태를 보지 않고 발화; 느린 Check C가 다음 tick으로 넘어감 | probe는 **`active+waiting == 0`**(큐가 비어 있음을 증명 가능)일 때만; PID lockfile으로 재진입 방지 |
| 6 | 에이전트 harness(DSH)의 리トライ가 죽음 루프 or 조기 포기 | 재시도 윈도우와 복구 시간 불일치 | harness 측 유계 리트라이(예: DSH `maxRetries=40`, 최악 ~35분)가 2–4분 재시작 + 모델 자동 로드를 커버; 영구 장애는 명시적 실패 |

## 원클릭 설치 (macOS, Apple Silicon)

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| 변수 | 기본값 | 의미 |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX API 베이스 URL (PORT-CLEAN 포트 파싱용) |
| `OMLX_WATCHDOG_STALL` | `900` | 진행 중 요청이 있을 때 토큰 카운터 정지 초 (wedged 판정) |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX 홈 (`settings.json` 필수) |

**제거:**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## 동작 원리 — 체크 4종, 60초 간격

| Check | 방법 | 발화 조건 | 왜 자기 방해가 아닌가 |
|---:|---|---|---|
| **A** 도달성 | `GET /api/status` (5초) | 서버 다운 또는 응답 파싱 불가 | 즉각적인 읽기 전용 호출; 절대 큐에 넣지 않음 |
| **B** 모델 등록 | `GET /v1/models` 로드된 이름 grep | 실제로 로드된 모델이 레지스트리에 없음(상태 손상) | tick마다 `loaded_models[0]` 읽기 — 모델 전환 안전; 빈 경우 스킵, 강제 로드하지 않음 |
| **C** 유휴 completion probe | 실물 `POST /v1/chat/completions`, `max_tokens=4` (90초) | 엔진이 수락하지만 토큰을 생성하지 않음(Metal wedge) — **`active+waiting == 0`일 때만** | 큐가 비어 있음을 증명 가능 → 실제 작업과 충돌 없음; 재시작 후 모델 워밍업 겸용 |
| **D** 스톨 감지기 | `total_prompt_tokens + total_completion_tokens` vs 이전 tick | 진행 중 요청 **있고** 카운터가 ≥ `STALL_SECONDS`(기본 900초) 동결 | 작업 진행 중일 때만 타이밍; 카운터 리셋(외부 재시작)은 오동작 대신 타이머 재장전 |

**복구 래더**(어떤 check든 실패 시): `omlx restart --timeout 240` → **PORT-CLEAN**(listener만 kill, 30초 그레인, `kill -9`) + 재시도 → 마지막 수단 `open -a oMLX`. 그 후 `/api/status`를 최대 4분 폴링; `RECOVERED: oMLX up (loaded=<model>)` 기록.

## FAQ — 화면이 매 분마다 한 번 흔들립니다?

**보통 omlx-watchdog 때문이 아닙니다.** 워치독 본체는 HTTP GET/POST만 수행(UI 없음, 윈도우 조작 없음).

매 분 1회 흔들림의 가장 흔한 원인은 **다른 launchd agent가 매 분마다 GUI 앱을 `open -a`로 실행하는 것**입니다. 특정 방법:

```bash
# 1. 60초 간격의 agent 목록 표시
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. GUI 앱을 반복 시작하는 것 찾기 (본 사례: docker-watchdog.sh가 매 분마다 open -a Docker)
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**본 사례 실록 (2026-09):** `com.ricky.docker-watchdog`가 매 분마다 `open -a Docker` 실행. Docker Desktop GUI(Electron)는 매번 `open -a`로 창을 재활성화 → 화면이 흔들림. 수정: Docker daemon 복구 또는 스크립트에 `pgrep -f "Docker Desktop" && exit 0` 가드 추가.

## License

[MIT](../LICENSE) © ricky8848. oMLX 및 그 유지보수자와 무관; 독립적인 커뮤니티 도구입니다.
