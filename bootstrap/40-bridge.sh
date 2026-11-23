#!/usr/bin/env bash
# claw-bridge（外部クラウドAI成果物の取り込み）の導入。root で実行する。
#   sudo ./bootstrap/40-bridge.sh
# 事前準備（root で一度だけ）:
#   rclone config --config /etc/claw-hub/secrets/rclone.conf
#     → 名前 "gdrive"、type drive、scope は "drive.readonly"（読み取り専用）
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY_USER="${GATEWAY_USER:-ubuntu}"
gw_home="$(getent passwd "$GATEWAY_USER" | cut -d: -f6)"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
command -v node >/dev/null || { echo "node not found (run 20-openclaw.sh first)" >&2; exit 1; }

# 取り込み専用のシステムユーザー（Gateway / clawrun とは別）
id clawbridge >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/claw-bridge --shell /usr/sbin/nologin clawbridge

install -d -m 0755 /opt/claw-hub/bridge/lib
install -m 0644 "$here"/bridge/bridge.mjs /opt/claw-hub/bridge/
install -m 0644 "$here"/bridge/lib/*.mjs /opt/claw-hub/bridge/lib/
install -m 0755 "$here"/bridge/claw-bridge-sync /opt/claw-hub/bridge/
install -m 0755 -o root -g root "$here"/bridge/claw-bridge /usr/local/sbin/claw-bridge

# Hooks トークンを Gateway の .env から root 専用ファイルへ（systemd LoadCredential で渡す）
tok="$(grep '^OPENCLAW_HOOKS_TOKEN=' "$gw_home/.openclaw/.env" | cut -d= -f2-)"
[[ -n "$tok" ]] || { echo "OPENCLAW_HOOKS_TOKEN not found in $gw_home/.openclaw/.env" >&2; exit 1; }
umask 077
printf '%s' "$tok" > /etc/claw-hub/secrets/hooks-token
unset tok

if [[ ! -f /etc/claw-hub/bridge.env ]]; then
  # shellcheck disable=SC1091
  source "$here/config/ids.env"
  sed "s/__DISCORD_CHANNEL_ID__/${DISCORD_CHANNEL_ID}/" "$here/config/bridge.env.example" > /etc/claw-hub/bridge.env
fi
chmod 0644 /etc/claw-hub/bridge.env

# LoadCredential は存在しないファイルで失敗するので、未設定なら空ファイルを置く（同期スクリプトがスキップする）
[[ -e /etc/claw-hub/secrets/rclone.conf ]] || install -m 0600 /dev/null /etc/claw-hub/secrets/rclone.conf

install -m 0644 "$here"/systemd/claw-bridge.service "$here"/systemd/claw-bridge.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now claw-bridge.timer
systemctl list-timers claw-bridge.timer --no-pager

[[ -s /etc/claw-hub/secrets/rclone.conf ]] || echo "NOTE: /etc/claw-hub/secrets/rclone.conf がまだありません（Drive 同期はスキップされ、/var/lib/claw-bridge/inbox だけを読みます）"
echo "status: sudo claw-bridge status   /  manual run: sudo systemctl start claw-bridge.service"
