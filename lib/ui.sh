#!/usr/bin/env bash
# lib/ui.sh — the "wow" terminal UI for the MCR Server OS installer.
# Pure shell + tput only. No external UI dependencies.
# Respects NO_COLOR, non-tty output and the --plain flag (MCR_PLAIN=1).
#
# This file is meant to be sourced, not executed.

# ---------------------------------------------------------------------------
# Capability detection
# ---------------------------------------------------------------------------
# MCR_PLAIN may be pre-set by install.sh (--plain). NO_COLOR disables colour.
ui_init() {
  UI_COLOR=1
  UI_UNICODE=1

  # No TTY on stdout -> plain, no spinners, no cursor tricks.
  # MCR_FORCE_TTY=1 forces TTY behaviour even when piped (used to capture a
  # colourised demo of the UI for documentation/screenshots).
  if [ "${MCR_FORCE_TTY:-0}" = "1" ]; then
    UI_TTY=1
  elif [ ! -t 1 ]; then
    UI_TTY=0
  else
    UI_TTY=1
  fi

  if [ "${MCR_PLAIN:-0}" = "1" ] || [ -n "${NO_COLOR:-}" ] || [ "$UI_TTY" = "0" ]; then
    UI_COLOR=0
  fi

  # Unicode: assume yes unless plain mode or a non-UTF locale.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) : ;;
    "") : ;;  # unknown; be optimistic
    *) UI_UNICODE=0 ;;
  esac
  if [ "${MCR_PLAIN:-0}" = "1" ]; then UI_UNICODE=0; fi

  # Colour palette via tput when colour is enabled and tput exists.
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GREY=""
  if [ "$UI_COLOR" = "1" ] && command -v tput >/dev/null 2>&1; then
    local ncolors
    ncolors=$(tput colors 2>/dev/null || echo 0)
    if [ "${ncolors:-0}" -ge 8 ]; then
      C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim 2>/dev/null || echo "")
      C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
      C_BLUE=$(tput setaf 4); C_MAGENTA=$(tput setaf 5); C_CYAN=$(tput setaf 6)
      if [ "${ncolors:-0}" -ge 256 ]; then
        C_GREY=$(tput setaf 245)
      else
        C_GREY=$(tput setaf 7)
      fi
    else
      UI_COLOR=0
    fi
  else
    UI_COLOR=0
  fi

  # Glyphs (unicode vs ascii fallback).
  if [ "$UI_UNICODE" = "1" ]; then
    G_OK="✓"; G_FAIL="✗"; G_DOT="•"; G_ARROW="›"
    G_TL="╭"; G_TR="╮"; G_BL="╰"; G_BR="╯"; G_H="─"; G_V="│"
    G_BAR_FULL="█"; G_BAR_EMPTY="░"
    SPIN_FRAMES='⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏'
  else
    G_OK="[OK]"; G_FAIL="[X]"; G_DOT="*"; G_ARROW=">"
    G_TL="+"; G_TR="+"; G_BL="+"; G_BR="+"; G_H="-"; G_V="|"
    G_BAR_FULL="#"; G_BAR_EMPTY="."
    SPIN_FRAMES='| / - \'
  fi

  UI_WIDTH=$(tput cols 2>/dev/null || echo 80)
  [ "${UI_WIDTH:-0}" -lt 40 ] && UI_WIDTH=80
  [ "${UI_WIDTH:-0}" -gt 100 ] && UI_WIDTH=100

  UI_STEP_NO=0
  UI_STEP_TOTAL=0
}

# c <color-var> <text...> -> colourised (or plain) string on stdout
_c() {
  local color="$1"; shift
  if [ "$UI_COLOR" = "1" ]; then
    printf '%s%s%s' "$color" "$*" "$C_RESET"
  else
    printf '%s' "$*"
  fi
}

ui_repeat() { # ui_repeat <char> <count>
  local ch="$1" n="$2" out=""
  while [ "$n" -gt 0 ]; do out="$out$ch"; n=$((n - 1)); done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
ui_banner() { # ui_banner <logo-file>
  local logo="$1"
  echo
  if [ -f "$logo" ]; then
    if [ "$UI_COLOR" = "1" ]; then
      while IFS= read -r line; do
        printf '   %s%s%s\n' "$C_CYAN$C_BOLD" "$line" "$C_RESET"
      done < "$logo"
    else
      while IFS= read -r line; do printf '   %s\n' "$line"; done < "$logo"
    fi
  else
    printf '   %s\n' "$(_c "$C_CYAN$C_BOLD" 'MCRSOFT  BY WOBOO.IO')"
  fi
  echo
  printf '   %s\n' "$(_c "$C_GREY" 'Universal MCR server provisioning  ·  https://woboo.io')"
  echo
}

# ui_rule — a horizontal divider
ui_rule() {
  printf '   %s\n' "$(_c "$C_GREY" "$(ui_repeat "$G_H" $((UI_WIDTH - 6)))")"
}

# ---------------------------------------------------------------------------
# Boxed messages
# ---------------------------------------------------------------------------
ui_box() { # ui_box <title> <line...>   (reads extra lines from args)
  local title="$1"; shift
  local inner=$((UI_WIDTH - 6))
  printf '   %s%s %s %s%s\n' "$(_c "$C_BLUE" "$G_TL")" \
    "$(_c "$C_BLUE" "$G_H")" "$(_c "$C_BOLD" "$title")" \
    "$(_c "$C_BLUE" "$(ui_repeat "$G_H" $((inner - ${#title} - 3)))")" \
    "$(_c "$C_BLUE" "$G_TR")"
  local l
  for l in "$@"; do
    printf '   %s %-*s %s\n' "$(_c "$C_BLUE" "$G_V")" "$((inner - 2))" "$l" "$(_c "$C_BLUE" "$G_V")"
  done
  printf '   %s%s%s\n' "$(_c "$C_BLUE" "$G_BL")" \
    "$(_c "$C_BLUE" "$(ui_repeat "$G_H" "$inner")")" "$(_c "$C_BLUE" "$G_BR")"
}

# ---------------------------------------------------------------------------
# Logging helpers (also mirror to the install log)
# ---------------------------------------------------------------------------
ui_log_init() { # ui_log_init <logfile>
  UI_LOGFILE="$1"
  if [ -n "${UI_LOGFILE:-}" ]; then
    mkdir -p "$(dirname "$UI_LOGFILE")" 2>/dev/null || true
    : >> "$UI_LOGFILE" 2>/dev/null || true
  fi
}
_logline() {
  [ -n "${UI_LOGFILE:-}" ] || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$UI_LOGFILE" 2>/dev/null || true
}

ui_info()  { printf '   %s %s\n' "$(_c "$C_BLUE" "$G_ARROW")" "$*"; _logline "INFO $*"; }
ui_warn()  { printf '   %s %s\n' "$(_c "$C_YELLOW" "!")" "$(_c "$C_YELLOW" "$*")"; _logline "WARN $*"; }
ui_error() { printf '   %s %s\n' "$(_c "$C_RED" "$G_FAIL")" "$(_c "$C_RED" "$*")" >&2; _logline "ERROR $*"; }
ui_note()  { printf '      %s\n' "$(_c "$C_GREY" "$*")"; _logline "NOTE $*"; }

# ---------------------------------------------------------------------------
# Steps: each step has a number, label, ✓/✗ and timing.
# ---------------------------------------------------------------------------
ui_steps_total() { UI_STEP_TOTAL="$1"; }

ui_step_begin() { # ui_step_begin <label>
  UI_STEP_NO=$((UI_STEP_NO + 1))
  UI_STEP_LABEL="$1"
  UI_STEP_START=$(date +%s)
  local tag="[$UI_STEP_NO/$UI_STEP_TOTAL]"
  printf '   %s %s %s' "$(_c "$C_MAGENTA$C_BOLD" "$tag")" "$(_c "$C_DIM" "$G_DOT")" "$UI_STEP_LABEL"
  if [ "$UI_TTY" = "1" ]; then printf '\n'; else printf '\n'; fi
  _logline "STEP-BEGIN $tag $UI_STEP_LABEL"
}

ui_step_end() { # ui_step_end <0=ok|nonzero=fail> [message]
  local rc="$1"; shift || true
  local msg="${*:-}"
  local dur=$(( $(date +%s) - ${UI_STEP_START:-$(date +%s)} ))
  local tag="[$UI_STEP_NO/$UI_STEP_TOTAL]"
  if [ "$rc" = "0" ]; then
    printf '   %s %s %s %s\n' "$(_c "$C_MAGENTA$C_BOLD" "$tag")" \
      "$(_c "$C_GREEN" "$G_OK")" "$UI_STEP_LABEL" "$(_c "$C_GREY" "(${dur}s)${msg:+ — $msg}")"
    _logline "STEP-OK $tag ${dur}s $msg"
  else
    printf '   %s %s %s %s\n' "$(_c "$C_MAGENTA$C_BOLD" "$tag")" \
      "$(_c "$C_RED" "$G_FAIL")" "$UI_STEP_LABEL" "$(_c "$C_RED" "FAILED${msg:+ — $msg}")"
    _logline "STEP-FAIL $tag ${dur}s $msg"
  fi
}

# ---------------------------------------------------------------------------
# Progress bar (indeterminate count -> fraction)
# ---------------------------------------------------------------------------
ui_progress() { # ui_progress <current> <total> [label]
  local cur="$1" total="$2" label="${3:-}"
  [ "$total" -le 0 ] && total=1
  local width=28
  local filled=$(( cur * width / total ))
  [ "$filled" -gt "$width" ] && filled="$width"
  local empty=$(( width - filled ))
  local pct=$(( cur * 100 / total ))
  local bar
  bar="$(_c "$C_CYAN" "$(ui_repeat "$G_BAR_FULL" "$filled")")$(_c "$C_GREY" "$(ui_repeat "$G_BAR_EMPTY" "$empty")")"
  if [ "$UI_TTY" = "1" ]; then
    printf '\r      %s %3d%% %s' "$bar" "$pct" "$label"
    [ "$cur" -ge "$total" ] && printf '\n'
  else
    printf '      %3d%% %s\n' "$pct" "$label"
  fi
}

# ---------------------------------------------------------------------------
# Spinner wrapping a command. ui_spin <label> <command...>
# Runs the command in background, animates, returns the command exit code.
# ---------------------------------------------------------------------------
ui_spin() {
  local label="$1"; shift
  if [ "$UI_TTY" != "1" ] || [ "$UI_COLOR" != "1" ]; then
    # No animation; just run and report.
    "$@"
    return $?
  fi
  "$@" &
  local pid=$!
  local frames=($SPIN_FRAMES)
  local i=0
  # hide cursor
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    local f="${frames[$((i % ${#frames[@]}))]}"
    printf '\r      %s %s' "$(_c "$C_CYAN" "$f")" "$label"
    i=$((i + 1))
    sleep 0.1
  done
  wait "$pid"; local rc=$?
  tput cnorm 2>/dev/null || true
  printf '\r      %s\r' "$(ui_repeat ' ' $(( ${#label} + 10 )))"
  return $rc
}

# ---------------------------------------------------------------------------
# Final summary panel
# ---------------------------------------------------------------------------
ui_summary() { # ui_summary <title> <line...>
  local title="$1"; shift
  echo
  ui_box "$title" "$@"
  echo
}

ui_confirm() { # ui_confirm <prompt>  -> returns 0 if yes
  if [ "${MCR_ASSUME_YES:-0}" = "1" ]; then return 0; fi
  if [ "$UI_TTY" != "1" ]; then return 0; fi
  local ans=""
  printf '   %s %s [y/N] ' "$(_c "$C_YELLOW" "?")" "$1"
  read -r ans || true
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
