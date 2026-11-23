#!/usr/bin/env bash
# OpenClaw の導入と、ハードニング済み設定の適用。Gateway ユーザー（ubuntu）で実行する。root では実行しない。
#   ./bootstrap/20-openclaw.sh
#
# 事前に config/ids.env を作っておく（config/ids.env.example をコピー）。
# Discord Bot トークンは初回のみ対話入力し、~/.openclaw/.env（0600）に保存する。
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
IDS_FILE="${IDS_FILE:-$here/config/ids.env}"
OPENCLAW_VERSION="${OPENCLAW_VERSION:-latest}"
STATE="$HOME/.openclaw"
ENV_FILE="$STATE/.env"

[[ $EUID -ne 0 ]] || { echo "do not run as root; run as the gateway user" >&2; exit 1; }
[[ -f "$IDS_FILE" ]] || { echo "missing $IDS_FILE (copy config/ids.env.example)" >&2; exit 1; }

step() { printf '\n== %s\n' "$*"; }

step "OpenClaw install"
if ! command -v openclaw >/dev/null; then
  # 公式インストーラ。Linux では NodeSource 経由で Node 24 LTS を入れる（sudo を求められる）
  curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh \
    | bash -s -- --no-onboard --version "$OPENCLAW_VERSION"
  hash -r
fi
openclaw --version

step "secrets (~/.openclaw/.env, 0600)"
install -d -m 0700 "$STATE"
touch "$ENV_FILE" && chmod 600 "$ENV_FILE"
ensure_secret() { # name generator
  local name="$1"
  grep -q "^${name}=" "$ENV_FILE" || printf '%s=%s\n' "$name" "$(openssl rand -hex 32)" >> "$ENV_FILE"
}
ensure_secret OPENCLAW_GATEWAY_TOKEN
ensure_secret OPENCLAW_HOOKS_TOKEN
if ! grep -q '^DISCORD_BOT_TOKEN=' "$ENV_FILE"; then
  read -r -s -p "Discord bot token: " tok; echo
  [[ -n "$tok" ]] || { echo "empty token" >&2; exit 1; }
  printf 'DISCORD_BOT_TOKEN=%s\n' "$tok" >> "$ENV_FILE"
  unset tok
fi
set -a; . "$ENV_FILE"; set +a

step "sandbox image (rootless podman)"
if ! podman image exists openclaw-sandbox:trixie-slim; then
  # OpenClaw 公式ドキュメントのインライン Dockerfile と同一（npm 版にはビルドスクリプトが同梱されないため）
  podman build -t openclaw-sandbox:trixie-slim - <<'DOCKERFILE'
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git jq python3 ripgrep \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
DOCKERFILE
fi

step "plugins"
# Discord は本体同梱ではなくチャンネルプラグイン（2026.11 時点）
if ! openclaw plugins list 2>/dev/null | grep -q '│ discord '; then
  openclaw plugins install @openclaw/discord --pin
fi
openclaw plugins enable workboard >/dev/null

step "config patch (dry-run → apply)"
rendered="$(mktemp)"; trap 'rm -f "$rendered"' EXIT
"$here/checks/render-config.sh" "$IDS_FILE" > "$rendered"
openclaw config patch --file "$rendered" --dry-run
openclaw config patch --file "$rendered"
openclaw config validate
chmod 700 "$STATE"

step "standing orders (AGENTS.md)"
# 既存の AGENTS.md は上書きしない。マーカーが無ければ末尾に追記する
for agent in main reader; do
  ws="$STATE/workspace"; [[ $agent == reader ]] && ws="$STATE/workspace-reader"
  install -d -m 0700 "$ws"
  if ! grep -q 'claw-hub:standing-orders' "$ws/AGENTS.md" 2>/dev/null; then
    { [[ -s "$ws/AGENTS.md" ]] && echo; cat "$here/workspace/$agent/AGENTS.md"; } >> "$ws/AGENTS.md"
  fi
done

step "gateway service (systemd --user)"
openclaw gateway install
systemctl --user restart openclaw-gateway.service
sleep 5
systemctl --user --no-pager status openclaw-gateway.service | head -5 || true

step "security audit"
openclaw security audit || true

cat <<'EOF'

Next (interactive, once):
  # 窓口エージェントのモデル認証（ヘッドレスなので device code）
  openclaw models auth login --provider openai --device-code
  openclaw models status
  # Discord の DM で bot に話しかけ、返事が来ることを確認
  # 続けて: sudo ./bootstrap/30-runner.sh && sudo ./bootstrap/40-bridge.sh && sudo ./bootstrap/50-backup.sh
EOF
