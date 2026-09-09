# omlx-watchdog

**ローカル [oMLX](https://github.com/jundot/omlx) 推論サーバーを常に生存させます。**

launchd ベースのヘルスウォッチドッグ。[oMLX](https://github.com/jundot/omlx)（Apple Silicon 向けローカル OpenAI 互換 LLM サーバー）用。wedged/停止したエンジンを自動検知・復旧——**誤った再起動ゼロ**。長時間エージェントセッション（DSH、OpenClaw…）がクラッシュ後も無人で生き残り続け、ウォッチドッグ自身が監視対象の障害を引き起こすこともありません。

**Apple M5 Max / 128 GB / macOS** で Qwen3.8-27B を自主コーディングエージェントに提供し、1週間以上実戦検証：手動介入ゼロ、全クラッシュが約 2–4 分で自己修復。

## なぜ必要か —— oMLX に実際にある問題

| # | 症状（実測） | 根本原因 | omlx-watchdog の解決策 |
|---:|---|---|---|
| 1 | リクエストは受理されるが **30分+ トークンなし**（Metal wedge） | GPU コマンドバッファのスタック；プロセスは「生きている」、ログも書き込み継続 | **Check C**：実物の completion probe（`max_tokens=4`）でエンジンが本当に*生成できる*ことを証明；**Check D**：処理中リクエストあり時にトークンカウンターが ≥900s 停止 = wedged |
| 2 | oMLX プロセスの無音死（メモリ圧力下 SIGKILL） | OOM / crash reporter がエンジンを kill、誰も再起動しない | **Check A**（`/api/status` 到達性）→ 60s tick 内で完全な復旧ラダー発動 |
| 3 | 再起動が永遠に失敗：*port in use*；「修正」でクライアント接続を誤 kill | 残存 listener がポート占有；`lsof -ti` 型クリーンアップは *client* ソケットもマッチし、起動直後のサーバーを kill | **PORT-CLEAN は LISTENER のみ kill**（`lsof -sTCP:LISTEN`）、30s 待機、`kill -9` にエスカレート；クライアントは絶対に触らない |
| 4 | モデル切替後の無限再起動ループ —— ウォッチドッグが古いモデル名で探査し続ける | モデルチェックが `default_model` 追従/ハードコード、oMLX が実際ロードしているのは別物 | **v6：モデル = `/api/status` → `loaded_models[0]`** —— oMLX が*実際にロード中*のモデルを追従；無しの場合はチェックスキップ、強制ロードしない |
| 5 | ウォッチドッグ自身が監視対象の障害を誘発（probe が処理中リクエストと衝突；tick 重複） | probe がキュー状態を見ずに発火；遅い Check C が次の tick にまたがる | probe は **`active+waiting == 0`**（キューが空と証明可能）のときのみ；PID lockfile で再入防止 |
| 6 | エージェント harness（DSH）のリトライが死ループ or 早期放棄 | リトライウィンドウと復旧時間の不一致 | harness 側有界リトライ（例：DSH `maxRetries=40`、最悪 ~35min）が 2–4 min の再起動 + モデル自動ロードをカバー；永続障害は明示的に失敗 |

## ワンクリックインストール（macOS、Apple Silicon）

```bash
curl -fsSL https://raw.githubusercontent.com/ricky8848/omlx-watchdog/main/scripts/install.sh | bash
```

| 変数 | デフォルト | 意味 |
|---:|---:|---|
| `OMLX_WATCHDOG_API` | `http://127.0.0.1:8000` | oMLX API 基盤 URL（PORT-CLEAN のポート解析用） |
| `OMLX_WATCHDOG_STALL` | `900` | 処理中リクエストあり時のトークンカウンター停止秒数（wedged 判定） |
| `OMLX_WATCHDOG_OMLX_HOME` | `$HOME/.omlx` | oMLX ホーム（`settings.json` 必須） |

**アンインストール：**

```bash
launchctl unload ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist
rm -f ~/Library/LaunchAgents/com.ricky8848.omlx-watchdog.plist ~/.omlx/watchdog.sh
```

## 仕組み —— チェック4種、60s 間隔

| Check | 方法 | 発火条件 | なぜ自己干渉しないか |
|---:|---|---|---|
| **A** 到達性 | `GET /api/status`（5s） | サーバーダウン、またはレスポンス不可解析 | 即座の読み取り専用呼び出し；決してキューに積まない |
| **B** モデル登録 | `GET /v1/models` でロード済み名 grep | 実際ロード中のモデルがレジストリにない（状態破損） | tick ごとに `loaded_models[0]` を読取——モデル切替安全；空 → スキップ、強制ロードしない |
| **C** アイドル completion probe | 実物 `POST /v1/chat/completions`、`max_tokens=4`（90s） | エンジンが受理するがトークンを生成しない（Metal wedge）——**`active+waiting == 0` のときのみ** | キューが空と証明可能 → 実作業と衝突しない；再起動後のモデルウォームアップ兼用 |
| **D** ストール検出器 | `total_prompt_tokens + total_completion_tokens` vs 前 tick | 処理中リクエストあり **かつ** カウンターが ≥ `STALL_SECONDS`（デフォルト 900s）凍結 | 処理中リクエストがある間のみ計時；カウンターリセット（外部再起動）は誤検知せずタイマー再アーム |

**復旧ラダー**（いずれかの check 失敗時）：`omlx restart --timeout 240` → **PORT-CLEAN**（listener のみ kill、30s グレース、`kill -9`）+ リトライ → 最終手段 `open -a oMLX`。その後 `/api/status` を最大4分ポーリング；`RECOVERED: oMLX up (loaded=<model>)` を記録。

## FAQ —— 画面が毎分一回震えます？

**通常 omlx-watchdog が原因ではありません。** ウォッチドッグ本体は HTTP GET/POST のみ（UI なし、ウィンドウ操作なし）。

毎分1回の震えの最も一般的な原因は**別の launchd agent が毎分 GUI App を `open -a` していること**。特定方法：

```bash
# 1. 60s 間隔の agent を一覧表示
ls ~/Library/LaunchAgents/*.plist | xargs -I{} sh -c 'echo "== {}"; plutil -p "{}" 2>/dev/null | grep StartInterval'

# 2. GUI App を繰り返し起動しているものを探す（本ケース：docker-watchdog.sh が毎分 open -a Docker）
grep -l "open -a" ~/Library/LaunchAgents/*.plist ~/.omlx/*watchdog*.sh 2>/dev/null
```

**本ケースの実録（2026-09）：** `com.ricky.docker-watchdog` が毎分 `open -a Docker` を実行。Docker Desktop の GUI（Electron）は毎回 `open -a` でウィンドウを再アクティベート → 画面が震える。修正：Docker daemon を修復、またはスクリプトに `pgrep -f "Docker Desktop" && exit 0` ガード追加。

## License

[MIT](../LICENSE) © ricky8848. oMLX とそのメンテナとは無関係；独立したコミュニティツール。
