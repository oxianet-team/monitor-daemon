#!/bin/sh
[ "$(id -u)" -ne 0 ] && {
  echo "This script must be run as root. Use: sudo sh install-monitor.sh"
  exit 1
}

URL="https://raw.githubusercontent.com/oxianet-team/monitor-stats-deamon/refs/heads/main/monitor_daemon.pl"
DEST="/usr/local/bin/monitor_daemon.pl"

# Download the script
curl -sSL "$URL" -o "$DEST" || {
  echo "Failed to download script."
  exit 1
}

# Make it executable
chmod +x "$DEST"

# Add cron job if not already present
CRON_JOB="*/5 * * * * $DEST"
( crontab -l 2>/dev/null | grep -F -q "$DEST" ) || (
  crontab -l 2>/dev/null; echo "$CRON_JOB"
) | crontab -
