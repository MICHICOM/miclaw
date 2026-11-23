#!/usr/bin/env bash
# OCI Ampere A1 (Ubuntu 24.04 aarch64) のホスト初期化。root で実行する。
#   sudo ./bootstrap/00-host.sh
# 何度実行しても同じ結果になる（冪等）。
set -euo pipefail

GATEWAY_USER="${GATEWAY_USER:-ubuntu}"
RUN_USER="${RUN_USER:-clawrun}"
HOSTNAME_WANTED="${HOSTNAME_WANTED:-openclaw}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
arch="$(uname -m)"
[[ "$arch" == "aarch64" ]] || echo "warning: expected aarch64 (OCI A1), got $arch" >&2
id "$GATEWAY_USER" >/dev/null 2>&1 || { echo "gateway user $GATEWAY_USER not found" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
# build-essential: ARM64 でネイティブモジュールをビルドする依存がある（OpenClaw 公式手順）
# podman/uidmap: rootless サンドボックス / rclone: 外部成果物の取り込みとバックアップ転送 / age: バックアップ暗号化
apt-get install -y --no-install-recommends \
  build-essential ca-certificates curl git jq sqlite3 python3 \
  podman uidmap slirp4netns passt fuse-overlayfs \
  rclone age unattended-upgrades

hostnamectl set-hostname "$HOSTNAME_WANTED"
# ログアウト後も user systemd（openclaw-gateway.service）を動かし続ける
loginctl enable-linger "$GATEWAY_USER"

# rootless Podman 用の subuid/subgid（Ubuntu は通常作成済み。無ければ追加）
grep -q "^${GATEWAY_USER}:" /etc/subuid || usermod --add-subuids 100000-165535 "$GATEWAY_USER"
grep -q "^${GATEWAY_USER}:" /etc/subgid || usermod --add-subgids 100000-165535 "$GATEWAY_USER"

# AI CLI を動かす専用ユーザー（ログイン不可）。Gateway ユーザーの資格情報とは分離する
if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --create-home --home-dir "/home/$RUN_USER" --shell /usr/sbin/nologin "$RUN_USER"
fi
install -d -m 0700 -o "$RUN_USER" -g "$RUN_USER" "/home/$RUN_USER/.codex" "/home/$RUN_USER/.claude" "/home/$RUN_USER/.gemini"

install -d -m 0755 /srv/claw
install -d -m 0711 /srv/claw/jobs          # ジョブごとに 0700 で clawrun 所有
install -d -m 0755 /srv/claw/repos         # claw-run --repo の clone 元（読み取り専用ミラー）
install -d -m 0755 /etc/claw-hub /etc/claw-hub/prompts
install -d -m 0700 /etc/claw-hub/secrets /etc/claw-hub/runner-secrets

# 小さめの swap（Gateway ~2GB + Codex/Claude Code 実行時のピーク対策。常用はしない）
if ! swapon --show | grep -q .; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/90-claw-hub.conf
fi

# セキュリティ更新は自動適用
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "host ready: $(lsb_release -ds 2>/dev/null || true) $arch, gateway user=$GATEWAY_USER, runner user=$RUN_USER"
