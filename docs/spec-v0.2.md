# OpenClaw を中心とするマルチAI常駐基盤 — 仕様書 v0.2（現行仕様反映版）

- 改訂日: 2026-11-23（v0.1: 2026-10-29）
- 対象バージョン: OpenClaw **2026.11.7**（npm `latest`。`extended-stable` は 2026.10.33）、Node **24.16+**
- 位置づけ: v0.1 の目的・要件はそのまま維持し、構成を「現在の OpenClaw / 各社サービスの仕様」に合わせて具体化したもの。
  実装は本リポジトリ（`claw-hub/`）。

判定の凡例（v0.1 §2.8 の判定ルールに従う）:
**公式** = 公式ドキュメントで確認 / **検証済** = このリポジトリ作成時に実物で確認（下記「検証環境」） /
**仮説** = 未確認 / **非対応** / **規約上不可**

> 検証環境: x86_64 コンテナ上で OpenClaw 2026.11.7 を Node 24.22.3 で実行。ARM64（OCI A1）実機と systemd・Tailscale・Podman は未検証。

---

## 1. v0.1 からの主な変更点

| # | v0.1 の前提 | 現行仕様（2026-11） | 影響 | 判定 |
|---|---|---|---|---|
| 1 | OCI A1 は 2 OCPU / 12GB 想定 | Always Free は **1,500 OCPU時間・9,000 GB時間/月 = 常時 2 OCPU / 12GB**（旧 3,000/18,000 から半減）。OpenClaw 公式の Oracle 手順は「最大 4 OCPU / 24GB」のままで**古い** | 2 OCPU / 12GB を上限として設計。超過分は課金/停止対象 | 公式（Oracle）/ OpenClaw 側の記述は旧情報 |
| 2 | ジョブキュー・状態管理を SQLite で自作 | OpenClaw 本体に **Automations**（旧 cron。実行履歴・失敗通知・リトライ/バックオフ・自動無効化）と **Workboard** プラグイン（SQLite、`triage…done` のカード状態）がある | 自作は「外部成果物の取り込み台帳」だけに縮小（§4） | 公式 |
| 3 | Discord は OpenClaw 標準 | Discord は**別インストールのチャンネルプラグイン** `@openclaw/discord`。未導入だと設定があっても配信先として使えない（`channel must be last` で 400） | ブートストラップで導入 | 検証済 |
| 4 | — | CLI は `openclaw automations …`（設定キーは `cron.*` のまま） | 手順書の表記を更新 | 公式 |
| 5 | 外部イベントはブリッジから投入 | Gateway の **Inbound webhooks**（`/hooks/agent`）。`Idempotency-Key` 対応、`waitForCompletion` で実行結果まで同期取得可。ただし**再生キャッシュはメモリのみ** | 二重実行防止の正本はブリッジ側 SQLite に置く | 公式 + 検証済 |
| 6 | 複数エージェントで既定担当を `default: true` | 現行は `agents.ownership: "explicit"` + `bindings` + `defaults.systemAgent`。`default: true` は旧形式で、既存設定に残るとスキーマ検証が失敗 | 設定を現行形式で記述 | 検証済 |
| 7 | Gemini 系 CLI を利用条件確認後に追加 | **Google は 2026-06-18 に個人向け Gemini CLI の「Google でログイン」を終了**。Antigravity OAuth を第三者ツールから使うことは規約で禁止。残る経路は AI Studio の API キー | Gemini CLI は API キー経路のみ・既定無効 | 公式 / OAuth 経路は**規約上不可** |
| 8 | ChatGPT Work / Cowork / Spark の扱いは未確定 | 3 つともクラウド側の**定期タスク**機能が正式提供。いずれも OpenClaw から起動・状態取得できる公開 API は確認できない | 方式 B（成果物連携）のみ採用。起動はユーザーがクラウド側で登録 | 公式（機能の存在）/ API は**非対応** |
| 9 | Docker Sandbox | Docker の他に **rootless Podman** バックエンドが本体内蔵 | Gateway ユーザーに root 相当の Docker ソケットを持たせない構成にできる | 公式 |
| 10 | 管理 UI は Tailscale Serve | 変わらず。Serve 利用時の Tailscale ID ヘッダ認証（トークン省略）は「同一ホストで非信頼コードを動かさない」前提 | `gateway.auth.allowTailscale: false` で常にトークン必須 | 公式 |
| 11 | バックアップは自前 | `openclaw backup create --verify` / `verify` / `restore` が公式提供（DB スナップショット整合性検査つき）。**プラグインの node_modules は含まれない** | 公式バックアップ + age 暗号化 + rclone で VM 外へ。復旧時はプラグイン再導入 | 公式 + 検証済 |

---

## 2. 構成（v0.2）

```
[オーナー: Discord（許可リスト1名）/ スマホ / PC]
        │ DM / 指定チャンネル（mention 必須）
        ▼
┌──────────── OCI A1 (2 OCPU / 12GB, Ubuntu 24.04 aarch64) ─────────────┐
│ Tailscale (UDP 41641 のみ受信) ── Serve ──► Control UI (tailnet のみ)   │
│                                                                        │
│  OpenClaw Gateway  [user systemd, loopback:18789, token 認証]           │
│   ├─ agent "main"   … Discord 窓口。rootless Podman サンドボックス内で実行 │
│   ├─ agent "reader" … 外部データ専用。ツールほぼ無し。フック経由のみ       │
│   ├─ Automations（定期・単発。失敗通知→Discord）                         │
│   ├─ Workboard（長い依頼のカード管理, SQLite）                            │
│   └─ /hooks/agent（専用トークン。reader 宛てのみ許可）                    │
│        ▲                                                               │
│        │ Idempotency-Key / waitForCompletion                           │
│  claw-bridge  [system timer 5分毎, user=clawbridge, 常駐しない]          │
│   ├─ rclone（drive.readonly）で Drive「claw-inbox」→ ローカル受信箱       │
│   ├─ スキーマ検証・許可 source・サイズ上限・重複排除（SQLite 台帳）        │
│   └─ 根拠 URL の HTTP ステータス独立確認（SSRF 対策つき）                  │
│                                                                        │
│  claw-run  [sudo で起動できるのはこれだけ / user=clawrun]                 │
│   └─ systemd-run 一時ユニット: Codex / Claude Code を                    │
│      ProtectSystem=strict・MemoryMax・CPUQuota・RuntimeMaxSec で実行      │
│                                                                        │
│  claw-backup [system timer 毎日] openclaw backup → age 暗号化 → rclone   │
└────────────────────────────────────────────────────────────────────────┘
        ▲ ファイル（JSON / Markdown）を書くだけ。起動・状態取得の API は無い
┌───────┴──────────────── 各社クラウド（ユーザーが定期タスクを登録）────────┐
│ ChatGPT Work Scheduled Tasks / Claude Cowork（クラウド実行）/ Gemini Spark │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.1 処理の振り分け（v0.1 §2.3 改訂）

| 処理 | 第一候補 | フォールバック | 判定 |
|---|---|---|---|
| 受付・通知・タスク管理 | OpenClaw（Discord プラグイン + Workboard） | — | 検証済（設定・フック）/ Discord 実接続は未検証 |
| 定期 Web 調査・変更監視 | クラウド側定期タスク（Spark / ChatGPT Work / Cowork）→ Drive → ブリッジ | Automations（isolated エージェントターン） | 機能は公式 / Drive 出力の安定性は**仮説** |
| 単純ポーリング・差分検知 | Automations（エージェントターン）または軽量スクリプト | — | 公式 |
| GUI ブラウザ操作 | クラウド側機能（ChatGPT Work 等） | VM 上 Chromium は**採用しない**（2 OCPU/12GB で Gateway ~2GB と同居させない） | 方針 |
| コーディング | `claw-run`（Codex / Claude Code、隔離・時間制限つき） | OpenClaw ネイティブ Codex（`/codex bind`）/ ACP — **ホスト上で Gateway ユーザー権限で動く**ことを許容する場合のみ | 公式 + claw-run は単体テスト済・systemd 実行は未検証 |
| 結果確認 | ブリッジの独立検証（HTTP ステータス）・claw-run の終了コード/差分 | — | 検証済（単体） |

---

## 3. 各 AI の利用経路と規約（v0.1 §1.4「認証流用をしない」の具体化）

| 経路 | 使い方 | 課金 | 判定 / 根拠 |
|---|---|---|---|
| OpenAI（窓口エージェントのモデル） | `openclaw models auth login --provider openai --device-code`（ChatGPT/Codex サブスクの OAuth） | サブスク枠 | 公式（OpenClaw ドキュメント「OpenAI explicitly supports subscription OAuth usage in external tools and workflows like OpenClaw」） |
| Codex CLI（claw-run） | `clawrun` ユーザーで `codex login --device-auth` | サブスク枠 | 公式（同上）。フラグは CLI 版で変わるため `runner.json` で上書き可 |
| Claude Code（claw-run） | `clawrun` ユーザーで `/login` または `claude setup-token` | サブスク枠（`claude -p` / Agent SDK はサインイン中プランの上限から消費） | 公式（OpenClaw Anthropic ページが Anthropic のサポート記事を引用）。共有・本番用途は API キー推奨とされる点に注意 |
| Claude を OpenClaw のモデルとして使う | `claude-cli/*` ルート（同一ホストの Claude Code ログインを再利用） | サブスク枠 | 公式。ただし Claude Code は Gateway ユーザー側に入る＝claw-run の分離が崩れるため**本構成では不採用** |
| Gemini API（窓口エージェントのサブ LLM） | `agents.defaults.model.fallbacks` に `google/…`、キーは `GEMINI_API_KEY`。GPT が上限・障害の時だけ使われる | 無料枠（課金を有効にしない）。無料枠の入力は製品改善に使われうる | 公式（OpenClaw model failover / Google provider）。サーバから弾かれる件は `checks/gemini-diag.sh` で切り分け |
| Gemini CLI | AI Studio の API キー（課金未設定のキー＝無料枠）。`runner.json` で `gemini.enabled=true` | 無料枠（課金を有効にしない） | 公式。個人向け Google ログインは 2026-06-18 終了、Antigravity OAuth は**規約上不可** |
| ChatGPT Work / Claude Cowork / Gemini Spark | 各サービスの UI で定期タスクを登録し、結果を Drive `claw-inbox` へ | 各サブスク | 機能は公式。OpenClaw からの起動 API は**非対応**。Drive への書き出しは**仮説**（§7） |

---

## 4. 要件と実装の対応

| 要件 | 実装 | 状態 |
|---|---|---|
| F-01 常駐受付 | Discord プラグイン、`dmPolicy: allowlist` + ギルド/チャンネル許可リスト、`requireMention` | 設定はスキーマ検証済 |
| F-02 定期・イベント起動 | Automations（cron 式 / 単発 / コマンドジョブ）、ブリッジ（Drive 更新契機・5分毎） | 公式機能 + ブリッジは結合テスト済 |
| F-03 複数AI | §3 の経路。claw-run の `agents` で切替 | 単体テスト済 |
| F-04 クラウド優先 | 振り分け表 §2.1。VM 上ブラウザ不使用 | 方針 |
| F-05 必要時のみローカル実行 | claw-run（`systemd-run --collect`、同時 1 本、`RuntimeMaxSec`）、ブリッジ・バックアップは oneshot タイマー | 引数生成は単体テスト済 / systemd 実行は未検証 |
| F-06 状態管理 | OpenClaw: Automations 実行履歴・Workboard。ブリッジ: `RECEIVED→VALIDATED→SENT→COMPLETED / RETRY_PENDING / FAILED / REJECTED` を SQLite に保持（監査ログ付き） | 再起動跨ぎを単体テストで確認 |
| F-07 検証 | ブリッジ: 根拠 URL の HTTP ステータス確認（本文は取らない・内部アドレス拒否）。claw-run: 終了コード・タイムアウト・変更ファイルを `result.json` に記録。reader への指示で「自己申告と事実の区別」 | 単体テスト済 |
| F-08 復旧 | `openclaw backup create --verify` + ブリッジ台帳 + `/etc/claw-hub` → age（公開鍵のみ VM に置く）→ rclone → 転送後サイズ照合 | 作成→暗号化→復号→verify→restore の往復を検証済（rclone はシムで代替） |

### 4.1 二重実行の防止（v0.1 §2.6）
- ブリッジ: `(source, task, run_id)` を自然キー、内容ハッシュで改訂を判別。同一内容の別名ファイルは重複として捨てる。
  `Idempotency-Key = claw-bridge:<eventId>` で送信。Gateway 側の再生キャッシュはメモリのみなので、
  **Gateway 再起動と送信中断が重なった場合だけ** reader の要約が 2 回届く可能性がある（reader は通知以外の副作用を持たないため許容）。
- claw-run: ジョブ ID は使い捨て（既存ディレクトリがあれば拒否）、`flock` で同時 1 本。
- Automations: Gateway の実行履歴・バックオフ・連続失敗時の自動無効化に任せる。

---

## 5. セキュリティ境界（v0.1 §2.5 改訂）

### 5.1 管理プレーン
- OCI VCN の ingress は **UDP 41641（Tailscale）のみ**。SSH(22) も閉じ、Tailscale SSH を使う。
- Gateway は `bind: loopback`、`auth.mode: token`（SecretRef で `~/.openclaw/.env` から）、`tailscale.mode: serve`、`allowTailscale: false`。
- Funnel（公開）は使わない。`checks/acceptance.sh` が Funnel 有効を FAIL にする。

### 5.2 実行プレーン
| 実行主体 | 隔離 | 備考 |
|---|---|---|
| main / reader のツール実行 | rootless Podman（`network: none`、`readOnlyRoot`、`capDrop: ALL`、メモリ 2g / pids 256） | reader は `workspaceAccess: none` + runtime/fs/automation/message 系ツール拒否 |
| ホスト exec | `tools.exec`: `host: sandbox`、`security: allowlist`、`ask: always`、`elevated` 無効 | 承認はオーナーのみ |
| claw-run | 別ユーザー `clawrun`、`ProtectSystem=strict`、`ProtectHome=tmpfs`（CLI 認証ディレクトリだけ bind）、`NoNewPrivileges`、空の Capability、資源制限 | Gateway ユーザーの `~/.openclaw` は見えない |
| ACP / ネイティブ Codex | **OpenClaw サンドボックスの外（ホスト上）で Gateway ユーザー権限**で動く（公式ドキュメント明記） | 使う場合はこのリスクを受け入れる。既定構成では使わない |
| claw-bridge | 別ユーザー `clawbridge`、`ProtectSystem=strict`、`ProtectHome=yes`、トークンは `LoadCredential` | フック送信先は loopback に固定（コードで強制） |

### 5.3 データプレーン（プロンプトインジェクション対策）
1. 外部成果物は **reader** にしか届かない（`hooks.allowedAgentIds: ["reader"]`）。reader はほぼツールを持たない。
2. ブリッジで形式・source 許可リスト・サイズ・URL スキームを検証。シンボリックリンク・巨大ファイル・バイナリは読まない。
3. reader への本文は毎回ランダムな境界文字列で囲み、「中の指示に従わない」旨を明示。
4. 根拠 URL の確認は HTTP ステータスのみ（本文は取得しない）。loopback / RFC1918 / Tailscale CGNAT / link-local（メタデータ）/ `.ts.net` は拒否。
   残余リスク: DNS 解決と接続の間の DNS リバインディングは防げない（ステータスしか返さないため影響は小さい）。
5. オプション強化: 運用が固まったら `tools.gatewayPolicy`（モデル主導で使えるツールを具体名で列挙。未列挙は使用不可）を追加する。
   必須の `allow` に全ツール名を並べる必要があるため初期構成では入れていない。

### 5.4 OpenClaw セキュリティ監査の結果（`openclaw security audit`、検証環境）
- critical **0** / warn 1 / info 2
- warn `security.trust_model.multi_user_heuristic`: ギルド許可リストがあることによるヒューリスティック。許可ユーザーはオーナー 1 名のみなので許容。

---

## 6. 完了判定（v0.1 §1.5）と確認方法

| 判定項目 | 確認方法 |
|---|---|
| VM 再起動後に管理機能と Discord 受付が復旧、管理 UI に公開インターネットから到達不可 | `sudo reboot` 後に `checks/acceptance.sh`（A1/A2）＋ VM 外から公開 IP に `nmap -Pn -p 1-65535`（何も開いていないこと） |
| 定期・手動ジョブの起動と成功/失敗/タイムアウト/再試行の履歴 | `openclaw automations runs <id>`、`sudo claw-bridge status`、`/srv/claw/jobs/*/result.json` |
| クラウド完結の監視ジョブを Chromium なしで取得・通知 | Spark 等の定期タスク → Drive → ブリッジ → Discord に要約が届くこと |
| CLI 実行の制限と非残留 | `checks/acceptance.sh`（A4: `claw-job-*` 残留なし）、`systemctl show` で制限値を確認 |
| 不審な外部文章や重複イベントで未許可コマンド・二重投稿が起きない | `bridge/test` のインジェクション・重複テスト ＋ 実機で同じファイルを 2 回置く |
| VM 喪失を想定した復旧 | README「復旧」の手順を新しい VM で 1 回通す |
| 無料枠内で運用・各 AI の利用条件と課金経路 | OCI コンソールの Cost Analysis が 0 円、§3 の表を各社の最新ページで再確認 |

---

## 7. 未検証事項（次に実機で確認すべきこと）

| 項目 | 確認方法 | 判定 |
|---|---|---|
| ARM64 上の OpenClaw / Discord プラグイン / Podman 動作 | `bootstrap/*.sh` を A1 で実行 | 仮説（OpenClaw の Oracle 手順では動作する前提） |
| Ubuntu 24.04 の AppArmor 下で rootless Podman が動くか | `podman run --rm debian:trixie-slim true` | 仮説。不可なら `sandbox.backend: "docker"`（docker グループ＝root 相当である点を受容） |
| Codex 内部サンドボックス（`--sandbox workspace-write`）が systemd の制限下で動くか | `claw-run` のスモークテスト | 仮説。不可なら `runner.json` で `--sandbox danger-full-access`（外側の systemd 隔離に任せる） |
| 各クラウド定期タスクが Drive の指定フォルダへ指定名で書けるか | 1 サービスずつ 1 タスク試す | 仮説 |
| Gateway の常駐メモリ（ARM64） | `checks/acceptance.sh` A7 | 検証環境(x86_64)では起動直後 約2.0–2.2GB、アイドル 約1.7GB |
| OCI の A1 空き容量・回収ポリシー（アイドル判定） | コンソール / 規約 | 仮説 |

---

## 8. 代替構成についての所見（v0.1 §2.8「より良い構成」）

- **OpenClaw を使わない軽量構成**: 要件が「定期取得 → Discord 通知」だけなら、ブリッジ + Discord Webhook で常駐メモリは数十MBで済む。
  OpenClaw を使う価値は「会話での受付・承認・Workboard・Automations の会話管理」にある。12GB に対し Gateway ~2GB は許容範囲と判断。
- **2 台構成**: Always Free の A1 は合計 2 OCPU / 12GB なので分割しても総量は増えない。分離の利点（ブリッジやランナーを別 VM）はあるが、
  Tailscale 越しのフック通信と運用が増える。まず 1 台で始め、claw-run の負荷が Gateway の応答性を落とす場合に再検討。

---

## 9. 参考一次資料

- Oracle Always Free（A1 の上限）: https://docs.oracle.com/iaas/Content/FreeTier/resourceref.htm
- 同 変更報道: https://infoq.com/news/2026/07/oracle-cloud-free-tier-limits/
- OpenClaw（同梱ドキュメント 2026.11.7。オンライン版 https://docs.openclaw.ai/）
  - Oracle: `/install/oracle` / Tailscale: `/gateway/tailscale` / Hardened baseline: `/gateway/security/hardened-baseline`
  - Inbound webhooks: `/automation/cron-jobs/webhooks`、フック設定: `/gateway/config-hooks`
  - ACP サンドボックス境界: `/tools/acp-agents/delivery#sandbox-compatibility`
  - Podman バックエンド: `/gateway/sandboxing/podman-backend`
  - バックアップ: `/cli/backup`、Workboard: `/cli/workboard`、マルチエージェント: `/concepts/multi-agent`
  - プロバイダ: `/providers/openai`、`/providers/anthropic`、`/providers/google`
- Gemini Spark: https://support.google.com/gemini/answer/17094507 / スケジュール: https://support.google.com/gemini/answer/17094710 /
  日本の Pro ユーザーへの拡大: https://blog.google/intl/ja-jp/company-news/technology/gemini-spark-comes-to-japan/
- Claude Cowork 定期タスク: https://support.claude.com/en/articles/13854387 / クラウド実行: https://support.claude.com/en/articles/15811196
- ChatGPT Work / Scheduled tasks: https://openai.com/index/chatgpt-for-your-most-ambitious-work/ / https://help.openai.com/en/articles/10291617
- Gemini CLI 個人向けログイン終了: https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals
