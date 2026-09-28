#!/usr/bin/env bash
# Log file belongs to the user, so 'sudo cmd >>log' redirects are intentional.
# shellcheck disable=SC2024
# ---------------------------------------------------------------------------
# setup.sh — end-to-end Axelera Metis PCIe + Voyager SDK installer
#
#   PCIe detection -> Secure Boot check -> base packages -> clone/checkout SDK
#   -> install.sh (deps, runtime, metis-dkms driver, venv) -> repair failed
#   Python packages -> mask axelera-multi-device -> load driver -> groups
#   -> full verification + inference test (verify.sh)
#
# Resumable: ./setup.sh --resume skips stages that already completed.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$REPO_ROOT/config.env"

usage() {
  cat <<EOF
Usage: ./setup.sh [options]

Options:
  --resume            Skip stages that completed in a previous run
  --reset             Forget previous progress and start from scratch
  --version X.Y.Z     Voyager SDK version (default: $SDK_VERSION)
  --ref REF           Exact git tag/branch to check out (overrides auto-resolve)
  --sdk-dir DIR       Where to clone the SDK (default: $SDK_DIR)
  --devices N         Expected Metis devices on PCIe (default: $EXPECTED_DEVICES)
  --jobs N            Build jobs when rebuilding failed packages (default: $BUILD_JOBS)
  --stash             If the SDK checkout has local changes, git-stash them
                      (without this the script stops instead of touching them)
  --keep-multi-device Do NOT disable axelera-multi-device.service
  --skip-verify       Do not run verify.sh at the end
  --no-inference      Pass to verify.sh: skip the inference test
  --per-device        Pass to verify.sh: also run inference on each device
  -h, --help          Show this help
EOF
}

RESUME=0 RESET=0 STASH=0 SKIP_VERIFY=0
VERIFY_ARGS=()
while (($#)); do
  case $1 in
    --resume) RESUME=1 ;;
    --reset) RESET=1 ;;
    --version) SDK_VERSION=$2; shift ;;
    --ref) SDK_REF=$2; shift ;;
    --sdk-dir) SDK_DIR=$2; shift ;;
    --devices) EXPECTED_DEVICES=$2; shift ;;
    --jobs) BUILD_JOBS=$2; shift ;;
    --stash) STASH=1 ;;
    --keep-multi-device) DISABLE_MULTI_DEVICE=0 ;;
    --skip-verify) SKIP_VERIFY=1 ;;
    --no-inference | --per-device) VERIFY_ARGS+=("$1") ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done
export SDK_VERSION SDK_REF REPO_URL SDK_DIR EXPECTED_DEVICES BUILD_JOBS \
  DISABLE_MULTI_DEVICE TEST_MODEL TEST_MEDIA TEST_FRAMES PER_DEVICE_FRAMES \
  INFERENCE_TIMEOUT STATE_DIR

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR" "$STATE_DIR"
LOG_FILE="$LOG_DIR/setup-$TS.log"
INSTALL_LOG="$LOG_DIR/install-sdk-$TS.log"
export LOG_FILE
: >"$LOG_FILE"

# shellcheck source=lib/ui.sh
source "$REPO_ROOT/lib/ui.sh"
# shellcheck source=lib/system.sh
source "$REPO_ROOT/lib/system.sh"

STATE_FILE="$STATE_DIR/state"
VENV_PY="$SDK_DIR/venv/bin/python"
WARNINGS=()
RELOGIN_REQUIRED=0

# ---- single instance + cleanup --------------------------------------------
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
  echo "Another setup.sh run is in progress (lock: $STATE_DIR/lock)." >&2
  exit 1
fi
on_exit() { sudo_keepalive_stop; }
trap on_exit EXIT
trap 'echo; err "Interrupted — rerun with ./setup.sh --resume"; exit 130' INT TERM

# ---- resume state -----------------------------------------------------------
if ((RESET)); then rm -f "$STATE_FILE"; fi
if [[ -f $STATE_FILE ]] && ! grep -qx "version=$SDK_VERSION" "$STATE_FILE"; then
  rm -f "$STATE_FILE" # state belongs to a different SDK version
fi
[[ -f $STATE_FILE ]] || echo "version=$SDK_VERSION" >"$STATE_FILE"
is_done()   { grep -qx "done:$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { is_done "$1" || echo "done:$1" >>"$STATE_FILE"; }

# ===========================================================================
# Stages. Return 0 = ok, 2 = ok with warnings (continue), anything else = stop.
# ===========================================================================

stage_preflight() {
  local rc=0 os_id os_name free_gb ram_gb

  if ((EUID == 0)); then
    err "Run as your normal user (the script calls sudo itself), not as root."
    return 1
  fi

  os_id=$(. /etc/os-release && echo "${VERSION_ID:-}")
  os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")
  case $os_id in
    22.04 | 24.04) ok "OS: $os_name" ;;
    *) warn "OS: $os_name — Voyager SDK targets Ubuntu 22.04/24.04"; rc=2 ;;
  esac
  ok "Kernel: $(uname -r) ($(uname -m))"

  if ! command -v sudo >/dev/null 2>&1; then err "sudo is not installed"; return 1; fi
  info "Authenticating sudo (kept alive for the whole run)…"
  if ! sudo_keepalive_start; then err "sudo authentication failed"; return 1; fi
  ok "sudo authenticated"

  free_gb=$(df -BG --output=avail "$HOME" | tail -n1 | tr -dc '0-9')
  if ((free_gb < MIN_DISK_GB)); then
    err "Only ${free_gb} GB free in $HOME (need ≥ ${MIN_DISK_GB} GB)"; return 1
  fi
  ok "Disk: ${free_gb} GB free in $HOME"

  ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  if ((ram_gb < MIN_RAM_GB)); then warn "RAM: ${ram_gb} GB (recommended ≥ ${MIN_RAM_GB} GB)"; rc=2
  else ok "RAM: ${ram_gb} GB"; fi

  if timeout 10 bash -c '</dev/tcp/github.com/443' 2>/dev/null; then ok "Network: github.com reachable"
  else err "Cannot reach github.com:443 — check network/proxy"; return 1; fi

  return $rc
}

stage_pcie() {
  local count addr bar_errs
  count=$(metis_pci_count)
  lspci -nn -D -d "${AXELERA_VENDOR_ID}:" >>"$LOG_FILE" 2>&1

  if ((count == 0)); then
    err "No Axelera device (vendor 1f9d) found on PCIe"
    hint "Power off, reseat the card in an x16/x4 slot, check the card's power."
    hint "BIOS: enable 'Above 4G Decoding' (and Re-Size BAR if offered), then retry."
    return 1
  fi

  while read -r addr; do
    ok "Found $addr  $(lspci -s "$addr" | cut -d' ' -f2-)"
  done < <(metis_pci_addrs)

  if ((count != EXPECTED_DEVICES)); then
    err "Found $count Metis device(s), expected $EXPECTED_DEVICES"
    hint "Use --devices $count if that is correct, otherwise check seating / BIOS PCIe bifurcation."
    return 1
  fi
  ok "$count/$EXPECTED_DEVICES Metis AIPUs detected"

  # BAR assignment failures (PCIe BAR exhaustion) for our devices.
  bar_errs=$(sudo -n dmesg 2>/dev/null | grep -iE "$(metis_pci_addrs | paste -sd'|')" |
    grep -iE 'BAR [0-9]+.*(failed|no space|can.t assign)|can.t claim' || true)
  if [[ -n $bar_errs ]]; then
    warn "Kernel reported BAR assignment problems for the Metis devices:"
    printf '%s\n' "$bar_errs" | head -n4 | sed 's/^/      /'
    hint "Enable 'Above 4G Decoding' in BIOS."
    return 2
  fi
  return 0
}

stage_secureboot() {
  case $(secure_boot_state) in
    disabled) ok "Secure Boot is disabled" ;;
    legacy)   ok "Legacy BIOS boot (no Secure Boot)" ;;
    enabled)
      err "Secure Boot is ENABLED — the unsigned metis DKMS module would be rejected."
      hint "Reboot into BIOS → Security/Boot → Secure Boot → Disabled, save,"
      hint "then run:  ./setup.sh --resume"
      return 1 ;;
    *) warn "Could not determine Secure Boot state (mokutil missing?)"; return 2 ;;
  esac
}

stage_sysdeps() {
  local pkgs=(git curl ca-certificates pciutils mokutil dkms build-essential
    "linux-headers-$(uname -r)" util-linux)
  local missing=() p k=0

  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if ((${#missing[@]} == 0)); then ok "All ${#pkgs[@]} base packages already installed"; return 0; fi

  run_cmd "apt-get update" sudo DEBIAN_FRONTEND=noninteractive apt-get update || return 1
  for p in "${missing[@]}"; do
    inline_bar "$k" "${#missing[@]}" "apt install $p"
    log "RUN   apt-get install -y $p"
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >>"$LOG_FILE" 2>&1 </dev/null; then
      clear_line
      err "Failed to install $p"
      [[ $p == linux-headers-* ]] && hint "No headers for this kernel: run 'sudo apt install linux-generic' and reboot."
      return 1
    fi
    k=$((k + 1))
  done
  inline_bar "$k" "${#missing[@]}" "done"
  clear_line
  ok "Installed ${#missing[@]} base package(s): ${missing[*]}"
}

# Prints "<kind> <name>" where kind is tag|branch.
resolve_ref() {
  local refs c kind name
  refs=$(git ls-remote --heads --tags "$REPO_URL" 2>>"$LOG_FILE" | awk '{print $2}' | sed 's/\^{}$//' | sort -u) || return 1
  local candidates=()
  if [[ -n $SDK_REF ]]; then
    candidates=("refs/tags/$SDK_REF" "refs/heads/$SDK_REF")
  else
    candidates=("refs/tags/v$SDK_VERSION" "refs/heads/release/v$SDK_VERSION"
      "refs/tags/release/v$SDK_VERSION" "refs/heads/release/$SDK_VERSION" "refs/tags/$SDK_VERSION"
      "refs/heads/release/v${SDK_VERSION%.*}")
  fi
  for c in "${candidates[@]}"; do
    if grep -Fxq "$c" <<<"$refs"; then
      case $c in refs/tags/*) kind=tag; name=${c#refs/tags/} ;; *) kind=branch; name=${c#refs/heads/} ;; esac
      echo "$kind $name"
      return 0
    fi
  done
  return 1
}

stage_repo() {
  local ref kind name remote dirty head
  if ! ref=$(resolve_ref); then
    err "No git ref found for SDK ${SDK_REF:-v$SDK_VERSION} in $REPO_URL"
    hint "List them with:  git ls-remote --tags --heads $REPO_URL | grep 1.6"
    hint "then rerun with:  ./setup.sh --ref <name>"
    return 1
  fi
  read -r kind name <<<"$ref"
  ok "Resolved SDK $SDK_VERSION → $kind '$name'"

  if [[ ! -d $SDK_DIR/.git ]]; then
    if [[ -e $SDK_DIR ]] && [[ -n $(ls -A "$SDK_DIR" 2>/dev/null) ]]; then
      err "$SDK_DIR exists but is not a git checkout — move it away first"; return 1
    fi
    run_cmd "git clone ($name) → $SDK_DIR" git clone --branch "$name" "$REPO_URL" "$SDK_DIR" || return 1
  else
    remote=$(git -C "$SDK_DIR" remote get-url origin 2>/dev/null || true)
    [[ $remote == "$REPO_URL" || $remote == "${REPO_URL%.git}" ]] ||
      warn "origin of $SDK_DIR is '$remote' (expected $REPO_URL)"

    dirty=$(git -C "$SDK_DIR" status --porcelain --untracked-files=normal | grep -v -E '^\?\? venv$' | wc -l)
    if ((dirty > 0)); then
      if ((STASH)); then
        run_cmd "git stash ($dirty local change(s))" \
          git -C "$SDK_DIR" stash push -u -m "axelera-setup backup $TS" || return 1
        ok "Local changes saved — restore later with: git -C $SDK_DIR stash pop"
      else
        err "$SDK_DIR has $dirty local change(s) (modified/untracked files)."
        hint "Commit/copy them somewhere safe, or rerun with --stash to git-stash them."
        git -C "$SDK_DIR" status --short | head -n10 | sed 's/^/        /'
        return 1
      fi
    fi

    run_cmd "git fetch" git -C "$SDK_DIR" fetch --all --tags --prune --force || return 1
    if [[ $kind == tag ]]; then
      run_cmd "git checkout tag $name" git -C "$SDK_DIR" checkout --detach "refs/tags/$name" || return 1
    else
      run_cmd "git checkout branch $name" git -C "$SDK_DIR" checkout -B "$name" "origin/$name" || return 1
    fi
  fi

  head=$(git -C "$SDK_DIR" describe --tags --always 2>/dev/null)
  echo "$kind $name" >"$STATE_DIR/sdk_ref"
  ok "SDK checkout at $SDK_DIR ($head)"
}

stage_multidev_pre() {
  if ((!DISABLE_MULTI_DEVICE)); then info "Keeping axelera-multi-device (--keep-multi-device)"; return 0; fi
  if ! multi_device_installed; then info "axelera-multi-device not installed yet — will be masked after install"; return 0; fi
  sudo systemctl disable --now "$MULTI_DEVICE_UNIT" >>"$LOG_FILE" 2>&1 || true
  ok "Stopped $MULTI_DEVICE_UNIT before install ($(multi_device_state))"
}

# Runs install.sh, parsing its "[N/M] step" lines into a progress bar.
run_install_with_bar() {
  local cur=0 tot=0 label="starting…" line
  (cd "$SDK_DIR" && ./install.sh "$@") </dev/null 2>&1 | while IFS= read -r line; do
    printf '%s\n' "$line" >>"$INSTALL_LOG"
    line=${line//$'\r'/}
    if [[ $line =~ ^[[:space:]]*\[([0-9]+)/([0-9]+)\][[:space:]]+(.+)$ ]]; then
      cur=${BASH_REMATCH[1]}; tot=${BASH_REMATCH[2]}
      local l=${BASH_REMATCH[3]}
      if [[ $l =~ ^[A-Z] && ${#l} -lt 90 ]]; then label=$l; fi
    elif [[ $line =~ ^(building|refreshing|Device|ACTION|ERROR|Installing|Downloading) ]]; then
      label=$line
    fi
    if [[ $line == WARNING:\ Failed* ]]; then clear_line; warn "${line#WARNING: }"; fi
    if ((tot > 0)); then
      inline_bar "$cur" "$tot" "[$cur/$tot] $label"
    elif ((IS_TTY)); then
      printf '\r\e[2K    … %s' "${label:0:$((COLS - 10))}"
    fi
  done
  local rc=${PIPESTATUS[0]}
  clear_line
  return "$rc"
}

stage_install() {
  local help yesflag="" rc start=$SECONDS
  local -a flags
  read -r -a flags <<<"$INSTALL_FLAGS"

  help=$(cd "$SDK_DIR" && ./install.sh --help 2>&1 || true)
  printf '%s\n' "---- install.sh --help ----" "$help" >>"$LOG_FILE"
  if grep -q -- '--YES' <<<"$help"; then yesflag=--YES
  elif grep -qE -- '(^|[[:space:],])--yes([[:space:],=]|$)' <<<"$help"; then yesflag=--yes; fi

  : >"$INSTALL_LOG"
  info "install.sh log: $INSTALL_LOG"
  if [[ -n $yesflag ]]; then
    flags+=("$yesflag")
    info "Running ./install.sh ${flags[*]}  (typically 15–45 min)"
    run_install_with_bar "${flags[@]}"
    rc=$?
  else
    warn "install.sh has no auto-yes flag — running interactively, answer any prompts below"
    (cd "$SDK_DIR" && ./install.sh "${flags[@]}") 2>&1 | tee -a "$INSTALL_LOG"
    rc=${PIPESTATUS[0]}
  fi

  if [[ ! -f $SDK_DIR/venv/bin/activate ]]; then
    err "install.sh did not create $SDK_DIR/venv (exit $rc). Last lines:"
    tail -n 20 "$INSTALL_LOG" | sed 's/^/      /'
    return 1
  fi
  if ((rc != 0)); then
    if grep -q 'Installation complete' "$INSTALL_LOG"; then
      warn "install.sh finished with unresolved issues after $(_fmt_elapsed $((SECONDS - start))) — repair stage handles them"
      return 2
    fi
    err "install.sh failed (exit $rc). Last lines:"
    tail -n 20 "$INSTALL_LOG" | sed 's/^/      /'
    return 1
  fi
  ok "install.sh completed in $(_fmt_elapsed $((SECONDS - start)))"
}

repair_pkg() {
  local spec=$1 j
  local -a jobs=("$BUILD_JOBS")
  ((BUILD_JOBS > 2)) && jobs+=(2)
  ((BUILD_JOBS > 1)) && jobs+=(1)
  for j in "${jobs[@]}"; do
    if run_cmd_soft "pip install $spec (build jobs=$j)" \
      env MAX_JOBS="$j" CMAKE_BUILD_PARALLEL_LEVEL="$j" \
      "$VENV_PY" -m pip install --disable-pip-version-check --no-deps --no-cache-dir "$spec"; then
      return 0
    fi
  done
  return 1
}

stage_repair() {
  local src rc=0 bad=0 k=0 spec
  local -a failed=()
  [[ -x $VENV_PY ]] || { err "venv python not found at $VENV_PY"; return 1; }

  src=$INSTALL_LOG
  [[ -s $src ]] || src=$(latest_install_log "$LOG_DIR")
  if [[ -z $src || ! -s $src ]]; then
    warn "No install.sh log found — skipping failed-package scan"; return 2
  fi

  mapfile -t failed < <(grep -oE 'Failed to install [A-Za-z0-9_.+-]+==[A-Za-z0-9_.+!-]+' "$src" |
    awk '{print $4}' | sort -u)

  if grep -qE 'internal compiler error|Illegal instruction|Segmentation fault' "$src"; then
    warn "Compiler/CPU crashes (ICE / Illegal instruction / segfault) seen during install"
    hint "Often RAM/CPU instability (XMP/EXPO, overclock). verify.sh checks the kernel log."
    rc=2
  fi

  if ((${#failed[@]} == 0)); then
    ok "install.sh reported no failed Python packages"
  else
    info "${#failed[@]} package(s) to repair: ${failed[*]}"
    for spec in "${failed[@]}"; do
      k=$((k + 1))
      inline_bar $((k - 1)) "${#failed[@]}" "repairing $spec"
      if ! repair_pkg "$spec"; then
        err "Could not install $spec"
        bad=$((bad + 1))
      fi
    done
  fi

  if run_cmd_soft "pip check (dependency consistency)" "$VENV_PY" -m pip check; then :; else rc=2; fi
  if ((bad > 0)); then
    warn "$bad package(s) still failing — see $LOG_FILE"
    rc=2
  fi
  return $rc
}

stage_multidev_post() {
  if ((!DISABLE_MULTI_DEVICE)); then info "Keeping axelera-multi-device (--keep-multi-device)"; return 0; fi
  if ! multi_device_installed && [[ $(multi_device_state) != masked/* ]]; then
    ok "$MULTI_DEVICE_UNIT not installed"; return 0
  fi
  sudo systemctl disable --now "$MULTI_DEVICE_UNIT" >>"$LOG_FILE" 2>&1 || true
  if ! sudo systemctl mask "$MULTI_DEVICE_UNIT" >>"$LOG_FILE" 2>&1; then
    err "Failed to mask $MULTI_DEVICE_UNIT"; return 1
  fi
  sudo systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
  ok "$MULTI_DEVICE_UNIT is $(multi_device_state) (must stay disabled on this board)"
}

stage_driver() {
  local i n ver dk
  if metis_module_loaded; then
    ok "metis kernel module already loaded"
  else
    if ! run_cmd "modprobe metis" sudo modprobe metis; then
      if sudo -n dmesg 2>/dev/null | tail -n 50 | grep -qi 'Key was rejected'; then
        hint "Module signature rejected → Secure Boot is on. Disable it in BIOS and rerun --resume."
      else
        hint "Check: dkms status ; sudo dmesg | grep -i metis"
      fi
      return 1
    fi
  fi

  for ((i = 0; i <= 20; i++)); do
    n=$(metis_node_count)
    inline_bar "$n" "$EXPECTED_DEVICES" "waiting for /dev/metis-* ($n/$EXPECTED_DEVICES)"
    ((n >= EXPECTED_DEVICES)) && break
    sleep 0.5
  done
  clear_line
  if ((n < EXPECTED_DEVICES)); then
    err "Only $n/$EXPECTED_DEVICES /dev/metis-* nodes present"
    hint "Try: sudo modprobe -r metis && sudo modprobe metis ; if still missing, reboot."
    return 1
  fi
  ok "$n device nodes: $(metis_nodes | xargs -n1 basename | paste -sd' ')"

  ver=$(modinfo -F version metis 2>/dev/null || echo '?')
  dk=$(dkms status 2>/dev/null | grep -i metis | head -n1)
  ok "metis driver version $ver${dk:+ — dkms: $dk}"
  # Make sure it loads at boot.
  if [[ ! -f /etc/modules-load.d/metis.conf ]]; then
    echo metis | sudo tee /etc/modules-load.d/metis.conf >/dev/null && ok "metis set to load at boot"
  fi
}

stage_groups() {
  local g missing_session=()
  if ! getent group axelera >/dev/null; then
    warn "Group 'axelera' does not exist (install.sh normally creates it)"
    return 2
  fi
  for g in axelera render video; do
    getent group "$g" >/dev/null || continue
    if ! user_in_group_db "$g"; then
      if sudo usermod -aG "$g" "$USER" >>"$LOG_FILE" 2>&1; then ok "Added $USER to group $g"
      else err "Could not add $USER to $g"; return 1; fi
    else
      ok "$USER is a member of $g"
    fi
    user_in_group_session "$g" || missing_session+=("$g")
  done
  if ((${#missing_session[@]})); then
    RELOGIN_REQUIRED=1
    touch "$STATE_DIR/relogin_required"
    warn "This login session does not have group(s): ${missing_session[*]} yet"
    return 2
  fi
  rm -f "$STATE_DIR/relogin_required"
  ok "Group membership active in this session"
}

stage_verify() {
  if ((SKIP_VERIFY)); then info "Skipped (--skip-verify). Run ./verify.sh later."; return 0; fi
  "$REPO_ROOT/verify.sh" "${VERIFY_ARGS[@]}"
}

# ===========================================================================
STAGES=(preflight pcie secureboot sysdeps repo multidev_pre install repair multidev_post driver groups verify)
declare -A TITLE=(
  [preflight]="Preflight (OS, sudo, disk, RAM, network)"
  [pcie]="PCIe detection (Metis AIPU)"
  [secureboot]="Secure Boot check"
  [sysdeps]="Base packages (git, dkms, kernel headers)"
  [repo]="Voyager SDK $SDK_VERSION checkout"
  [multidev_pre]="Stop axelera-multi-device (pre-install)"
  [install]="SDK install.sh (deps, runtime, driver, venv)"
  [repair]="Repair failed Python packages"
  [multidev_post]="Mask axelera-multi-device"
  [driver]="Load metis driver + device nodes"
  [groups]="User groups (axelera, render, video)"
  [verify]="Full verification + tests"
)
# Stages that are cheap / must reflect the current state: never skipped.
declare -A ALWAYS=([preflight]=1 [pcie]=1 [secureboot]=1 [multidev_post]=1 [driver]=1 [groups]=1 [verify]=1)

banner "Axelera Metis + Voyager SDK $SDK_VERSION setup   ($(hostname), $(date '+%F %T'))"
((RESUME)) && info "Resume mode: completed stages will be skipped"

total=${#STAGES[@]}
final_rc=0
for i in "${!STAGES[@]}"; do
  s=${STAGES[$i]}
  n=$((i + 1))
  if ((RESUME)) && [[ -z ${ALWAYS[$s]:-} ]] && is_done "$s"; then
    stage_header "$n" "$total" "${TITLE[$s]}  ${C_DIM}(done earlier — skipped)${C_RESET}"
    continue
  fi
  stage_header "$n" "$total" "${TITLE[$s]}"
  "stage_$s"
  rc=$?
  case $rc in
    0) mark_done "$s" ;;
    2) mark_done "$s"; WARNINGS+=("${TITLE[$s]}") ;;
    *)
      if [[ $s == verify ]]; then final_rc=1; break; fi
      final_bar "Setup stopped at stage $n/$total: ${TITLE[$s]}" "$C_RED"
      err "Fix the problem above, then continue with:  ./setup.sh --resume"
      info "Setup log: $LOG_FILE"
      exit 1 ;;
  esac
done

if ((final_rc)); then
  final_bar "Setup finished — verification found FAILURES" "$C_RED"
elif ((${#WARNINGS[@]})); then
  final_bar "Setup finished with warnings" "$C_YELLOW"
else
  final_bar "Setup finished — everything installed and verified" "$C_GREEN"
fi

for w in "${WARNINGS[@]}"; do warn "Warning in: $w"; done
if ((RELOGIN_REQUIRED)) || [[ -f $STATE_DIR/relogin_required ]]; then
  echo
  warn "${C_BOLD}ACTION REQUIRED:${C_RESET} log out and back in (or reconnect SSH) to activate group changes,"
  hint "then run:  cd $REPO_ROOT && ./verify.sh"
fi
echo
info "Activate the SDK:  cd $SDK_DIR && source venv/bin/activate"
info "Setup log:         $LOG_FILE"
[[ -s $INSTALL_LOG ]] && info "install.sh log:    $INSTALL_LOG"
exit "$final_rc"
