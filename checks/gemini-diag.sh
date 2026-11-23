#!/usr/bin/env bash
# Gemini API キーが「サーバからだと弾かれる」原因の切り分け。Gateway ユーザーで実行:
#   ./checks/gemini-diag.sh [model]        例: ./checks/gemini-diag.sh gemini-3.8-flash
# キーは ~/.openclaw/.env の GEMINI_API_KEY（または GOOGLE_API_KEY）から読む。キー本体は表示しない。
set -uo pipefail
MODEL="${1:-gemini-3.8-flash}"
ENV_FILE="${ENV_FILE:-$HOME/.openclaw/.env}"
API=https://generativelanguage.googleapis.com/v1beta
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

say()  { printf '%s\n' "$*"; }
hint() { printf '  → %s\n' "$*"; }

# --- 1. キーの読み込みと形式チェック ---------------------------------------
raw="$(grep -E '^(GEMINI_API_KEY|GOOGLE_API_KEY)=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)"
if [[ -z "$raw" ]]; then
  say "[key] $ENV_FILE に GEMINI_API_KEY / GOOGLE_API_KEY がありません"; exit 2
fi
say "[key] 長さ=${#raw} 先頭=${raw:0:4}…（本体は非表示）"
case "$raw" in *$'\r'*) say "[key] NG: 改行コード CR が混入（Windows で編集した .env）"; hint "sed -i 's/\\r\$//' $ENV_FILE" ;; esac
case "$raw" in \"*|\'*) say "[key] NG: 引用符ごと値になっている"; hint "KEY=値 の形にする（引用符なし）" ;; esac
case "$raw" in *' '*) say "[key] NG: 空白が含まれている" ;; esac
key="$(printf '%s' "$raw" | tr -d '\r"'"'"' ')"
[[ "$key" =~ ^AIza[0-9A-Za-z_-]{35}$ ]] && say "[key] 形式: AI Studio の API キーとして妥当" \
  || say "[key] 注意: AI Studio キー（AIza…39文字）の形式ではない"

# --- 2. サーバの出口（どの IP / 国として Google に見えるか）---------------------
for fam in 4 6; do
  loc="$(curl -"$fam" -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | awk -F= '/^(ip|loc)=/{printf "%s=%s ", $1, $2}')"
  say "[egress IPv$fam] ${loc:-接続不可}"
done

# --- 3. API 呼び出し（IPv4 / IPv6 / 既定 を個別に）-----------------------------
call() { # family label method path [body]
  local fam="$1" label="$2" method="$3" path="$4" body="${5:-}"
  local out="$tmp/${label//\//_}.json" code
  local args=(-s -m 30 -o "$out" -w '%{http_code}' -H "x-goog-api-key: $key" -X "$method")
  [[ -n "$fam" ]] && args+=(-"$fam")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' -d "$body")
  code="$(curl "${args[@]}" "$API/$path" 2>/dev/null)"
  [[ "$code" == "000" ]] && { say "[$label] 接続できない（その IP ファミリが無い / 遮断）"; return; }
  local status reason msg
  status="$(jq -r '.error.status // empty' "$out" 2>/dev/null)"
  reason="$(jq -r '[.error.details[]?.reason // empty] | join(",")' "$out" 2>/dev/null)"
  msg="$(jq -r '.error.message // empty' "$out" 2>/dev/null | head -c 200)"
  if [[ "$code" == "200" ]]; then say "[$label] HTTP 200 OK"; else say "[$label] HTTP $code ${status} ${reason} ${msg}"; fi
  printf '%s %s %s %s\n' "$label" "$code" "$status" "$reason $msg" >> "$tmp/results"
}
gen='{"contents":[{"parts":[{"text":"Reply with OK."}]}],"generationConfig":{"maxOutputTokens":8}}'
call 4 "list/IPv4" GET "models?pageSize=1"
call 6 "list/IPv6" GET "models?pageSize=1"
call "" "generate/default" POST "models/${MODEL}:generateContent" "$gen"

# --- 4. 判定 -------------------------------------------------------------------
say ""; say "== 判定"
r="$(cat "$tmp/results" 2>/dev/null)"
matched=0
m() { grep -q -- "$1" <<<"$r" && { matched=1; say "● $2"; shift 2; for h in "$@"; do hint "$h"; done; }; }
m "location is not supported" "Google がサーバの出口 IP を『対応外の地域』と判定" \
  "上の egress の loc を確認。IPv6 だけ NG なら IPv4 を優先させる（/etc/gai.conf で 'precedence ::ffff:0:0/96 100'）" \
  "IP の地域判定が誤っている VPS では Vertex AI（GCP プロジェクト）経由にするか、別リージョンから呼ぶ"
m "API_KEY_IP_ADDRESS_BLOCKED" "キーに IP 制限があり、サーバの IP が許可されていない" \
  "Google Cloud コンソール → 認証情報 → このキー → アプリケーションの制限 に上の egress IP を追加（IPv6 で出ているなら IPv6 も）"
m "API_KEY_HTTP_REFERRER_BLOCKED" "キーが『ウェブサイト（HTTP リファラー）』制限になっている。サーバからはリファラーが無いので必ず弾かれる" \
  "サーバ用に別キーを作り、制限を『IP アドレス』にする（リファラー制限のキーは使い回さない）"
m "API_KEY_ANDROID_APP_BLOCKED\|API_KEY_IOS_APP_BLOCKED" "キーがスマホアプリ用の制限になっている" "サーバ用に別キーを作る"
m "API_KEY_SERVICE_BLOCKED\|SERVICE_DISABLED" "キーの API 制限に Generative Language API が入っていない / API が無効" \
  "キーの『API の制限』に Generative Language API を追加、またはプロジェクトで API を有効化"
m "API_KEY_INVALID\|API key not valid" "キーが無効（貼り間違い・CR 混入・削除済み）" "上の [key] 行を確認し、AI Studio でキーを再発行"
m "RESOURCE_EXHAUSTED\| 429 " "無料枠のレート/日次上限" "時間をおく。フォールバック用途ならモデルを flash 系にする"
m "NOT_FOUND" "モデル名が存在しない" "openclaw models list --provider google --refresh で使える ID を確認"
if [[ $matched -eq 0 ]] && grep -q "generate/default 200" <<<"$r"; then
  say "● このサーバから API は使える。OpenClaw 経由で弾かれるなら、Gateway がキーを読めていない可能性"
  hint "systemctl --user restart openclaw-gateway.service の後 openclaw models list --provider google --refresh"
elif [[ $matched -eq 0 ]]; then
  say "● 既知のパターンに当てはまらない。上の HTTP 行（キーは含まれない）をそのまま共有してください"
fi
