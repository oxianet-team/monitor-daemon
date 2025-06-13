#!/bin/sh

[ "$(id -u)" -ne 0 ] && {
  echo "This script must be run as root. Use: sudo sh install-monitor.sh"
  exit 1
}

URL="https://raw.githubusercontent.com/oxianet-team/monitor-stats-deamon/refs/heads/main/monitor_daemon.pl"
DEST="/usr/local/bin/monitor_daemon.pl"

# Optional parameters passed via env or CLI
ARGS="$*"

curl -sSL "$URL" -o "$DEST" || {
  echo "Failed to download script."
  exit 1
}

chmod +x "$DEST"

# Escape args for crontab (avoid issues with special chars)
ESCAPED_ARGS=$(printf "%s" "$ARGS" | sed 's/\\/\\\\/g; s/"/\\"/g')

CRON_CMD="$DEST $ESCAPED_ARGS"
CRON_JOB="*/5 * * * * $CRON_CMD"

( crontab -l 2>/dev/null | grep -F -q "$CRON_CMD" ) || (
  crontab -l 2>/dev/null; echo "$CRON_JOB"
) | crontab -
