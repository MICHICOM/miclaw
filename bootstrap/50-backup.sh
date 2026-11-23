#!/usr/bin/env bash
# 暗号化オフサイトバックアップの導入。root で実行する。
#   sudo AGE_RECIPIENT=age1... ./bootstrap/50-backup.sh
#
# 事前準備:
#   1) 手元の PC（VM ではない）で:  age-keygen -o claw-backup.key   → 表示される公開鍵 age1... を控える
#      秘密鍵 claw-backup.key は VM に置かない。パスワードマネージャ等に保管する
#   2) VM で: rclone config --config /etc/claw-hub/secrets/rclone-backup.conf
#      → 名前 "gdrive-backup"、type drive、scope は "drive.file"（rclone が作ったファイルだけ触れる）
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
GATEWAY_USER="${GATEWAY_USER:-ubuntu}"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
oc_bin="$(runuser -u "$GATEWAY_USER" -- bash -lc 'command -v openclaw' || true)"
[[ -n "$oc_bin" ]] || { echo "openclaw not found for $GATEWAY_USER" >&2; exit 1; }

if [[ -n "${AGE_RECIPIENT:-}" ]]; then
  [[ "$AGE_RECIPIENT" =~ ^age1[0-9a-z]{58}$ ]] || { echo "AGE_RECIPIENT must be an age public key (age1...)" >&2; exit 1; }
  grep -qx "$AGE_RECIPIENT" /etc/claw-hub/backup-recipients.txt 2>/dev/null || echo "$AGE_RECIPIENT" >> /etc/claw-hub/backup-recipients.txt
fi
[[ -s /etc/claw-hub/backup-recipients.txt ]] || { echo "set AGE_RECIPIENT=age1... (public key only)" >&2; exit 1; }
chmod 0644 /etc/claw-hub/backup-recipients.txt

if [[ ! -f /etc/claw-hub/backup.env ]]; then
  cat > /etc/claw-hub/backup.env <<EOF
GATEWAY_USER=${GATEWAY_USER}
OPENCLAW_BIN=${oc_bin}
BACKUP_RCLONE_DEST=gdrive-backup:claw-backups
BACKUP_KEEP_DAYS=30
EOF
fi

install -m 0755 -o root -g root "$here/backup/claw-backup" /usr/local/sbin/claw-backup
install -m 0644 "$here"/systemd/claw-backup.service "$here"/systemd/claw-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now claw-backup.timer

if [[ -s /etc/claw-hub/secrets/rclone-backup.conf ]]; then
  echo "running first backup..."
  systemctl start claw-backup.service
  journalctl -u claw-backup.service -n 5 --no-pager
else
  echo "NOTE: /etc/claw-hub/secrets/rclone-backup.conf がありません。rclone config 後に: sudo systemctl start claw-backup.service"
fi
