# shellcheck shell=bash
# ---------------------------------------------------------------------------
# UI helpers: colours, logging, progress bars, spinners, sudo keep-alive.
# Expects LOG_FILE to be set by the caller (defaults to /dev/null).
# ---------------------------------------------------------------------------

LOG_FILE="${LOG_FILE:-/dev/null}"

IS_TTY=0
[[ -t 1 ]] && IS_TTY=1

if ((IS_TTY)) && [[ -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''
  C_YELLOW=''; C_BLUE=''; C_CYAN=''
fi

_locale="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
if [[ $_locale == *[Uu][Tt][Ff]-8* || $_locale == *[Uu][Tt][Ff]8* ]]; then
  G_FULL='█'; G_EMPTY='░'; G_OK='✔'; G_FAIL='✘'; G_WARN='!'; G_INFO='•'
else
  G_FULL='#'; G_EMPTY='-'; G_OK='+'; G_FAIL='x'; G_WARN='!'; G_INFO='*'
fi
unset _locale

COLS="$(tput cols 2>/dev/null || echo 100)"
[[ $COLS =~ ^[0-9]+$ ]] || COLS=100
((COLS < 60)) && COLS=60

# ---- logging ---------------------------------------------------------------
_ts() { date '+%F %T'; }
log() { printf '[%s] %s\n' "$(_ts)" "$*" >>"$LOG_FILE"; }

clear_line() { ((IS_TTY)) && printf '\r\e[2K'; return 0; }

info() { clear_line; printf '  %s%s%s %s\n' "$C_BLUE"   "$G_INFO" "$C_RESET" "$*"; log "INFO  $*"; }
ok()   { clear_line; printf '  %s%s%s %s\n' "$C_GREEN"  "$G_OK"   "$C_RESET" "$*"; log "OK    $*"; }
warn() { clear_line; printf '  %s%s%s %s\n' "$C_YELLOW" "$G_WARN" "$C_RESET" "$*"; log "WARN  $*"; }
err()  { clear_line; printf '  %s%s%s %s\n' "$C_RED"    "$G_FAIL" "$C_RESET" "$*"; log "ERROR $*"; }
hint() { printf '      %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; log "HINT  $*"; }

_fmt_elapsed() {
  local s=$1
  if ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

# ---- progress bars ---------------------------------------------------------
# _bar CUR TOTAL [WIDTH] -> prints a bar string like ██████░░░░
_bar() {
  local cur=$1 tot=$2 w=${3:-32} fill s e
  ((tot < 1)) && tot=1
  ((cur > tot)) && cur=$tot
  ((cur < 0)) && cur=0
  fill=$((cur * w / tot))
  printf -v s '%*s' "$fill" ''
  printf -v e '%*s' $((w - fill)) ''
  printf '%s' "${s// /$G_FULL}${e// /$G_EMPTY}"
}

# Overall stage progress line (printed permanently).
stage_header() {
  local idx=$1 tot=$2 title=$3 pct
  pct=$(((idx - 1) * 100 / tot))
  clear_line
  printf '\n%s%s%s %3d%%  %sStage %d/%d%s %s %s\n' \
    "$C_CYAN" "$(_bar $((idx - 1)) "$tot")" "$C_RESET" "$pct" \
    "$C_BOLD" "$idx" "$tot" "$C_RESET" "·" "$title"
  log "===== STAGE $idx/$tot: $title ====="
}

final_bar() {
  local title=$1 colour=${2:-$C_GREEN}
  clear_line
  printf '\n%s%s%s 100%%  %s%s%s\n' "$colour" "$(_bar 1 1)" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
}

# Transient inner bar on the current line (TTY only).
inline_bar() {
  ((IS_TTY)) || return 0
  local cur=$1 tot=$2 label=$3 pct max
  ((tot < 1)) && tot=1
  pct=$((cur * 100 / tot))
  max=$((COLS - 42))
  printf '\r\e[2K    %s%s%s %3d%% %s' "$C_CYAN" "$(_bar "$cur" "$tot" 24)" "$C_RESET" "$pct" "${label:0:$max}"
}

# spin_wait PID LABEL -> waits for PID with a spinner, returns its exit code.
spin_wait() {
  local pid=$1 label=$2 start=$SECONDS i=0 f='|/-\' max
  max=$((COLS - 24))
  while kill -0 "$pid" 2>/dev/null; do
    if ((IS_TTY)); then
      printf '\r\e[2K    %s%s%s %s %s(%s)%s' "$C_CYAN" "${f:i++%4:1}" "$C_RESET" \
        "${label:0:$max}" "$C_DIM" "$(_fmt_elapsed $((SECONDS - start)))" "$C_RESET"
    fi
    sleep 0.25
  done
  wait "$pid"
}

# _run MODE LABEL CMD...   MODE=hard (error on fail) | soft (warning on fail)
_run() {
  local mode=$1 label=$2 start=$SECONDS rc
  shift 2
  log "RUN   $label :: $*"
  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  spin_wait $! "$label"
  rc=$?
  clear_line
  if ((rc == 0)); then
    ok "$label ${C_DIM}($(_fmt_elapsed $((SECONDS - start))))${C_RESET}"
  elif [[ $mode == soft ]]; then
    warn "$label failed (exit $rc) — details in $LOG_FILE"
  else
    err "$label failed (exit $rc) — details in $LOG_FILE"
  fi
  return $rc
}
run_cmd()      { _run hard "$@"; }
run_cmd_soft() { _run soft "$@"; }

# ---- sudo keep-alive -------------------------------------------------------
SUDO_KEEPALIVE_PID=""
sudo_keepalive_start() {
  [[ -n $SUDO_KEEPALIVE_PID ]] && return 0
  sudo -v || return 1
  (
    while kill -0 "$$" 2>/dev/null; do
      sudo -n true 2>/dev/null
      sleep 45
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}
sudo_keepalive_stop() {
  if [[ -n $SUDO_KEEPALIVE_PID ]]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    SUDO_KEEPALIVE_PID=""
  fi
  return 0
}

banner() {
  local title=$1
  printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "Log: $LOG_FILE" "$C_RESET"
}
