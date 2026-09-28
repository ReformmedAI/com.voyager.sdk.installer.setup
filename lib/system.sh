# shellcheck shell=bash
# ---------------------------------------------------------------------------
# System helpers shared by setup.sh and verify.sh
# ---------------------------------------------------------------------------

USER="${USER:-$(id -un)}"
AXELERA_VENDOR_ID="1f9d"
MULTI_DEVICE_UNIT="axelera-multi-device.service"

# PCI addresses (domain:bus:dev.fn) of all Axelera devices.
metis_pci_addrs() { lspci -D -d "${AXELERA_VENDOR_ID}:" 2>/dev/null | awk '{print $1}'; }
metis_pci_count() { metis_pci_addrs | grep -c . || true; }

# /dev/metis-* device nodes.
metis_nodes()      { compgen -G '/dev/metis-*' | sort -V; }
metis_node_count() { metis_nodes | grep -c . || true; }

metis_module_loaded() { lsmod 2>/dev/null | awk '$1=="metis"{f=1} END{exit !f}'; }

# enabled | disabled | legacy | unknown
secure_boot_state() {
  if [[ ! -d /sys/firmware/efi ]]; then echo legacy; return; fi
  if command -v mokutil >/dev/null 2>&1; then
    local o
    o=$(mokutil --sb-state 2>&1 || true)
    case $o in
      *"SecureBoot enabled"*)  echo enabled;  return ;;
      *"SecureBoot disabled"*) echo disabled; return ;;
      *"not support"*)         echo legacy;   return ;;
    esac
  fi
  local f b
  f=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1)
  if [[ -n $f ]]; then
    b=$(od -An -t u1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
    if [[ $b == 1 ]]; then echo enabled; else echo disabled; fi
    return
  fi
  echo unknown
}

# "<is-enabled>/<is-active>" for axelera-multi-device, e.g. "masked/inactive".
# is-enabled is empty when the unit is not installed.
multi_device_state() {
  local en ac
  en=$(systemctl is-enabled "$MULTI_DEVICE_UNIT" 2>/dev/null || true)
  ac=$(systemctl is-active "$MULTI_DEVICE_UNIT" 2>/dev/null || true)
  [[ $en == not-found ]] && en=""
  printf '%s/%s' "${en:-not-installed}" "${ac:-inactive}"
}

multi_device_installed() {
  systemctl list-unit-files "$MULTI_DEVICE_UNIT" --no-legend 2>/dev/null | grep -q .
}

# Run a command inside the SDK venv, from SDK_DIR.
in_venv() {
  bash -c 'cd "$0" || exit 97
           [[ -f venv/bin/activate ]] || { echo "venv/bin/activate missing in $0" >&2; exit 98; }
           # shellcheck disable=SC1091
           source venv/bin/activate >/dev/null 2>&1 || exit 99
           exec "$@"' "$SDK_DIR" "$@"
}

# Is USER in GROUP in the group database / in this login session?
user_in_group_db()      { id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }
user_in_group_session() { id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$1"; }

# Newest install.sh log produced by setup.sh (for resumed runs).
latest_install_log() {
  local dir=$1
  compgen -G "$dir/install-sdk-*.log" | sort | tail -n1
}
