# claw-hub

OCI Always Free（Ampere A1, 2 OCPU / 12GB）の 1 台に、OpenClaw を窓口とする 24 時間稼働の AI エージェント基盤を構築するための設定・スクリプト一式。
設計と、各構成要素の「公式確認済み / 検証済み / 仮説」の判定は [docs/spec-v0.2.md](docs/spec-v0.2.md) を参照。

対象: OpenClaw 2026.11.x / Ubuntu 24.04 aarch64 / Node 24（OpenClaw インストーラが導入）

## 構成要素

| パス | 役割 |
|---|---|
| `config/openclaw.patch.json5` | OpenClaw のハードニング済み設定パッチ（loopback + token + Tailscale Serve、Discord 許可リスト、main / reader の 2 エージェント、rootless Podman サンドボックス、フック） |
| `bridge/` | **claw-bridge**: クラウドAI（ChatGPT Work / Claude Cowork / Gemini Spark）が Drive に書いた成果物を検証・重複排除して reader エージェントへ渡す。5 分毎のタイマー起動、常駐しない |
| `runner/claw-run` | **claw-run**: Codex / Claude Code を別ユーザー・systemd 一時ユニット（資源・時間・書込先の制限つき）で必要な時だけ実行 |
| `backup/claw-backup` | `openclaw backup create --verify` + ブリッジ台帳 + `/etc/claw-hub` を age で暗号化して rclone で VM 外へ |
| `workspace/*/AGENTS.md` | エージェントの運用ルール（信頼境界・承認が必要な操作・振り分け・報告の仕方） |
| `systemd/` | ブリッジ / バックアップのユニットとタイマー |
| `bootstrap/` | 導入スクリプト（00 → 50 の順） |
| `checks/` | 設定のレンダリング、完了判定チェック、テスト一括実行 |

## 導入

### 0. 事前に用意するもの
- OCI アカウント（Always Free）、Tailscale アカウント、Discord Bot（Message Content Intent 有効）
- Discord の数値 ID: 自分のユーザー ID、サーバー ID、報告用チャンネル ID
- 手元 PC で作る age 鍵ペア（`age-keygen -o claw-backup.key`）。**秘密鍵は VM に置かない**

### 1. VM 作成
OCI コンソールで `VM.Standard.A1.Flex`、**2 OCPU / 12GB**、Ubuntu 24.04 (aarch64)、ブートボリューム 50〜100GB。
（2026 年の改定で Always Free の A1 は常時 2 OCPU / 12GB が上限。OpenClaw 公式手順の「4 OCPU / 24GB」は旧情報）

### 2. ホスト・Tailscale

```bash
git clone <this repo> ~/claw-hub && cd ~/claw-hub
```

```bash
sudo ./bootstrap/00-host.sh
```

```bash
sudo ./bootstrap/10-tailscale.sh
```

tailnet 経由で `ssh ubuntu@openclaw` できることを確認したら、OCI の VCN → Security List から **UDP 41641 以外の ingress をすべて削除**（SSH 22 も削除）。

### 3. OpenClaw

```bash
cp config/ids.env.example config/ids.env && nano config/ids.env
```

```bash
./bootstrap/20-openclaw.sh
```

```bash
openclaw models auth login --provider openai --device-code
```

Discord で bot に DM して返事が来ることを確認する。

### 4. 隔離ランナー（Codex / Claude Code）

```bash
INSTALL_CLIS=1 sudo -E ./bootstrap/30-runner.sh
```

```bash
sudo -u clawrun -H codex login --device-auth
```

```bash
echo 'pwd と whoami の結果だけ答えて' | sudo -n /usr/local/sbin/claw-run --agent codex --timeout 300
```

定型ジョブは `/etc/claw-hub/prompts/*.md`（root 管理）に置き、Automations のコマンドジョブとして**人間が**登録する（モデルからはコマンドジョブを作れない）:

```bash
openclaw automations create "0 3 * * *" --name nightly-tests --tz Asia/Tokyo --command "sudo -n /usr/local/sbin/claw-run --agent codex --repo myapp --prompt-file example-nightly.md" --announce --channel discord --to "channel:<報告用チャンネルID>"
```

`--repo myapp` は `/srv/claw/repos/myapp`（root が用意する読み取り用ミラー）から作業コピーを clone する。結果は `/srv/claw/jobs/<job>/result.json`。

### 5. 取り込みブリッジ

```bash
sudo rclone config --config /etc/claw-hub/secrets/rclone.conf
```
（名前 `gdrive`、type `drive`、scope **`drive.readonly`**）

```bash
sudo ./bootstrap/40-bridge.sh
```

各クラウド AI の定期タスクの指示文の最後に、次を付け足す:

> 結果を Google Drive の `claw-inbox` フォルダに、ファイル名 `gemini-spark__<タスク名>__<YYYY-MM-DD>.md` で保存してください。
> 参照した URL は本文の末尾に箇条書きで列挙してください。

（`source` 部分は `chatgpt-work` / `claude-cowork` / `gemini-spark`。JSON で書かせる場合の形式は `bridge/lib/envelope.mjs` の `claw-hub/result@1`）

### 6. バックアップ

```bash
sudo rclone config --config /etc/claw-hub/secrets/rclone-backup.conf
```
（名前 `gdrive-backup`、type `drive`、scope **`drive.file`**）

```bash
sudo AGE_RECIPIENT=age1xxxxxxxx ./bootstrap/50-backup.sh
```

### 7. 完了判定

```bash
./checks/acceptance.sh
```

VM の**外**から、公開 IP に何も開いていないことも確認する（例: `nmap -Pn -p- <公開IP>`）。

## 運用

| やりたいこと | コマンド |
|---|---|
| Gateway の状態 | `systemctl --user status openclaw-gateway.service` / `openclaw logs --follow` |
| 定期ジョブ一覧・履歴 | `openclaw automations list` / `openclaw automations runs <id>` |
| ブリッジの台帳 | `sudo claw-bridge status` |
| 失敗イベントの再試行 | `sudo claw-bridge retry <eventId>` |
| ブリッジを今すぐ実行 | `sudo systemctl start claw-bridge.service` |
| セキュリティ監査 | `openclaw security audit` |
| 更新 | `openclaw update` の後 `./checks/acceptance.sh` |

## 復旧（VM 喪失時）

1. 新しい VM で手順 1〜2、`20-openclaw.sh` の「OpenClaw install」まで（または `20-openclaw.sh` 全体）を実行し、Gateway を止める:
   ```bash
   systemctl --user stop openclaw-gateway.service
   ```
2. 手元 PC でバックアップを復号し、VM へ転送:
   ```bash
   age -d -i claw-backup.key claw-backup-openclaw-<日時>.tar.age | tar -xf - -C ./restore
   ```
3. VM 上で OpenClaw 公式手順で検証・展開:
   ```bash
   openclaw backup verify ./restore/openclaw/<archive>.tar.gz
   ```
   ```bash
   openclaw backup restore ./restore/openclaw/<archive>.tar.gz --target ~/restored-openclaw
   ```
   展開物を `~/.openclaw` に配置し（または `OPENCLAW_STATE_DIR` で指定）、`openclaw doctor` を実行。
4. **プラグインはバックアップに含まれない**ので再導入:
   ```bash
   openclaw plugins install @openclaw/discord --pin --force
   ```
5. `etc-claw-hub.tar.gz` を `/` に展開して `/etc/claw-hub` を戻し、`bridge.sqlite` を `/var/lib/claw-bridge/` に置く（所有者 `clawbridge`、0600）。
6. `30` / `40` / `50` の bootstrap を再実行し、`./checks/acceptance.sh`。

## 開発・テスト

```bash
./checks/test.sh
```

ブリッジ（Node の `node:test`）、claw-run（Python `unittest`）、shellcheck、`openclaw` があれば設定パッチのスキーマ検証（dry-run）を実行する。
