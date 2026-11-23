#!/usr/bin/env bash
# Tailscale 導入。root で実行する。
#   sudo ./bootstrap/10-tailscale.sh
# 実行後、表示された URL でログインして tailnet に参加させる。
# 参加を確認したら OCI の VCN Security List から SSH(22) を含む ingress をすべて消し、
# UDP 41641 だけを残す（docs/spec-v0.2.md §4.1）。
set -euo pipefail
GATEWAY_USER="${GATEWAY_USER:-ubuntu}"
TS_HOSTNAME="${TS_HOSTNAME:-openclaw}"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }

if ! command -v tailscale >/dev/null; then
  # Tailscale 公式の apt リポジトリ導入スクリプト
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled

# --ssh: tailnet ID で SSH（sshd 不要）。管理 UI は OpenClaw が Serve で公開する
tailscale up --ssh --hostname="$TS_HOSTNAME"
# Gateway ユーザーが sudo なしで Serve のクレームを取得・解放できるようにする（OpenClaw 公式推奨）
tailscale set --operator="$GATEWAY_USER"

tailscale status | head -5
echo
echo "Next: confirm 'ssh ${GATEWAY_USER}@${TS_HOSTNAME}' works over tailnet, then lock the OCI VCN down to UDP 41641 only."
