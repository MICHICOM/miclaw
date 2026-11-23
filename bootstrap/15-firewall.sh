#!/usr/bin/env bash
# VPS（KAGOYA 等、OCI の VCN が無い環境）向け: ufw で受信を閉じる。root で実行する。10-tailscale.sh の後に実行。
#   sudo ./bootstrap/15-firewall.sh               # 受信は既定 deny。41641/udp と tailscale0 を許可。SSH はまだ残す
#   sudo CLOSE_SSH=1 ./bootstrap/15-firewall.sh   # tailnet 経由の SSH を確認した後: 公開側の SSH 許可を外す
#   sudo CLOSE_SSH=1 STOP_SSHD=1 ./bootstrap/15-firewall.sh   # さらに sshd 自体を止める（Tailscale SSH だけにする）
# 既に公開しているサービスを残す場合: EXTRA_ALLOW="80/tcp 443/tcp"
# ufw とは別に、事業者のコントロールパネル側のファイアウォールでも 41641/udp 以外を閉じること。
set -euo pipefail
CLOSE_SSH="${CLOSE_SSH:-0}"
STOP_SSHD="${STOP_SSHD:-0}"
EXTRA_ALLOW="${EXTRA_ALLOW:-}"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
command -v tailscale >/dev/null || { echo "run bootstrap/10-tailscale.sh first" >&2; exit 1; }
ip link show tailscale0 >/dev/null 2>&1 || { echo "tailscale0 not found (tailscale up が未完了)" >&2; exit 1; }

SSH_PORT="${SSH_PORT:-$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}')}"
SSH_PORT="${SSH_PORT:-22}"

if ! command -v ufw >/dev/null; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ufw
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow 41641/udp comment 'tailscale direct'
ufw allow in on tailscale0 comment 'tailnet'
for rule in $EXTRA_ALLOW; do ufw allow "$rule"; done

if [[ "$CLOSE_SSH" == "1" ]]; then
  tailscale status >/dev/null || { echo "tailscale is not up; refusing to close SSH" >&2; exit 1; }
  ufw --force delete allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
else
  ufw allow "${SSH_PORT}/tcp"
fi

ufw --force enable
ufw status verbose

if [[ "$CLOSE_SSH" == "1" && "$STOP_SSHD" == "1" ]]; then
  # Ubuntu 24.04 は ssh.socket で起動する。両方止める（戻すとき: systemctl enable --now ssh.socket）
  systemctl disable --now ssh.socket ssh.service 2>/dev/null || true
  echo "sshd stopped. 以後は Tailscale SSH（ssh <user>@<tailnet 名>）か事業者のコンソールで入る"
fi

if [[ "$CLOSE_SSH" != "1" ]]; then
  echo
  echo "Next: tailnet 経由の SSH を確認したら: sudo CLOSE_SSH=1 ./bootstrap/15-firewall.sh"
fi
