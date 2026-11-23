#!/usr/bin/env bash
# claw-run（隔離 CLI ランナー）の導入。root で実行する。
#   sudo ./bootstrap/30-runner.sh
#   INSTALL_CLIS=1 sudo -E ./bootstrap/30-runner.sh   # Codex / Claude Code も npm で /usr/local に入れる
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY_USER="${GATEWAY_USER:-ubuntu}"
RUN_USER="${RUN_USER:-clawrun}"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
id "$RUN_USER" >/dev/null || { echo "run bootstrap/00-host.sh first" >&2; exit 1; }

install -m 0755 -o root -g root "$here/runner/claw-run" /usr/local/sbin/claw-run

if [[ ! -f /etc/claw-hub/runner.json ]]; then
  # 既定値は claw-run 内の DEFAULTS。ここでは上書きしたい項目だけを書く
  cat > /etc/claw-hub/runner.json <<'JSON'
{
  "limits": { "MemoryMax": "3G", "MemorySwapMax": "0", "CPUQuota": "150%", "TasksMax": "256" },
  "default_timeout_sec": 1800
}
JSON
fi
chown root:root /etc/claw-hub/runner.json && chmod 0644 /etc/claw-hub/runner.json

if [[ ! -f /etc/claw-hub/prompts/example-nightly.md ]]; then
  cat > /etc/claw-hub/prompts/example-nightly.md <<'MD'
このリポジトリのテストを実行し、失敗しているものがあれば原因を調べて最小限の修正をしてください。
- 依存の追加・削除、外部への push、秘密情報の読み書きはしないこと
- 最後に、変更したファイルと理由を3行以内で報告すること
MD
fi
chmod 0644 /etc/claw-hub/prompts/*.md

# Gateway ユーザーが使えるのは claw-run だけ（引数の検証は claw-run 側で行う）
sudoers=/etc/sudoers.d/claw-run
tmp="$(mktemp)"
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/claw-run\n' "$GATEWAY_USER" > "$tmp"
visudo -cf "$tmp"
install -m 0440 -o root -g root "$tmp" "$sudoers"
rm -f "$tmp"

if [[ "${INSTALL_CLIS:-0}" == "1" ]]; then
  # バージョン固定したい場合は CODEX_PKG / CLAUDE_PKG を指定
  npm install -g "${CODEX_PKG:-@openai/codex}" "${CLAUDE_PKG:-@anthropic-ai/claude-code}"
fi

cat <<EOF
claw-run installed. Log the CLIs in AS ${RUN_USER} (not as ${GATEWAY_USER}):
  sudo -u ${RUN_USER} -H codex login --device-auth
  sudo -u ${RUN_USER} -H claude          # /login。または 'claude setup-token' で長期トークンを作り
                                          # /etc/claw-hub/runner-secrets/claude.env に CLAUDE_CODE_OAUTH_TOKEN=... を置き
                                          # runner.json の agents.claude.env_file に指定する
Smoke test (as ${GATEWAY_USER}):
  claw-run --agent codex --prompt-file example-nightly.md --dry-run
  echo 'pwd と whoami を実行して結果だけ答えて' | sudo -n /usr/local/sbin/claw-run --agent codex --timeout 300
EOF
