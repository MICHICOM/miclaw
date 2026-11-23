#!/usr/bin/env bash
# 完了判定（仕様書 §1.5 / docs/spec-v0.2.md §6）のうち、VM 上で機械的に確かめられるものを検査する。
# Gateway ユーザーで実行（一部 sudo -n を使う）:  ./checks/acceptance.sh
# 外部からの到達性（公開 IP に対するポートスキャン）は VM の外から別途確認すること。
set -uo pipefail
pass=0; fail=0; warn=0
ok()   { printf '  \e[32mPASS\e[0m %s\n' "$*"; pass=$((pass+1)); }
ng()   { printf '  \e[31mFAIL\e[0m %s\n' "$*"; fail=$((fail+1)); }
note() { printf '  \e[33mWARN\e[0m %s\n' "$*"; warn=$((warn+1)); }
sec()  { printf '\n[%s]\n' "$*"; }
STATE="$HOME/.openclaw"
# sudo -iu / su で入ると user systemd のバスが見えない。linger 済みなら /run/user/$UID がある
if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$(id -u)" ]]; then
  XDG_RUNTIME_DIR="/run/user/$(id -u)"; export XDG_RUNTIME_DIR
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

sec "A1 管理面がインターネットに出ていない"
# loopback / Tailscale(100.64/10, fd7a:115c:a1e0::/48) 以外で LISTEN している TCP を探す
public="$(ss -H -tln | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[?::ffff:127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|\[fd7a:115c:a1e0:)' || true)"
if [[ -z "$public" ]]; then ok "公開アドレスで LISTEN している TCP ポートなし"; else ng "公開 LISTEN: $(echo $public)"; fi
if grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
  grep -qsE '^DEFAULT_INPUT_POLICY="(DROP|REJECT)"' /etc/default/ufw && ok "ufw 有効・受信は既定 deny" || ng "ufw 有効だが受信の既定が deny でない"
else
  note "ufw 無効（OCI は VCN、VPS は bootstrap/15-firewall.sh で閉じる）"
fi
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then note "sshd が動作中（Tailscale SSH 確認後は無効化推奨）"; else ok "sshd 停止"; fi
tailscale serve status 2>/dev/null | grep -q 'proxy' && ok "Tailscale Serve 経由で公開" || ng "Tailscale Serve の経路が見つからない"
tailscale funnel status 2>/dev/null | grep -qi 'funnel on' && ng "Funnel（公開）が有効" || ok "Funnel 無効"

sec "A2 再起動後に復旧する"
systemctl --user is-enabled --quiet openclaw-gateway.service && ok "gateway service enabled" || ng "gateway service が enabled でない"
systemctl --user is-active --quiet openclaw-gateway.service && ok "gateway service active" || ng "gateway service が停止中"
loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q 'Linger=yes' && ok "linger 有効" || ng "linger 無効（ログアウトで停止する）"
openclaw channels status 2>/dev/null | grep -iq 'discord.*\(connected\|running\|ok\)' && ok "Discord 接続" || note "Discord の接続状態を確認できない（openclaw channels status を目視）"

sec "A3 設定と監査"
openclaw config validate >/dev/null 2>&1 && ok "config valid" || ng "config validate 失敗"
crit="$(openclaw security audit --json 2>/dev/null | jq -r '.summary.critical // "?"')"
[[ "$crit" == "0" ]] && ok "security audit: critical 0" || ng "security audit: critical=$crit"
[[ "$(stat -c %a "$STATE")" == "700" ]] && ok "~/.openclaw は 0700" || ng "~/.openclaw の権限が $(stat -c %a "$STATE")"
[[ "$(stat -c %a "$STATE/.env" 2>/dev/null)" == "600" ]] && ok "~/.openclaw/.env は 0600" || ng "~/.openclaw/.env の権限"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18789/hooks/agent -H 'Content-Type: application/json' -d '{"message":"x"}')"
[[ "$code" == "401" ]] && ok "/hooks/agent は無認証で 401" || ng "/hooks/agent 無認証応答が $code"

sec "A4 実行の隔離"
[[ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" == "true" ]] && ok "podman rootless" || ng "podman が rootless でない / 動かない"
podman image exists openclaw-sandbox:trixie-slim && ok "sandbox image あり" || ng "sandbox image なし"
if [[ -S /var/run/docker.sock ]] && [[ -w /var/run/docker.sock ]]; then ng "Gateway ユーザーが Docker ソケットに書ける（root 相当）"; else ok "Docker ソケットへの書込権なし"; fi
if [[ -x /usr/local/sbin/claw-run && "$(stat -c %U /usr/local/sbin/claw-run)" == "root" ]]; then ok "claw-run は root 所有"; else ng "claw-run が無い / root 所有でない"; fi
sudo -n -l 2>/dev/null | grep -vE 'claw-run|^\s*$|Matching|User .* may run|env_|secure_path|use_pty|Defaults' | grep -q . \
  && ng "claw-run 以外の sudo 権限がある: $(sudo -n -l 2>/dev/null | grep NOPASSWD | grep -v claw-run | head -2)" \
  || ok "sudo は claw-run のみ（または sudo 不可）"
left="$(systemctl list-units --all --plain --no-legend 'claw-job-*' 2>/dev/null | wc -l)"
[[ "$left" == "0" ]] && ok "残留ジョブユニットなし" || ng "claw-job-* ユニットが $left 個残っている"
/usr/local/sbin/claw-run --agent codex --prompt-file example-nightly.md --dry-run >/dev/null 2>&1 && ok "claw-run dry-run" || note "claw-run dry-run 失敗（CLI 未導入なら想定内）"

sec "A5 取り込みブリッジ"
systemctl is-active --quiet claw-bridge.timer && ok "claw-bridge.timer active" || ng "claw-bridge.timer 停止"
r="$(systemctl show claw-bridge.service -p Result --value 2>/dev/null)"
[[ "$r" == "success" ]] && ok "直近の bridge 実行: success" || note "直近の bridge 実行: ${r:-unknown}（FAILED イベントがあると exit 3 → sudo claw-bridge status）"

sec "A6 バックアップ"
systemctl is-active --quiet claw-backup.timer && ok "claw-backup.timer active" || ng "claw-backup.timer 停止"
last="$(systemctl show claw-backup.service -p ExecMainExitTimestamp --value 2>/dev/null)"
r="$(systemctl show claw-backup.service -p Result --value 2>/dev/null)"
[[ "$r" == "success" && -n "$last" ]] && ok "直近のバックアップ成功: $last" || ng "バックアップ未実行 / 失敗 (${r:-unknown})"

sec "A7 資源"
mem="$(ps -o rss= -C openclaw-gateway 2>/dev/null | awk '{s+=$1} END {printf "%d", s/1024}')"
[[ -n "$mem" && "$mem" -lt 3500 ]] && ok "gateway RSS ${mem}MB" || note "gateway RSS ${mem:-?}MB"
free -m | awk '/Mem:/ {printf "  info  メモリ: used %sMB / total %sMB, available %sMB\n", $3, $2, $7}'

printf '\nresult: %d pass, %d fail, %d warn\n' "$pass" "$fail" "$warn"
[[ $fail -eq 0 ]]
