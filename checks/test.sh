#!/usr/bin/env bash
# ローカルで実行できるテストを一括実行する（VM 不要）。
#   ./checks/test.sh
# 必要: Node 24+（node:sqlite）、python3。任意: shellcheck、openclaw（設定のスキーマ検証）
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
rc=0

echo "== bridge (node:test)"
(cd bridge && node --test 'test/*.test.mjs') || rc=1

echo "== claw-run (unittest)"
python3 -I -m unittest discover -s runner/test || rc=1

if command -v shellcheck >/dev/null; then
  echo "== shellcheck"
  shellcheck -S warning bootstrap/*.sh checks/*.sh backup/claw-backup bridge/claw-bridge bridge/claw-bridge-sync || rc=1
else
  echo "== shellcheck: skipped (not installed)"
fi

if command -v openclaw >/dev/null; then
  echo "== openclaw config schema (dry-run against an empty profile)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  printf 'DISCORD_OWNER_ID=123456789012345678\nDISCORD_GUILD_ID=223456789012345678\nDISCORD_CHANNEL_ID=323456789012345678\n' > "$tmp/ids.env"
  checks/render-config.sh "$tmp/ids.env" > "$tmp/patch.json5"
  HOME="$tmp" OPENCLAW_GATEWAY_TOKEN=x OPENCLAW_HOOKS_TOKEN=x DISCORD_BOT_TOKEN=x \
    openclaw config patch --file "$tmp/patch.json5" --dry-run || rc=1
else
  echo "== openclaw config schema: skipped (openclaw not installed)"
fi

exit $rc
