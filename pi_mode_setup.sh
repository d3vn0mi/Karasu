#!/usr/bin/env bash
# =============================================================================
#  pi_mode_setup  |  Yatagarasu — unified mode switcher (pi-mode)
#  Author: d3vn0mi
#
#  ONE command to select the Pi's wired role and swap between them safely:
#
#     sudo pi-mode ap          AP baseline  (wlan0 AP + eth0 workstation drop)
#     sudo pi-mode bridge      stealth transparent bridge (eth0<->usb0) + wlan0 OOB
#     sudo pi-mode intercept   inline MITM (eth0<->usb0, mitmproxy) + wlan0 OOB
#     sudo pi-mode clean       NO AP, NO bridge, NO rules — stock NetworkManager
#     sudo pi-mode status      what mode is selected + what is live right now
#     sudo pi-mode install     deploy pi-mode + its boot-apply unit (run once)
#
#  WHY A SWITCHER (what it fixes):
#  The three legacy scripts are run independently and each 'down' leaves residue
#  (stale ebtables/br0/UPDROP_BRIN, ip_forward, a dhcpcd denyinterfaces line,
#  stacked 99-*-unmanaged.conf). Switching mode-to-mode without the exact right
#  'down' first therefore breaks the next mode. pi-mode removes that footgun:
#
#    * SWITCHING IS REBOOT-FIRST (worst case = one reboot, by design).
#      A mode swap writes a persistent marker (/etc/pi-mode/mode), fixes the small
#      set of PERSISTENT state (unit enablement, NM/dhcpcd/sysctl files), and
#      reboots. On the next boot 'pi-mode-apply.service' reads the marker and
#      brings the mode up FROM A CLEAN SLATE — so every RUNTIME leak (br0,
#      ebtables, UPDROP_BRIN, ip_forward, stale iptables) is gone for free.
#    * --now does a best-effort LIVE swap (no reboot) for quick iteration; it is
#      less bulletproof than a reboot for the bridge/intercept paths (iptables
#      REDIRECT rules are config-specific) — prefer a reboot for field use.
#
#  WHAT RUNS IN EACH MODE (wlan0 AP + updrop are the OOB loot plane in all but clean):
#    ap        : ap-ip, eth-ip, hostapd, dnsmasq, updrop, healthcheck (all enabled)
#    bridge    : ap-ip, hostapd, updrop enabled (wlan0 OOB); eth-ip/dnsmasq/nat OFF;
#                boot-apply runs 'pi_bridge_setup.sh up'
#    intercept : ap-ip, hostapd, updrop enabled (wlan0 OOB); eth-ip/dnsmasq/nat OFF;
#                boot-apply runs 'pi_intercept_setup.sh up' + fences updrop off the
#                corporate br0 IP (fixes the no-auth exposure on the target LAN)
#    clean     : everything disabled; wlan0/eth0/usb0 handed back to NetworkManager;
#                hostapd off => NO SSID broadcast; NM default DHCP everywhere
#
#  REQUIREMENTS: the AP baseline must have been provisioned once
#    (sudo bash pi_ap_dropbox_setup.sh setup) so the AP units + /usr/local/bin/pi-ap
#    exist. bridge/intercept additionally need the 2nd NIC (usb0) present.
#
#  !! Run from the console / wlan0 / the mgmt cable — NEVER over the wire you are
#     about to bridge, and NEVER over wlan0 if you are switching to 'clean' (that
#     tears down the AP you are connected through). A reboot switch drops all
#     sessions by definition.
#
#  Changelog:
#    v0.1  initial unified switcher: reboot-first mode swap via a marker +
#          pi-mode-apply.service; full 'clean' (stock NetworkManager) teardown that
#          also neutralises the known cross-mode residue; 'status' live detection;
#          intercept updrop-off-corp hardening. UNVALIDATED ON HARDWARE — bench-test.
# =============================================================================
set -euo pipefail

### ---- CONFIG (single source of truth for the switcher) --------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_SHARED_CONF="${PI_MODE_CONF:-/etc/pi-mode/pi-mode.conf}"
[[ -r "$_SHARED_CONF" ]] && . "$_SHARED_CONF" || true

# Canonical interface roles (edit to match the rig). These are what pi-mode uses
# for detection + teardown; the individual mode scripts keep their own CONFIG
# blocks for now (unifying them to source these is the v0.2 refactor).
WLAN_IFACE="${WLAN_IFACE:-wlan0}"        # Wi-Fi AP / OOB loot plane
WIRED_IFACE="${WIRED_IFACE:-eth0}"        # built-in wired: AP workstation / bridge+intercept server side
SECOND_IFACE="${SECOND_IFACE:-usb0}"       # 2nd NIC: bridge router side / intercept corp uplink
MGMT_IFACE="${MGMT_IFACE:-eth2}"         # optional out-of-band mgmt cable (if used by bridge/intercept)
BR="br0"
UPLOAD_PORT="${UPLOAD_PORT:-80}"          # updrop port (must match the AP/overlay config)

# Where the mode scripts live. 'install' copies them next to pi-mode so paths are
# stable regardless of where the repo sits.
AP_SCRIPT="/usr/local/bin/pi-ap"
BRIDGE_SCRIPT="/usr/local/bin/pi-bridge-setup"
INTERCEPT_SCRIPT="/usr/local/bin/pi-intercept-setup"
# Fallbacks to the repo copies if not installed yet:
[[ -x "$BRIDGE_SCRIPT" ]]    || BRIDGE_SCRIPT="${HERE}/pi_bridge_setup.sh"
[[ -x "$INTERCEPT_SCRIPT" ]] || INTERCEPT_SCRIPT="${HERE}/pi_intercept_setup.sh"

MODE_DIR="/etc/pi-mode"
MODE_FILE="${MODE_DIR}/mode"
APPLY_UNIT="/etc/systemd/system/pi-mode-apply.service"

# AP-baseline units (created by pi_ap_dropbox_setup.sh setup).
AP_WLAN_UNITS=(ap-ip.service hostapd.service updrop.service)          # wlan0 OOB plane (kept up in bridge/intercept)
AP_WIRED_UNITS=(eth-ip.service dnsmasq.service pi-ap-healthcheck.timer) # eth0-side AP services (off in bridge/intercept/clean)
NAT_UNIT="pi-ap-nat.service"

# Persistent files that cause cross-mode residue.
NM_AP="/etc/NetworkManager/conf.d/99-unmanaged-ap.conf"
NM_BRIDGE="/etc/NetworkManager/conf.d/99-bridge-unmanaged.conf"
NM_INTERCEPT="/etc/NetworkManager/conf.d/99-intercept-unmanaged.conf"
SYSCTL_FWD="/etc/sysctl.d/99-pi-ap.conf"
DHCPCD_CONF="/etc/dhcpcd.conf"
### --------------------------------------------------------------------------

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
say(){ echo "[*] $*"; }

enable_units(){  for u in "$@"; do systemctl enable "$u" >/dev/null 2>&1 || true; done; }
disable_units(){ for u in "$@"; do systemctl disable "$u" >/dev/null 2>&1 || true; done; }
start_units(){   for u in "$@"; do systemctl start "$u"  2>/dev/null || true; done; }
stop_units(){    for u in "$@"; do systemctl stop "$u"   2>/dev/null || true; done; }

nm_managed(){    # yes|no  iface...
  local state="$1"; shift
  have nmcli || return 0
  for i in "$@"; do nmcli device set "$i" managed "$state" 2>/dev/null || true; done
}

strip_dhcpcd_deny(){   # remove the bridge-added 'denyinterfaces ... br0 ...' line (fix #4)
  [[ -f "$DHCPCD_CONF" ]] || return 0
  if grep -qE "^denyinterfaces .*${BR}" "$DHCPCD_CONF" 2>/dev/null; then
    sed -i "/^denyinterfaces .*${BR}/d" "$DHCPCD_CONF"
    systemctl restart dhcpcd 2>/dev/null || true
  fi
}

# --- teardown of all RUNTIME overlay state (safe/idempotent; keeps wlan0 AP) ---
teardown_overlays(){
  say "tearing down any live bridge/intercept overlay..."
  pkill -f mitmdump 2>/dev/null || true
  # ebtables (bridge stealth) -> accept-all + flush (fix #2)
  if have ebtables; then
    ebtables -t filter -F 2>/dev/null || true
    ebtables -t filter -P INPUT  ACCEPT 2>/dev/null || true
    ebtables -t filter -P OUTPUT ACCEPT 2>/dev/null || true
    ebtables -t filter -P FORWARD ACCEPT 2>/dev/null || true
  fi
  # bridge server-side filter chain (fix #3)
  iptables -D INPUT -i "$BR" -j UPDROP_BRIN 2>/dev/null || true
  iptables -F UPDROP_BRIN 2>/dev/null || true
  iptables -X UPDROP_BRIN 2>/dev/null || true
  # bridge device + members
  ip link set "$WIRED_IFACE"  nomaster 2>/dev/null || true
  ip link set "$SECOND_IFACE" nomaster 2>/dev/null || true
  ip link set "$WIRED_IFACE"  promisc off 2>/dev/null || true
  ip link set "$SECOND_IFACE" promisc off 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  # re-enable IPv6 on former members
  for i in "$WIRED_IFACE" "$SECOND_IFACE" "$BR"; do
    sysctl -qw "net.ipv6.conf.$i.disable_ipv6=0" 2>/dev/null || true
  done
  # intercept sysctls (fix #1-residue / #5)
  sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
  sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
  # the mgmt-cable dnsmasq used by bridge/intercept
  pkill -f "dnsmasq.*dnsmasq-mgmt.conf" 2>/dev/null || true
  ip addr flush dev "$MGMT_IFACE" 2>/dev/null || true
}

# --- AP internet-sharing NAT residue (only present if 'share on' was used) -----
clear_ap_nat(){
  systemctl disable --now "$NAT_UNIT" 2>/dev/null || true
  rm -f "$SYSCTL_FWD"
  sysctl --system >/dev/null 2>&1 || true
}

reboot_or_hint(){   # $1 = human description
  if [[ "${DO_NOW:-0}" == "1" ]]; then
    echo "[OK] $1 applied live (--now). Some runtime residue may remain; reboot for a guaranteed-clean state."
  else
    echo "[OK] $1 selected. Rebooting now to apply from a clean slate (worst case = this one reboot)..."
    echo "     (pass --now instead of a reboot to attempt a live switch.)"
    sleep 1
    systemctl reboot
  fi
}

# ---------------------------------------------------------------------------
# MODE: ap
# ---------------------------------------------------------------------------
mode_ap(){
  [[ -f "$NM_AP" || -x "$AP_SCRIPT" ]] || { echo "!! AP baseline not provisioned — run: sudo bash pi_ap_dropbox_setup.sh setup" >&2; exit 1; }
  say "selecting AP mode..."
  rm -f "$NM_BRIDGE" "$NM_INTERCEPT"
  strip_dhcpcd_deny
  enable_units "${AP_WLAN_UNITS[@]}" "${AP_WIRED_UNITS[@]}"
  nm_managed no "$WLAN_IFACE" "$WIRED_IFACE"
  echo ap >"$MODE_FILE"
  if [[ "${DO_NOW:-0}" == "1" ]]; then
    teardown_overlays
    systemctl reload NetworkManager 2>/dev/null || true
    start_units "${AP_WLAN_UNITS[@]}" "${AP_WIRED_UNITS[@]}"
  fi
  reboot_or_hint "AP mode"
}

# ---------------------------------------------------------------------------
# MODE: bridge / intercept  (wlan0 AP stays up as OOB; eth0-side AP services off)
# ---------------------------------------------------------------------------
mode_overlay(){   # $1 = bridge|intercept   $2 = script
  local name="$1" script="$2"
  [[ -x "$script" ]] || { echo "!! $name script not found/executable: $script" >&2; exit 1; }
  [[ -e "/sys/class/net/$SECOND_IFACE" ]] || echo "!! note: $SECOND_IFACE not present now — $name needs it at apply time (plug the USB NIC in)."
  say "selecting $name mode (wlan0 AP kept as OOB)..."
  # keep wlan0 AP; stop the eth0-side AP services so they don't fight the bridge
  enable_units "${AP_WLAN_UNITS[@]}"
  disable_units "${AP_WIRED_UNITS[@]}"
  clear_ap_nat
  strip_dhcpcd_deny
  # drop the OTHER overlay's NM conf; keep AP's (wlan0 must stay NM-unmanaged)
  if [[ "$name" == "bridge" ]]; then rm -f "$NM_INTERCEPT"; else rm -f "$NM_BRIDGE"; fi
  echo "$name" >"$MODE_FILE"
  if [[ "${DO_NOW:-0}" == "1" ]]; then
    teardown_overlays
    stop_units "${AP_WIRED_UNITS[@]}"
    "$script" up
    [[ "$name" == "intercept" ]] && harden_updrop_offcorp
  fi
  reboot_or_hint "$name mode"
}

harden_updrop_offcorp(){   # fix #1: do not expose the no-auth updrop on the corp br0 IP
  have iptables || return 0
  iptables -C INPUT -i "$BR" -p tcp --dport "$UPLOAD_PORT" -j DROP 2>/dev/null \
    || iptables -I INPUT -i "$BR" -p tcp --dport "$UPLOAD_PORT" -j DROP
  say "updrop fenced off ${BR} (corp side): INPUT -i ${BR} tcp/${UPLOAD_PORT} DROP"
}

# ---------------------------------------------------------------------------
# MODE: clean  (no AP, no broadcast, no rules — stock NetworkManager)
# ---------------------------------------------------------------------------
mode_clean(){
  say "selecting CLEAN mode (stock NetworkManager, no AP broadcast)..."
  teardown_overlays
  # stop + DISABLE every provisioned unit so a reboot stays clean
  stop_units    "${AP_WLAN_UNITS[@]}" "${AP_WIRED_UNITS[@]}" "$NAT_UNIT"
  disable_units "${AP_WLAN_UNITS[@]}" "${AP_WIRED_UNITS[@]}" "$NAT_UNIT"
  clear_ap_nat
  # drop every unmanaged conf + the dhcpcd line + the forwarding sysctl
  rm -f "$NM_AP" "$NM_BRIDGE" "$NM_INTERCEPT"
  strip_dhcpcd_deny
  rm -f "$SYSCTL_FWD"; sysctl --system >/dev/null 2>&1 || true
  # flush leftover static IPs the oneshots pinned, then hand NICs back to NM
  for i in "$WLAN_IFACE" "$WIRED_IFACE" "$SECOND_IFACE"; do ip addr flush dev "$i" 2>/dev/null || true; done
  systemctl reload NetworkManager 2>/dev/null || true
  nm_managed yes "$WLAN_IFACE" "$WIRED_IFACE" "$SECOND_IFACE"
  echo clean >"$MODE_FILE"
  echo "[OK] clean: AP/bridge/intercept torn down; hostapd disabled (no broadcast);"
  echo "     wlan0/eth0/usb0 returned to NetworkManager (default DHCP)."
  echo "     Note: this does NOT uninstall anything — 'sudo pi-mode ap' re-arms the AP baseline."
  if [[ "${DO_NOW:-0}" != "1" ]]; then
    echo "     Rebooting for a guaranteed-stock slate..."; sleep 1; systemctl reboot
  fi
}

# ---------------------------------------------------------------------------
# status / apply / install
# ---------------------------------------------------------------------------
detect_live(){
  if [[ -e "/sys/class/net/$BR" ]]; then
    if have ebtables && ebtables -t filter -L OUTPUT 2>/dev/null | grep -q DROP; then echo bridge; return; fi
    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && pgrep -f mitmdump >/dev/null 2>&1; then echo intercept; return; fi
    echo "bridge?/intercept? (br0 up)"; return
  fi
  systemctl is-active --quiet hostapd 2>/dev/null && { echo ap; return; }
  echo clean
}

mode_status(){
  echo "selected (marker): $(cat "$MODE_FILE" 2>/dev/null || echo '(none)')"
  echo "live (detected)  : $(detect_live)"
  local ae; ae="$(systemctl is-enabled pi-mode-apply.service 2>/dev/null || true)"
  [[ -z "$ae" || "$ae" == "not-found" ]] && ae="not installed (run: sudo pi-mode install)"
  echo "boot-apply unit  : $ae"
  echo "services:"
  for u in "${AP_WLAN_UNITS[@]}" "${AP_WIRED_UNITS[@]}" "$NAT_UNIT"; do
    printf '  %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo n/a)/$(systemctl is-enabled "$u" 2>/dev/null || echo -)"
  done
  echo "bridge br0       : $(ip -br link show "$BR" 2>/dev/null || echo 'absent')"
  echo "ip_forward       : $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  echo "NM unmanaged cfg : $(ls /etc/NetworkManager/conf.d/99-*-unmanaged.conf 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ' || echo none)"
}

do_apply(){   # run at boot by pi-mode-apply.service — bring up the marked mode from a clean slate
  need_root
  local m; m="$(cat "$MODE_FILE" 2>/dev/null || echo ap)"
  say "pi-mode-apply: marker=$m"
  case "$m" in
    ap|clean) : ;;                               # unit enablement already handles these
    bridge)    [[ -x "$BRIDGE_SCRIPT" ]] && "$BRIDGE_SCRIPT" up || true ;;
    intercept) [[ -x "$INTERCEPT_SCRIPT" ]] && { "$INTERCEPT_SCRIPT" up || true; harden_updrop_offcorp; } ;;
    *) echo "!! unknown marker '$m'" >&2 ;;
  esac
}

do_install(){
  need_root
  install -d "$MODE_DIR"
  [[ -f "$MODE_FILE" ]] || echo ap >"$MODE_FILE"
  if [[ ! -f "$_SHARED_CONF" ]]; then
    if [[ -f "${HERE}/pi_mode.conf" ]]; then install -m644 "${HERE}/pi_mode.conf" "$_SHARED_CONF"
    else printf 'WLAN_IFACE="%s"\nWIRED_IFACE="%s"\nSECOND_IFACE="%s"\nMGMT_IFACE="%s"\nPI_HOSTNAME="%s"\nUPLOAD_PORT="%s"\n' \
           "$WLAN_IFACE" "$WIRED_IFACE" "$SECOND_IFACE" "$MGMT_IFACE" "${PI_HOSTNAME:-karasu}" "$UPLOAD_PORT" >"$_SHARED_CONF"; fi
    echo "    shared config -> $_SHARED_CONF"
  fi
  install -m755 "${BASH_SOURCE[0]}" /usr/local/bin/pi-mode
  [[ -f "${HERE}/pi_bridge_setup.sh" ]]    && install -m755 "${HERE}/pi_bridge_setup.sh"    /usr/local/bin/pi-bridge-setup
  [[ -f "${HERE}/pi_intercept_setup.sh" ]] && install -m755 "${HERE}/pi_intercept_setup.sh" /usr/local/bin/pi-intercept-setup
  cat >"$APPLY_UNIT" <<EOF
[Unit]
Description=pi-mode: apply the selected Yatagarasu mode at boot
After=network-pre.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pi-mode _apply

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable pi-mode-apply.service >/dev/null 2>&1 || true
  echo "[OK] pi-mode installed -> /usr/local/bin/pi-mode  (+ pi-mode-apply.service enabled)"
  echo "     switch with: sudo pi-mode ap|bridge|intercept|clean   (add --now to skip the reboot)"
}

usage(){ sed -n '4,40p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'; }

# ---- DISPATCH --------------------------------------------------------------
DO_NOW=0
args=()
for a in "$@"; do [[ "$a" == "--now" ]] && DO_NOW=1 || args+=("$a"); done
set -- "${args[@]:-help}"

case "${1:-help}" in
  ap)         need_root; mode_ap ;;
  bridge)     need_root; mode_overlay bridge    "$BRIDGE_SCRIPT" ;;
  intercept)  need_root; mode_overlay intercept "$INTERCEPT_SCRIPT" ;;
  clean)      need_root; mode_clean ;;
  status)     mode_status ;;
  install)    do_install ;;
  _apply)     do_apply ;;
  help|-h|--help) usage ;;
  *) echo "usage: $0 {ap|bridge|intercept|clean|status|install} [--now]" >&2; exit 2 ;;
esac
