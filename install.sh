#!/usr/bin/env bash
# Install / update letta-server-ops on this machine. Safe to re-run.
#   ./install.sh [--env-name NAME] [--channels LIST] [--dry-run] [--force-unit]
# Never restarts a running letta-server (that would kill jobs in its cgroup).
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
ENV_NAME=$(hostname -s)
CHANNELS=""
DRY=0
FORCE_UNIT=0
UNIT=letta-server
BIN_DIR=$HOME/.local/bin
CONF_DIR=$HOME/.config/letta-server-ops
SHARE_DIR=$HOME/.local/share/letta-server-ops

while [ $# -gt 0 ]; do
  case "$1" in
    --env-name) ENV_NAME=$2; shift 2 ;;
    --channels) CHANNELS=$2; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --force-unit) FORCE_UNIT=1; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { echo "  $*"; }
step() { echo; echo "==> $*"; }
run()  { if [ $DRY = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
fail() { echo "  ✗ $*" >&2; exit 1; }

step "Checking prerequisites"
command -v systemctl >/dev/null || fail "systemd is required"
sudo -n true 2>/dev/null || fail "passwordless sudo is required (needed to manage the service and cgroups)"
for c in curl python3 flock busctl crontab journalctl; do
  command -v $c >/dev/null || fail "missing command: $c"
done
LETTA=$(command -v letta || true)
# cron and systemd don't load nvm, so resolve the real node bin dir now
[ -n "$LETTA" ] || LETTA=$(ls -d "$HOME"/.nvm/versions/node/*/bin/letta 2>/dev/null | tail -1 || true)
[ -n "$LETTA" ] || fail "letta not found. Install it first: npm i -g @letta-ai/letta-code"
NODE_BIN=$(dirname "$LETTA")
[ -x "$NODE_BIN/node" ] && [ -x "$NODE_BIN/npm" ] || fail "node/npm not found next to $LETTA"
say "✓ letta $("$LETTA" --version 2>/dev/null | awk '{print $1}') in $NODE_BIN"
journalctl -n 1 -q >/dev/null 2>&1 || say "⚠ cannot read the journal as $USER; add yourself to the systemd-journal group"

render() {  # render <template>
  sed -e "s|@USER@|$USER|g" -e "s|@GROUP@|$(id -gn)|g" -e "s|@HOME@|$HOME|g" \
      -e "s|@NODE_BIN@|$NODE_BIN|g" -e "s|@ENV_NAME@|$ENV_NAME|g" \
      -e "s|@CHANNELS_ARG@|${CHANNELS:+ --channels $CHANNELS}|g" "$1"
}

install_root_file() {  # install_root_file <template> <dest>
  local tmp; tmp=$(mktemp)
  render "$1" > "$tmp"
  if sudo -n test -f "$2"; then
    if sudo -n cmp -s "$tmp" "$2"; then say "✓ $2 is up to date"; rm -f "$tmp"; return 1; fi
    if [ $FORCE_UNIT = 0 ]; then
      say "⚠ $2 differs from the template (kept as is; use --force-unit to replace):"
      sudo -n diff -u "$2" "$tmp" | sed 's/^/      /' || true
      rm -f "$tmp"; return 1
    fi
  fi
  run sudo -n install -D -m 644 "$tmp" "$2"; rm -f "$tmp"
  say "✓ wrote $2"
}

step "Letta systemd service ($UNIT, env name '$ENV_NAME')"
changed=0
install_root_file "$REPO/systemd/letta-server.service.in" /etc/systemd/system/$UNIT.service && changed=1
install_root_file "$REPO/systemd/override.conf.in" /etc/systemd/system/$UNIT.service.d/override.conf && changed=1
if ! sudo -n test -f /etc/letta/.env; then
  run sudo -n install -D -m 600 -o root -g root "$REPO/letta.env.example" /etc/letta/.env
  say "✓ created /etc/letta/.env from template. Fill in LETTA_API_KEY: sudo nano /etc/letta/.env"
else
  say "✓ /etc/letta/.env exists"
fi
[ $changed = 1 ] && run sudo -n systemctl daemon-reload
run sudo -n systemctl enable $UNIT >/dev/null 2>&1
if systemctl is-active -q $UNIT; then
  [ $changed = 1 ] && say "ℹ service is running; changes apply on its next restart (letta-maintain does this when idle)"
elif sudo -n grep -qE '^LETTA_API_KEY=.+' /etc/letta/.env 2>/dev/null; then
  run sudo -n systemctl start $UNIT && say "✓ started $UNIT"
else
  say "ℹ not starting $UNIT until LETTA_API_KEY is set, then: sudo systemctl start $UNIT"
fi

step "letta-maintain script"
run install -D -m 755 "$REPO/letta-maintain.sh" "$BIN_DIR/letta-maintain"
say "✓ $BIN_DIR/letta-maintain"

step "Local patches ($SHARE_DIR)"
# Replace the installed copy wholesale so patches deleted from the repo disappear too
run rm -rf -- "${SHARE_DIR:?}/lib" "${SHARE_DIR:?}/patches"
run mkdir -p "$SHARE_DIR"
run cp -r "$REPO/lib" "$REPO/patches" "$SHARE_DIR/"
say "✓ $(find "$REPO/patches" -mindepth 2 -maxdepth 2 -name patch.json | wc -l) patch(es) installed; applied by letta-maintain (run: letta-maintain patches)"

step "Configuration ($CONF_DIR/env)"
run mkdir -p "$CONF_DIR"
if [ ! -f "$CONF_DIR/env" ]; then
  run install -m 600 "$REPO/env.example" "$CONF_DIR/env"
  # migrate the Slack settings of the pre-repo setup, if any
  if [ -f "$HOME/.config/letta-notifier/env" ] && [ $DRY = 0 ]; then
    grep -E '^SLACK_(BOT_TOKEN|USER_ID)=' "$HOME/.config/letta-notifier/env" | while IFS= read -r line; do
      sed -i "s|^${line%%=*}=.*|$line|" "$CONF_DIR/env"
    done
    say "✓ migrated Slack settings from ~/.config/letta-notifier/env"
  fi
  say "✓ created $CONF_DIR/env"
fi
if [ $DRY = 0 ]; then
  # add settings introduced after this config was created
  grep -q '^LETTA_PATCHES_DISABLED=' "$CONF_DIR/env" || printf '\n# Local patches to skip, comma-separated patch ids\nLETTA_PATCHES_DISABLED=\n' >> "$CONF_DIR/env"
  sed -i -e "s|^LETTA_UNIT=.*|LETTA_UNIT=$UNIT|" -e "s|^LETTA_NODE_BIN=.*|LETTA_NODE_BIN=$NODE_BIN|" "$CONF_DIR/env"
  grep -qE '^SLACK_BOT_TOKEN=.+' "$CONF_DIR/env" || say "ℹ Slack not configured yet: see README → Configure"
fi

step "Cron jobs"
CRON="# letta-server-ops: daily upgrade 02:00 UTC; idle restart / stuck check every 15 min
0 2 * * * $BIN_DIR/letta-maintain daily
*/15 * * * * $BIN_DIR/letta-maintain check"
current=$(crontab -l 2>/dev/null | grep -vE 'letta-maintain|^# (Letta:|letta-server-ops:)' || true)
new=$(printf '%s\n%s\n' "$current" "$CRON" | sed '/./,$!d')
if [ "$(crontab -l 2>/dev/null)" = "$new" ]; then
  say "✓ crontab is up to date"
elif [ $DRY = 1 ]; then
  echo "  [dry-run] new crontab:"; echo "$new" | sed 's/^/      /'
else
  echo "$new" | crontab - && say "✓ crontab updated"
fi

echo; echo "🎉 Done. Check health with: letta-maintain status"
