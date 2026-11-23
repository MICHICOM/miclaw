#!/usr/bin/env bash
# config/openclaw.patch.json5 のプレースホルダを置換して標準出力へ出す。
# 使い方: render-config.sh <ids.env>
#   ids.env には DISCORD_OWNER_ID / DISCORD_GUILD_ID / DISCORD_CHANNEL_ID を書く（秘密ではない数値ID）
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
ids_file="${1:?usage: render-config.sh <ids.env>}"

# shellcheck disable=SC1090
source "$ids_file"
for v in DISCORD_OWNER_ID DISCORD_GUILD_ID DISCORD_CHANNEL_ID; do
  val="${!v:-}"
  if [[ ! "$val" =~ ^[0-9]{15,22}$ ]]; then
    echo "error: $v must be a Discord snowflake ID (15-22 digits), got '${val}'" >&2
    exit 2
  fi
done

sed -e "s/__DISCORD_OWNER_ID__/${DISCORD_OWNER_ID}/g" \
    -e "s/__DISCORD_GUILD_ID__/${DISCORD_GUILD_ID}/g" \
    -e "s/__DISCORD_CHANNEL_ID__/${DISCORD_CHANNEL_ID}/g" \
    "$here/config/openclaw.patch.json5"
