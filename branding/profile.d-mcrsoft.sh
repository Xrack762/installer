# /etc/profile.d/mcrsoft.sh — shows the MCR banner once per interactive login.
# Installed by `mcrctl branding on`. Safe for all POSIX login shells.
# Only runs for interactive shells and only once per login session.
case "$-" in
  *i*) ;;
  *) return 2>/dev/null || exit 0 ;;
esac

if [ -z "${MCR_MOTD_SHOWN:-}" ] && [ -r /etc/mcrsoft/logo.txt ]; then
  export MCR_MOTD_SHOWN=1
  if [ -t 1 ]; then
    if [ -z "${NO_COLOR:-}" ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
      printf '\n%s' "$(tput setaf 6; tput bold)"
      cat /etc/mcrsoft/logo.txt
      printf '%s\n' "$(tput sgr0)"
    else
      printf '\n'; cat /etc/mcrsoft/logo.txt; printf '\n'
    fi
    printf '   MCRSOFT BY WOBOO.IO  ·  managed server  ·  type "mcrctl status"\n\n'
  fi
fi
