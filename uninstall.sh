#!/usr/bin/env bash
# =============================================================================
#  MCR Server OS — uninstaller
#  Stops/disables services, restores /etc/os-release, removes branding,
#  optionally drops the DB + /opt/mcrsoft, and deregisters from the fleet.
#
#  Usage: sudo ./uninstall.sh [--purge] [--yes] [--plain] [--dry-run]
#    --purge   also drop the database and /opt/mcrsoft (DESTRUCTIVE)
#    --yes     no prompts
#    --dry-run show actions only
# =============================================================================
set -euo pipefail

ETC_DIR="/etc/mcrsoft"
APP_ROOT="/opt/mcrsoft"
SECRETS_ENV="$ETC_DIR/secrets.env"
AGENT_ENV="$ETC_DIR/agent.env"
LIB_DIR="/usr/local/lib/mcrsoft"

PURGE=0; YES=0; PLAIN=0; DRY=0
for a in "$@"; do case "$a" in
  --purge) PURGE=1 ;; --yes|-y) YES=1 ;; --plain) PLAIN=1 ;; --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown option: $a" >&2; exit 2 ;;
esac; done

[ "$PLAIN" = 1 ] && export MCR_PLAIN=1
[ "$YES" = 1 ] && export MCR_ASSUME_YES=1
if [ -r "$LIB_DIR/ui.sh" ]; then . "$LIB_DIR/ui.sh"; ui_init; else
  _c(){ shift; printf '%s' "$*"; }; ui_info(){ printf ' > %s\n' "$*"; }
  ui_warn(){ printf ' ! %s\n' "$*"; }; ui_error(){ printf ' x %s\n' "$*" >&2; }
  ui_note(){ printf '   %s\n' "$*"; }; ui_box(){ local t="$1"; shift; printf '== %s ==\n' "$t"; for l in "$@"; do printf '  %s\n' "$l"; done; }
  ui_confirm(){ [ "${MCR_ASSUME_YES:-0}" = 1 ]; }; ui_banner(){ :; }
fi

run() { if [ "$DRY" = 1 ]; then ui_note "(dry-run) $*"; else "$@" || true; fi; }
runsh() { if [ "$DRY" = 1 ]; then ui_note "(dry-run) $*"; else sh -c "$1" || true; fi; }

[ "$(id -u 2>/dev/null || echo 0)" = "0" ] || [ "$DRY" = 1 ] || { ui_error "must run as root"; exit 1; }

ui_box "MCR Server OS uninstall" \
  "Purge DB + /opt/mcrsoft: $([ "$PURGE" = 1 ] && echo YES || echo no)" \
  "Dry-run                : $([ "$DRY" = 1 ] && echo YES || echo no)"

ui_confirm "Proceed with uninstall?" || { ui_warn "cancelled"; exit 0; }

# 1. deregister from fleet (best-effort)
if [ -r "$AGENT_ENV" ] && [ "$DRY" != 1 ]; then
  url="$(sed -n 's/^MCR_FLEET_URL=//p' "$AGENT_ENV" | head -n1)"
  nid="$(sed -n 's/^MCR_NODE_ID=//p' "$AGENT_ENV" | head -n1)"
  sec="$(sed -n 's/^MCR_NODE_SECRET=//p' "$AGENT_ENV" | head -n1)"
  if [ -n "$url" ] && [ -n "$nid" ] && [ -n "$sec" ]; then
    ts="$(date +%s)"; body="{\"node_id\":\"$nid\",\"ts\":$ts,\"action\":\"deregister\"}"
    sig="$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$sec" -r 2>/dev/null | awk '{print $1}')"
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      -H "X-MCR-Node: $nid" -H "X-MCR-Timestamp: $ts" -H "X-MCR-Signature: $sig" \
      -X POST --data-binary "$body" "$url/fleet/v1/heartbeat" >/dev/null 2>&1 || true
    ui_info "fleet deregister signalled"
  fi
fi

# 2. stop + disable services/timers
run systemctl disable --now mcr-agent.timer
run systemctl disable --now mcr-agent.service
run systemctl disable --now mcr-web.service
runsh "rm -f /etc/systemd/system/mcr-agent.service /etc/systemd/system/mcr-agent.timer /etc/systemd/system/mcr-web.service"
run systemctl daemon-reload

# 3. restore os-release + remove branding
if [ -x /usr/local/bin/mcrctl ]; then
  run /usr/local/bin/mcrctl branding off
else
  if [ -f /etc/os-release.mcr.bak ]; then runsh "cp /etc/os-release.mcr.bak /etc/os-release"; fi
  runsh "rm -f /etc/mcrsoft-release /etc/profile.d/mcrsoft.sh /root/.config/neofetch/config.conf"
fi
runsh "rm -f /etc/motd"
runsh "rm -f /etc/os-release.mcr.bak"

# 4. remove binaries + libs
runsh "rm -f /usr/local/bin/mcrctl /usr/local/bin/mcr-agent /usr/local/bin/mcr-uninstall"
runsh "rm -rf '$LIB_DIR'"

# 5. optional purge
if [ "$PURGE" = 1 ]; then
  if ui_confirm "DROP the database and DELETE $APP_ROOT? This cannot be undone."; then
    if [ -r "$SECRETS_ENV" ]; then
      db="$(sed -n 's/^MCR_DB_NAME=//p' "$SECRETS_ENV" | head -n1)"
      usr="$(sed -n 's/^MCR_DB_USER=//p' "$SECRETS_ENV" | head -n1)"
      if [ "$DRY" = 1 ]; then ui_note "(dry-run) DROP DATABASE $db; DROP USER $usr"
      else mysql <<SQL || true
DROP DATABASE IF EXISTS \`$db\`;
DROP USER IF EXISTS '$usr'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
      fi
    fi
    runsh "rm -rf '$APP_ROOT'"
    ui_info "database + app directory removed"
  else
    ui_note "purge skipped; data kept"
  fi
fi

# 6. remove config (secrets last)
runsh "rm -rf '$ETC_DIR'"
ui_info "MCR Server OS removed. The underlying distro is untouched."
ui_note "Installed packages (nginx, php, mariadb...) were left in place on purpose."
