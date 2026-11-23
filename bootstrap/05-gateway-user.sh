#!/usr/bin/env bash
# root でしかログインできない VPS（KAGOYA 等）向け: Gateway 用の一般ユーザーを作る。root で実行する。
# OCI のように最初から ubuntu ユーザーがある環境では不要。
#   ./bootstrap/05-gateway-user.sh            # claw を作り、導入中だけ NOPASSWD sudo を付与
#   ./bootstrap/05-gateway-user.sh --finish   # 導入後: 一時 sudo を外す（30-runner.sh の claw-run 用 sudoers だけが残る）
#
# 以降の bootstrap は Gateway ユーザーで入り直して実行する:
#   sudo -iu claw            # または tailnet 参加後は: ssh claw@openclaw（Tailscale SSH）
#   git clone -b claw-hub https://github.com/MICHICOM/miclaw ~/miclaw && cd ~/miclaw
#   sudo GATEWAY_USER=claw ./bootstrap/00-host.sh   ...（README「KAGOYA VPS」参照）
set -euo pipefail
GATEWAY_USER="${GATEWAY_USER:-claw}"
TMP_SUDOERS=/etc/sudoers.d/90-claw-bootstrap

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
[[ "$GATEWAY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid GATEWAY_USER: $GATEWAY_USER" >&2; exit 1; }

case "${1:-}" in
  --finish)
    rm -f "$TMP_SUDOERS"
    echo "removed temporary sudo for $GATEWAY_USER. remaining:"
    sudo -l -U "$GATEWAY_USER" || true
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--finish]" >&2; exit 2 ;;
esac

if ! id "$GATEWAY_USER" >/dev/null 2>&1; then
  # パスワードは設定しない（ロック状態）。入るのは root からの sudo -iu か Tailscale SSH のみ
  useradd --create-home --shell /bin/bash "$GATEWAY_USER"
fi

# OpenClaw インストーラ（NodeSource 経由の Node 導入）と 00〜50 の root 実行に使う一時権限
tmp="$(mktemp)"
printf '# claw-hub bootstrap 用の一時権限。導入後に 05-gateway-user.sh --finish で削除する\n%s ALL=(ALL) NOPASSWD: ALL\n' "$GATEWAY_USER" > "$tmp"
visudo -cf "$tmp" >/dev/null
install -m 0440 -o root -g root "$tmp" "$TMP_SUDOERS"
rm -f "$tmp"

echo "gateway user $GATEWAY_USER ready (temporary NOPASSWD sudo: $TMP_SUDOERS)"
echo "next: sudo -iu $GATEWAY_USER"
