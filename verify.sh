#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify.sh — checks that the Metis card, driver, SDK and tests all work,
# then writes a PASS/WARN/FAIL report to reports/.
#
# Exit code: 0 = all pass, 2 = pass with warnings, 1 = at least one failure.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$REPO_ROOT/config.env"

usage() {
  cat <<EOF
Usage: ./verify.sh [options]
  --no-inference   Skip the inference smoke test
  --per-device     Also run a short inference on each Metis device separately
  --devices N      Expected number of Metis devices (default: $EXPECTED_DEVICES)
  --sdk-dir DIR    SDK location (default: $SDK_DIR)
  --frames N       Frames for the inference test (default: $TEST_FRAMES)
  -h, --help       Show this help
EOF
}

NO_INFERENCE=0 PER_DEVICE=0
while (($#)); do
  case $1 in
    --no-inference) NO_INFERENCE=1 ;;
    --per-device) PER_DEVICE=1 ;;
    --devices) EXPECTED_DEVICES=$2; shift ;;
    --sdk-dir) SDK_DIR=$2; shift ;;
    --frames) TEST_FRAMES=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$REPO_ROOT/logs"
REPORT_DIR="$REPO_ROOT/reports"
mkdir -p "$LOG_DIR" "$REPORT_DIR"
LOG_FILE="$LOG_DIR/verify-$TS.log"
REPORT="$REPORT_DIR/report-$TS.txt"
: >"$LOG_FILE"

# shellcheck source=lib/ui.sh
source "$REPO_ROOT/lib/ui.sh"
# shellcheck source=lib/system.sh
source "$REPO_ROOT/lib/system.sh"

trap 'sudo_keepalive_stop' EXIT
trap 'echo; err "Interrupted"; exit 130' INT TERM

R_NAME=() R_STATUS=() R_DETAIL=()
AXDEVICE_OUT=""
INFER_HELP=""
HAVE_SUDO=0

record() {
  R_NAME+=("$1"); R_STATUS+=("$2"); R_DETAIL+=("$3")
  case $2 in
    PASS) ok "$1: $3" ;;
    WARN) warn "$1: $3" ;;
    FAIL) err "$1: $3" ;;
    SKIP) info "$1: skipped — $3" ;;
  esac
}

# ---- checks ---------------------------------------------------------------

check_pcie() {
  local n addrs
  n=$(metis_pci_count)
  addrs=$(metis_pci_addrs | paste -sd' ')
  if ((n == EXPECTED_DEVICES)); then record "PCIe detection" PASS "$n/$EXPECTED_DEVICES Metis AIPUs ($addrs)"
  elif ((n > 0)); then record "PCIe detection" FAIL "$n/$EXPECTED_DEVICES Metis AIPUs ($addrs)"
  else record "PCIe detection" FAIL "no vendor 1f9d device on PCIe"; fi
}

check_pcie_link() {
  if ((!HAVE_SUDO)); then record "PCIe link" SKIP "needs sudo"; return; fi
  local a sta links=() down=0
  while read -r a; do
    [[ -z $a ]] && continue
    sta=$(sudo -n lspci -vv -s "$a" 2>/dev/null | grep -m1 'LnkSta:')
    log "$a $sta"
    links+=("$(grep -oE 'Speed [^,]+, Width x[0-9]+' <<<"$sta" | sed 's/Speed //; s/, Width / /')")
    grep -qi downgraded <<<"$sta" && down=$((down + 1))
  done < <(metis_pci_addrs)
  if ((${#links[@]} == 0)); then record "PCIe link" WARN "could not read link status"; return; fi
  local summary
  summary=$(printf '%s\n' "${links[@]}" | sort | uniq -c | awk '{c=$1; $1=""; printf "%s%dx%s", sep, c, $0; sep=", "}')
  if ((down > 0)); then record "PCIe link" WARN "$down link(s) downgraded — $summary"
  else record "PCIe link" PASS "$summary"; fi
}

check_secureboot() {
  case $(secure_boot_state) in
    disabled) record "Secure Boot" PASS "disabled" ;;
    legacy)   record "Secure Boot" PASS "legacy BIOS boot" ;;
    enabled)  record "Secure Boot" FAIL "ENABLED — unsigned metis module will not load" ;;
    *)        record "Secure Boot" WARN "state unknown" ;;
  esac
}

check_driver() {
  if metis_module_loaded; then
    record "Kernel driver" PASS "metis loaded (version $(modinfo -F version metis 2>/dev/null || echo '?'))"
  else
    record "Kernel driver" FAIL "metis module not loaded (sudo modprobe metis)"
  fi
}

check_dkms() {
  local st kr
  kr=$(uname -r)
  st=$(dkms status 2>/dev/null | grep -i metis || true)
  log "dkms: $st"
  if [[ -z $st ]]; then record "DKMS" FAIL "metis not registered with dkms"
  elif grep -q "$kr" <<<"$st" && grep -qi installed <<<"$st"; then record "DKMS" PASS "built+installed for $kr"
  else record "DKMS" WARN "not installed for running kernel $kr: $(head -n1 <<<"$st")"; fi
}

check_nodes() {
  local n
  n=$(metis_node_count)
  if ((n == EXPECTED_DEVICES)); then record "Device nodes" PASS "$(metis_nodes | xargs -n1 basename | paste -sd' ')"
  else record "Device nodes" FAIL "$n/$EXPECTED_DEVICES /dev/metis-* present"; fi
}

check_node_access() {
  local d bad=()
  while read -r d; do
    [[ -z $d ]] && continue
    [[ -r $d && -w $d ]] || bad+=("$(basename "$d")")
  done < <(metis_nodes)
  if ((${#bad[@]})); then record "Device access" FAIL "no rw access for $USER: ${bad[*]}"
  elif (($(metis_node_count) == 0)); then record "Device access" FAIL "no device nodes"
  else record "Device access" PASS "$USER can read/write all device nodes"; fi
}

check_groups() {
  local g db=() sess=() miss_db=()
  for g in axelera render video; do
    getent group "$g" >/dev/null || continue
    if user_in_group_db "$g"; then db+=("$g"); else miss_db+=("$g"); fi
    user_in_group_session "$g" || sess+=("$g")
  done
  if ((${#miss_db[@]})); then record "User groups" FAIL "$USER not in: ${miss_db[*]} (sudo usermod -aG <group> $USER)"
  elif ((${#sess[@]})); then record "User groups" WARN "member of ${db[*]}, but not active in this session: ${sess[*]} — log out/in"
  else record "User groups" PASS "${db[*]} (active in session)"; rm -f "$STATE_DIR/relogin_required"; fi
}

check_multidev() {
  local st
  st=$(multi_device_state)
  if ((!DISABLE_MULTI_DEVICE)); then record "multi-device svc" SKIP "DISABLE_MULTI_DEVICE=0 ($st)"; return; fi
  case $st in
    masked/inactive | not-installed/inactive | not-found/inactive) record "multi-device svc" PASS "$st" ;;
    */active)  record "multi-device svc" FAIL "$st — RUNNING, it drops PCIe links (sudo systemctl mask --now $MULTI_DEVICE_UNIT)" ;;
    *)         record "multi-device svc" WARN "$st — not masked (sudo systemctl mask $MULTI_DEVICE_UNIT)" ;;
  esac
}

check_packages() {
  local rt dk
  rt=$(dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}\n' 'axelera-runtime*' 2>/dev/null | awk '$3 ~ /^ii/ {print $1" "$2}')
  dk=$(dpkg-query -W -f='${Version} ${db:Status-Abbrev}' metis-dkms 2>/dev/null | awk '$2 ~ /^ii/ {print $1}')
  log "runtime pkgs: $rt | metis-dkms: $dk"
  if [[ -z $rt ]]; then record "Runtime packages" FAIL "no axelera-runtime package installed"; return; fi
  local detail
  detail="$(paste -sd',' <<<"$rt")${dk:+; metis-dkms $dk}"
  if ! grep -q "axelera-runtime-$SDK_VERSION" <<<"$rt"; then
    record "Runtime packages" FAIL "axelera-runtime-$SDK_VERSION missing (have: $detail)"
  elif [[ -z $dk ]]; then
    record "Runtime packages" FAIL "metis-dkms not installed ($detail)"
  elif (($(grep -c . <<<"$rt") > 1)); then
    record "Runtime packages" WARN "multiple runtimes installed: $detail"
  else
    record "Runtime packages" PASS "$detail"
  fi
}

check_repo() {
  if [[ ! -d $SDK_DIR/.git ]]; then record "SDK checkout" FAIL "$SDK_DIR is not a git checkout"; return; fi
  local d b dirty
  d=$(git -C "$SDK_DIR" describe --tags --always 2>/dev/null)
  b=$(git -C "$SDK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
  dirty=$(git -C "$SDK_DIR" status --porcelain 2>/dev/null | grep -c . || true)
  if [[ "$d $b" == *"$SDK_VERSION"* ]]; then
    local extra=""; ((dirty > 0)) && extra=", $dirty local change(s)"
    record "SDK checkout" PASS "$SDK_DIR @ $d ($b)$extra"
  else
    record "SDK checkout" WARN "$SDK_DIR @ $d ($b) — does not look like $SDK_VERSION"
  fi
}

check_venv() {
  if [[ ! -f $SDK_DIR/venv/bin/activate ]]; then record "Python venv" FAIL "missing $SDK_DIR/venv"; return; fi
  local v
  if v=$(in_venv python --version 2>&1); then record "Python venv" PASS "activates OK ($v)"
  else record "Python venv" FAIL "activation failed: $v"; fi
}

check_pip() {
  local out
  if out=$(in_venv python -m pip check 2>&1); then record "pip check" PASS "no broken requirements"
  else
    log "$out"
    record "pip check" WARN "$(grep -c . <<<"$out") issue(s): $(head -n1 <<<"$out")"
  fi
}

check_imports() {
  local m good=() bad=() mods=(numpy cv2 onnx onnxruntime onnxoptimizer torch torchvision typing_inspection yaml gi)
  local k=0
  for m in "${mods[@]}"; do
    inline_bar "$k" "${#mods[@]}" "import $m"
    if in_venv python -c "import $m" >>"$LOG_FILE" 2>&1; then good+=("$m"); else bad+=("$m"); fi
    k=$((k + 1))
  done
  clear_line
  if ((${#bad[@]})); then record "Python imports" FAIL "failed: ${bad[*]} (ok: ${#good[@]}/${#mods[@]})"
  else record "Python imports" PASS "${#good[@]}/${#mods[@]} modules import cleanly"; fi
}

check_axelera_pkgs() {
  local out n
  out=$(in_venv python -m pip list --format=freeze 2>/dev/null | grep -i '^axelera' || true)
  log "$out"
  n=$(grep -c . <<<"$out" || true)
  if ((n == 0)); then record "Axelera Python pkgs" FAIL "none installed in venv"; return; fi
  local rt
  rt=$(grep -i '^axelera[-_]runtime==' <<<"$out" | cut -d= -f3)
  record "Axelera Python pkgs" PASS "$n packages${rt:+ (axelera-runtime $rt)}"
}

check_axdevice() {
  local rc n fw clk
  AXDEVICE_OUT=$(in_venv timeout 90 axdevice 2>&1)
  rc=$?
  log "---- axdevice ----"; log "$AXDEVICE_OUT"
  if ((rc != 0)); then record "axdevice" FAIL "exit $rc: $(tail -n1 <<<"$AXDEVICE_OUT")"; return; fi
  n=$(grep -cE '^Device [0-9]+:' <<<"$AXDEVICE_OUT" || true)
  fw=$(grep -oE 'flver=[0-9.]+' <<<"$AXDEVICE_OUT" | cut -d= -f2 | sort -u | paste -sd',')
  clk=$(grep -oE 'clock=[0-9]+MHz' <<<"$AXDEVICE_OUT" | cut -d= -f2 | sort -u | paste -sd',')
  if ((n != EXPECTED_DEVICES)); then record "axdevice" FAIL "$n/$EXPECTED_DEVICES devices listed"; return; fi
  if [[ $fw == *,* ]]; then record "axdevice" WARN "$n devices, MIXED firmware: $fw"
  elif [[ -n $fw && ${fw%.*} != "${SDK_VERSION%.*}" ]]; then
    record "axdevice" WARN "$n devices, firmware $fw vs SDK $SDK_VERSION"
  else record "axdevice" PASS "$n devices, firmware ${fw:-?}, clock ${clk:-?}"; fi
}

check_opencl() {
  if ! command -v clinfo >/dev/null 2>&1; then record "OpenCL" WARN "clinfo not installed"; return; fi
  local p
  p=$(clinfo -l 2>/dev/null | grep -c 'Platform' || true)
  if ((p > 0)); then record "OpenCL" PASS "$p platform(s): $(clinfo -l 2>/dev/null | grep Platform | sed 's/.*: //' | paste -sd',')"
  else record "OpenCL" WARN "no OpenCL platforms (log out/in for render group; used for pre/post-processing)"; fi
}

check_gstreamer() {
  local out n
  out=$(in_venv gst-inspect-1.0 2>/dev/null)
  if [[ -z $out ]]; then record "GStreamer" FAIL "gst-inspect-1.0 failed in venv"; return; fi
  n=$(grep -ciE 'axelera|axinference|axtransform|axinplace|axstreamer' <<<"$out" || true)
  if ((n > 0)); then record "GStreamer" PASS "$n Axelera element(s)/plugin(s) registered"
  else record "GStreamer" WARN "no Axelera GStreamer elements found (operators not built?)"; fi
}

check_hw() {
  local src hits n il
  if ((HAVE_SUDO)); then src=$(sudo -n dmesg 2>/dev/null); else src=$(dmesg 2>/dev/null || journalctl -k -b --no-pager 2>/dev/null); fi
  hits=$(grep -iE 'mce: \[hardware error\]|machine check|traps: .*(invalid opcode|general protection)|segfault at|internal compiler error' <<<"$src" || true)
  il=$(latest_install_log "$LOG_DIR")
  if [[ -n $il ]] && grep -qE 'Illegal instruction|internal compiler error' "$il"; then
    hits+=$'\n'"install log: $(grep -m1 -oE 'Illegal instruction|internal compiler error' "$il")"
  fi
  hits=$(grep -v '^$' <<<"$hits" || true)
  n=$(grep -c . <<<"$hits" || true)
  log "---- stability hits ----"; log "$hits"
  if ((n == 0)); then record "HW stability" PASS "no MCE / invalid-opcode / segfault events since boot"
  else record "HW stability" WARN "$n crash/MCE event(s) — possible RAM/CPU instability (disable XMP, run memtest): $(head -n1 <<<"$hits" | cut -c1-90)"; fi
}

# Build inference.py arguments that this SDK version supports.
infer_args() {
  local frames=$1
  INFER_ARGS=("$TEST_MODEL" "$TEST_MEDIA")
  grep -q -- '--no-display' <<<"$INFER_HELP" && INFER_ARGS+=(--no-display)
  grep -q -- '--frames' <<<"$INFER_HELP" && INFER_ARGS+=(--frames "$frames")
  return 0
}

# run_inference LABEL OUTFILE EXTRA_ARGS... -> rc
run_inference() {
  local label=$1 out=$2
  shift 2
  log "RUN   ./inference.py ${INFER_ARGS[*]} $*"
  in_venv timeout "$INFERENCE_TIMEOUT" ./inference.py "${INFER_ARGS[@]}" "$@" >"$out" 2>&1 </dev/null &
  spin_wait $! "$label"
}

fps_of() { grep -iE 'fps' "$1" | tail -n1 | sed 's/\x1b\[[0-9;]*m//g; s/^[[:space:]]*//' | cut -c1-80; }
err_of() { grep -iE 'error|exception|traceback|failed' "$1" | tail -n1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-100; }

check_inference() {
  if ((NO_INFERENCE)); then record "Inference test" SKIP "--no-inference"; return; fi
  if [[ ! -f $SDK_DIR/$TEST_MEDIA ]]; then record "Inference test" SKIP "media $TEST_MEDIA not found (install with --media)"; return; fi
  INFER_HELP=$(in_venv ./inference.py --help 2>&1 || true)
  infer_args "$TEST_FRAMES"
  local out="$LOG_DIR/inference-$TS.log" rc start=$SECONDS
  run_inference "Inference $TEST_MODEL (first run compiles/downloads the model — can take 10–30 min)" "$out"
  rc=$?
  clear_line
  local t
  t=$(_fmt_elapsed $((SECONDS - start)))
  if ((rc == 0)); then record "Inference test" PASS "$TEST_MODEL OK in $t — $(fps_of "$out")"
  elif ((rc == 124)); then record "Inference test" FAIL "timed out after ${INFERENCE_TIMEOUT}s (log: $out)"
  else record "Inference test" FAIL "exit $rc: $(err_of "$out") (log: $out)"; fi
}

check_per_device() {
  if ((!PER_DEVICE)); then record "Per-device test" SKIP "use --per-device"; return; fi
  if ((NO_INFERENCE)); then record "Per-device test" SKIP "--no-inference"; return; fi
  [[ -n $INFER_HELP ]] || INFER_HELP=$(in_venv ./inference.py --help 2>&1 || true)
  if ! grep -q -- '--devices' <<<"$INFER_HELP"; then record "Per-device test" SKIP "inference.py has no --devices option"; return; fi
  infer_args "$PER_DEVICE_FRAMES"
  local d name out rc
  while read -r d; do
    [[ -z $d ]] && continue
    name=$(basename "$d")
    out="$LOG_DIR/inference-$TS-$name.log"
    run_inference "Inference on $name" "$out" --devices "$name"
    rc=$?
    clear_line
    if ((rc == 0)); then record "Device $name" PASS "$(fps_of "$out")"
    else record "Device $name" FAIL "exit $rc: $(err_of "$out")"; fi
  done < <(metis_nodes)
}

# ---- run -------------------------------------------------------------------
CHECKS=(pcie pcie_link secureboot driver dkms nodes node_access groups multidev
  packages repo venv pip imports axelera_pkgs axdevice opencl gstreamer hw
  inference per_device)

banner "Axelera Metis / Voyager SDK $SDK_VERSION verification   ($(hostname), $(date '+%F %T'))"
if sudo -n true 2>/dev/null; then HAVE_SUDO=1
elif [[ -t 0 ]] && sudo_keepalive_start; then HAVE_SUDO=1
else warn "No sudo — PCIe link and kernel log checks will be limited"; fi
echo

total=${#CHECKS[@]}
for i in "${!CHECKS[@]}"; do
  c=${CHECKS[$i]}
  inline_bar "$i" "$total" "check $((i + 1))/$total: $c"
  "check_$c"
done
clear_line

# ---- report ------------------------------------------------------------------
P=0 W=0 F=0 S=0
for st in "${R_STATUS[@]}"; do
  case $st in PASS) P=$((P + 1)) ;; WARN) W=$((W + 1)) ;; FAIL) F=$((F + 1)) ;; SKIP) S=$((S + 1)) ;; esac
done
if ((F > 0)); then VERDICT="NOT READY — $F check(s) failed"; RC=1; COL=$C_RED
elif ((W > 0)); then VERDICT="READY with $W warning(s)"; RC=2; COL=$C_YELLOW
else VERDICT="ALL CHECKS PASSED — system ready"; RC=0; COL=$C_GREEN; fi

{
  echo "Axelera Metis / Voyager SDK verification report"
  echo "================================================"
  echo "Generated : $(date '+%F %T %Z')"
  echo "Host      : $(hostname)"
  echo "OS        : $(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "Kernel    : $(uname -r)"
  echo "SDK       : $SDK_VERSION at $SDK_DIR ($(git -C "$SDK_DIR" describe --tags --always 2>/dev/null || echo n/a))"
  echo "Devices   : expected $EXPECTED_DEVICES"
  echo
  printf '%-22s %-5s %s\n' "CHECK" "STATUS" "DETAIL"
  printf '%.0s-' {1..100}; echo
  for i in "${!R_NAME[@]}"; do
    printf '%-22s %-5s %s\n' "${R_NAME[$i]}" "${R_STATUS[$i]}" "${R_DETAIL[$i]}"
  done
  echo
  echo "Summary   : $P pass, $W warn, $F fail, $S skipped"
  echo "Verdict   : $VERDICT"
  echo
  echo "---- axdevice ----"
  echo "${AXDEVICE_OUT:-n/a}"
  echo
  echo "Verify log: $LOG_FILE"
} >"$REPORT"

final_bar "Verification: $VERDICT" "$COL"
printf '\n  %-22s %-6s %s\n' "CHECK" "STATUS" "DETAIL"
for i in "${!R_NAME[@]}"; do
  case ${R_STATUS[$i]} in PASS) c=$C_GREEN ;; WARN) c=$C_YELLOW ;; FAIL) c=$C_RED ;; *) c=$C_DIM ;; esac
  printf '  %-22s %s%-6s%s %s\n' "${R_NAME[$i]}" "$c" "${R_STATUS[$i]}" "$C_RESET" "${R_DETAIL[$i]:0:$((COLS - 34))}"
done
echo
info "$P pass, $W warn, $F fail, $S skipped"
info "Report: $REPORT"
info "Log:    $LOG_FILE"
exit "$RC"
