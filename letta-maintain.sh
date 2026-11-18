#!/usr/bin/env bash
# Letta server maintenance (https://github.com/alessandrocornacchia/letta-server-ops), driven by cron:
#   letta-maintain daily   -> upgrade @letta-ai/letta-code, then request a restart
#   letta-maintain check   -> restart if requested and Letta is idle, or if the
#                             cloud listener is stuck reconnecting (>10 min)
#   letta-maintain status  -> print a health summary
#   letta-maintain test    -> send a test Slack message
# Before any restart, background jobs left in the service's cgroup (e.g. experiments
# launched by the agent) are moved to their own scope so the restart doesn't kill them.
# Reports and alerts go to Slack and to $LOG. Settings come from $CONF (see env.example).
set -uo pipefail

CONF=${LETTA_OPS_CONF:-$HOME/.config/letta-server-ops/env}
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"
UNIT=${LETTA_UNIT:-letta-server}
export PATH=${LETTA_NODE_BIN:+$LETTA_NODE_BIN:}/usr/local/bin:/usr/bin:/bin

CG=/sys/fs/cgroup$(systemctl show -p ControlGroup --value $UNIT.service)
STATE=$HOME/.letta/maintain
LOG=$STATE/maintain.log
PENDING=$STATE/restart-pending
RESTARTS=$STATE/stuck-restarts      # epoch per stuck-triggered restart
STUCK_SECS=600
QUIET_MINS=10
STUCK_MIN_GAP=3600                   # at most one stuck restart per hour
STUCK_MAX_PER_DAY=3
MARKER_GRACE=86400                   # warn if no listener markers after 24h of uptime
PENDING_WARN=172800                  # warn if daily restart blocked for 48h
mkdir -p "$STATE"

exec 9>"$STATE/lock"
flock -n 9 || exit 0

log() { echo "[$(date -u +%FT%TZ)] $*" >> "$LOG"; }

notify() {  # notify <emoji> <text>
  log "notify: $2"
  [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_USER_ID:-}" ] || { log "notify skipped: Slack not configured in $CONF"; return 0; }
  local body resp
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"channel": sys.argv[1], "text": sys.argv[2]}))' \
         "$SLACK_USER_ID" "$1 *$(hostname)* — $2")
  resp=$(curl -sS -m 20 -X POST https://slack.com/api/chat.postMessage \
         -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H 'Content-Type: application/json; charset=utf-8' \
         --data "$body" 2>&1)
  [[ "$resp" == *'"ok":true'* ]] || log "notify failed: $resp"
}

# Alert once per key until cleared, so a persisting condition doesn't spam every 15 min
alert_once() {  # alert_once <key> <text>
  [ -f "$STATE/alerted-$1" ] && return 0
  touch "$STATE/alerted-$1"; notify ":warning:" "$2"
}
clear_alert() { rm -f "$STATE/alerted-$1"; }

# Record why a restart is pending, keeping the original mtime so the 48h "blocked" timer isn't reset
set_pending() {
  local t; t=$(stat -c %Y "$PENDING" 2>/dev/null || date +%s)
  echo "$1" > "$PENDING"; touch -d "@$t" "$PENDING"
}

version() { letta --version 2>/dev/null | awk '{print $1}'; }
main_pid() { systemctl show -p MainPID --value $UNIT; }
uptime_secs() {
  local t; t=$(systemctl show -p ActiveEnterTimestampMonotonic --value $UNIT)
  echo $(( $(awk '{printf "%d", $1}' /proc/uptime) - ${t:-0} / 1000000 ))
}

# Journal of the current service run only, so lines from before a restart never count
journal_now() {
  journalctl -u $UNIT _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value $UNIT)" "$@" 2>/dev/null
}

descendants() {  # pid and all its descendants
  local p=$1; echo "$p"
  for c in $(ps -o pid= --ppid "$p"); do descendants "$c"; done
}

is_idle() {
  local mp kids turns
  mp=$(main_pid); [ "${mp:-0}" -gt 0 ] || return 1
  # An active agent turn shows up as a child of the letta server (claude, bash tools...)
  kids=$(ps -o args= --ppid "$mp" | grep -vc 'letta channel-gateway')
  if [ "$kids" -gt 0 ]; then log "busy: $kids child process(es) of letta"; return 1; fi
  turns=$(journal_now --since "-${QUIET_MINS}min" -o cat | grep -cE 'status: (processing|receiving)')
  if [ "$turns" -gt 0 ]; then log "busy: turn activity in last ${QUIET_MINS} min"; return 1; fi
  return 0
}

# Last listener event in this run is "Reconnecting" with no "Connected" for STUCK_SECS.
# If the run has logged neither marker for a day, the log format probably changed:
# warn, and stuck detection is effectively off (no markers -> never stuck).
is_stuck() {
  local last ts
  last=$(journal_now -o short-unix | grep -E 'Reconnecting \(attempt|Connected\. Awaiting' | tail -1)
  if [ -z "$last" ]; then
    [ "$(uptime_secs)" -gt $MARKER_GRACE ] && alert_once markers \
      "Letta log markers ('Connected. Awaiting' / 'Reconnecting (attempt') not seen in 24h of uptime. The log format may have changed; stuck-connection detection is disabled until the script is updated."
    return 1
  fi
  clear_alert markers
  [[ "$last" == *Reconnecting* ]] || return 1
  ts=${last%%.*}
  [ $(( $(date +%s) - ts )) -gt $STUCK_SECS ]
}

# Rate limit for stuck restarts, so a misdetection can't cause a restart loop
stuck_restart_allowed() {
  local now recent last
  now=$(date +%s)
  [ -f "$RESTARTS" ] || touch "$RESTARTS"
  awk -v c=$((now - 86400)) '$1 > c' "$RESTARTS" > "$RESTARTS.tmp" && mv "$RESTARTS.tmp" "$RESTARTS"
  recent=$(wc -l < "$RESTARTS"); last=$(tail -1 "$RESTARTS")
  if [ "$recent" -ge $STUCK_MAX_PER_DAY ]; then
    alert_once ratelimit "Letta listener looks stuck again, but $recent stuck-restarts already happened in 24h. Not restarting; please take a look (\`journalctl -u $UNIT -n 100\`)."
    return 1
  fi
  [ -n "$last" ] && [ $((now - last)) -lt $STUCK_MIN_GAP ] && { log "stuck, but last stuck-restart <1h ago"; return 1; }
  return 0
}

rescue_orphans() {
  local mp keep pids first scope n
  mp=$(main_pid)
  keep=" $(descendants "$mp" | tr '\n' ' ') "
  pids=$(for p in $(cat $CG/cgroup.procs); do [[ "$keep" == *" $p "* ]] || echo "$p"; done)
  [ -n "$pids" ] || return 0
  scope=letta-orphans-$(date -u +%Y%m%dT%H%M%S).scope
  first=$(echo "$pids" | head -1)
  if ! sudo -n busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
       org.freedesktop.systemd1.Manager StartTransientUnit 'ssa(sv)a(sa(sv))' \
       "$scope" fail 2 PIDs au 1 "$first" Description s "Jobs rescued from $UNIT" 0 >/dev/null; then
    notify ":x:" "Could not move background jobs out of $UNIT before restart, so the restart was skipped to avoid killing them."
    return 1
  fi
  sleep 1
  local dst; dst=/sys/fs/cgroup$(systemctl show -p ControlGroup --value "$scope")
  # Two passes to catch children forked during the move
  for _ in 1 2; do
    for p in $(cat $CG/cgroup.procs); do
      [[ "$keep" == *" $p "* ]] || echo "$p" | sudo -n tee "$dst/cgroup.procs" >/dev/null 2>&1
    done
  done
  n=$(wc -l < "$dst/cgroup.procs")
  log "moved $n process(es) to $scope"
  RESCUED=" ($n background process(es) kept alive in \`$scope\`)"
}

restart() {  # restart <emoji> <reason>
  RESCUED=""
  rescue_orphans || return 1
  log "restarting $UNIT: $2"
  if ! sudo -n systemctl restart $UNIT; then
    notify ":x:" "Restart of $UNIT failed ($2). Check \`systemctl status $UNIT\`."
    return 1
  fi
  rm -f "$PENDING"
  # Wait for the listener to reconnect in the new run
  for _ in $(seq 18); do
    sleep 5
    if journal_now -o cat | grep -q 'Connected\. Awaiting'; then
      notify "$1" "Letta restarted: $2. Reconnected to Letta Cloud, version $(version).$RESCUED"
      return 0
    fi
  done
  notify ":warning:" "Letta restarted ($2) but no 'Connected' line within 90s. It may still be offline in the webapp. Version $(version).$RESCUED"
}

case "${1:-}" in
  daily)
    before=$(version)
    if npm i -g @letta-ai/letta-code@latest >> "$LOG" 2>&1; then
      after=$(version)
      if [ "$before" != "$after" ]; then
        set_pending "upgraded from $before to $after"
        notify ":arrow_up:" "Letta upgraded $before → $after. The service will restart once it's idle."
      else
        [ -f "$PENDING" ] || set_pending "version unchanged ($after)"
      fi
      clear_alert upgrade
    else
      alert_once upgrade "Letta upgrade failed (npm). See ~/.letta/maintain/maintain.log. Still on $before."
      [ -f "$PENDING" ] || set_pending "upgrade failed, still $before"
    fi
    ;;
  check)
    if is_stuck; then
      stuck_restart_allowed && { date +%s >> "$RESTARTS"; restart ":rotating_light:" "listener was stuck reconnecting for >$((STUCK_SECS / 60)) min"; }
    else
      clear_alert ratelimit
    fi
    if [ -f "$PENDING" ] && ! is_stuck; then
      if is_idle; then
        clear_alert blocked
        restart ":white_check_mark:" "daily restart while idle, $(cat "$PENDING")"
      elif [ $(( $(date +%s) - $(stat -c %Y "$PENDING") )) -gt $PENDING_WARN ]; then
        alert_once blocked "Daily Letta restart has been waiting 48h for an idle moment ($(tail -1 "$LOG" | cut -c24-)). If Letta is really idle, the idle check may be out of date."
      fi
    fi
    ;;
  status)
    last=$(journal_now -o cat | grep -E 'Reconnecting \(attempt|Connected\. Awaiting' | tail -1)
    echo "service:     $UNIT ($(systemctl is-active $UNIT)), up $(( $(uptime_secs) / 3600 ))h"
    echo "version:     $(version)"
    echo "listener:    ${last:-no marker yet}"
    echo "stuck:       $(is_stuck && echo YES || echo no)"
    echo "idle:        $(is_idle && echo yes || echo no)"
    echo "pending:     $(cat "$PENDING" 2>/dev/null || echo none)"
    echo "other procs: $(( $(wc -l < "$CG/cgroup.procs") - $(descendants "$(main_pid)" | wc -l) )) in $UNIT cgroup outside letta's own tree"
    echo "slack:       $([ -n "${SLACK_BOT_TOKEN:-}" ] && echo configured || echo NOT configured)"
    echo "log:         $LOG"
    ;;
  test)
    notify ":wave:" "Test message from letta-maintain.sh. Notifications are working."
    ;;
  *) echo "usage: $0 daily|check|status|test" >&2; exit 2 ;;
esac
