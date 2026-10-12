#!/usr/bin/env bash
# =============================================================================
#  pi_bridge_setup  |  Yatagarasu — transparent bridge ("bump in the wire")
#  Author: d3vn0mi
#
#  Inserts the Pi inline between a SERVER and its ROUTER as a transparent L2
#  bridge. From the router's side nothing changes: the server's own frames are
#  forwarded verbatim, so its MAC *and* IP are exactly as before — like you
#  unplugged the server and plugged it back. The Pi is muted on the router-
#  facing port, so no second identity (ARP/IPv6/mDNS/BPDU/USB-NIC MAC) ever
#  leaks toward the router.
#
#  On top of the bridge, the Pi answers ONE name to the SERVER side only —
#  http://karasu.local (the updrop file drop) — on a service IP that is fenced
#  off from the router port. Everything else the server does is business as
#  usual. The Wi-Fi AP (pi_ap_dropbox_setup.sh) keeps running in parallel as
#  the out-of-band management + loot plane; updrop (bound to ::) serves both.
#
#  MODES:
#    up            build the bridge + stealth + confined karasu service (+ mgmt NIC)
#    down          tear the bridge down (LAB ONLY — the server loses its link)
#    status        show bridge, members, stealth rules, mgmt NIC, router reachability
#    detect        sniff the server side to suggest its subnet + a free service IP
#    help
#
#  REQUIREMENTS:
#    * TWO wired NICs. On a Pi 4/5: built-in eth0 (server side) + USB3 GbE eth1
#      (router side). USB2 caps ~300 Mbps and adds jitter — a GbE link through
#      it is detectable.
#    * ebtables, iproute2. (Installed by 'up' if missing.)
#    * Assumes PASSIVE MAC monitoring on the port. If the port runs 802.1X /
#      port-security, a naive bridge gets killed — you need EAPOL pass-through
#      (not in this script yet).
#
#  !! DANGER: this goes INLINE on the server's only uplink. A Pi crash/reboot
#     drops the server's connectivity (software bridge, no hardware fail-through).
#     Bench-test the exact cabling before you put it on anything that matters.
#
#  Run:  sudo bash pi_bridge_setup.sh up     (over wlan0 / the MGMT NIC / console,
#        NEVER over the bridged wire — bringing the bridge up flaps eth0+eth1)
#
#  Changelog:
#    v0.4  correctness/stealth fixes found on first hardware bring-up:
#          * strip_member_l3 — flush IP+routes off BOTH bridge members on 'up'
#            (a member that keeps its own IP/default route makes the Pi half-ROUTE
#            and leak its MAC+IP+IPv6 out the router port).
#          * stop_ap_conflicts — stop AP-mode 'dnsmasq'/'eth-ip' on 'up' (once eth0
#            is bridged, the AP dnsmasq becomes a ROGUE DHCP on the server segment).
#          * verify_stealth — after apply_stealth, confirm the '-o RTR DROP' rule
#            actually landed; tear down + exit 3 rather than run a leaky bridge.
#          * restore_ap — 'down' now restarts eth-ip + dnsmasq (and re-enables
#            IPv6 on the members) so eth0's 192.168.160.1 + the AP baseline come
#            back WITHOUT a reboot (was: only reappeared after reboot).
#          * NM force-release: 'up' runs 'nmcli device set <nic> managed no' (a
#            reload alone leaves an active NIC managed, so NM re-leased the router
#            NIC and the Pi half-routed); 'down' hands the router NIC back to NM.
#          * NOTE: the router side must be a real switch/router port. A phone/USB
#            *tether* is single-client (one MAC, NAT) and cannot bridge a 2nd host;
#            a plain USB-ETH adapter cabled to a real router is fine. Prefer the
#            built-in eth0 for the uplink path over a USB adapter when possible.
#    v0.3  ALLOW_SERVER_PORTS: restrict what the SERVER side can reach on the Pi
#          (KARASU_IP) via an iptables INPUT filter on br0 — locally-delivered,
#          so L2 transparency is untouched. BENCH default "22 80" (manage over
#          the server side w/o a 3rd NIC); set "80" for the FIELD to hide SSH.
#    v0.2  dedicated out-of-band MGMT NIC (MGMT_IFACE/MGMT_IP), kept OUT of the
#          bridge with a static IP (default 192.168.160.1/24), optional tiny
#          dnsmasq for a mgmt laptop. Survives 'up' — your SSH home. Collision
#          guards vs the bridged subnet + the two bridge members.
#    v0.1  initial transparent-bridge mode (approach A: serve karasu.local to the
#          server, pass everything else; server MAC+IP preserved to the router)
# =============================================================================
set -euo pipefail

# --- shared identity (optional single source of truth; overrides the CONFIG below) ---
_SHARED_CONF="${PI_MODE_CONF:-/etc/pi-mode/pi-mode.conf}"
[[ -r "$_SHARED_CONF" ]] && . "$_SHARED_CONF" || true

### ---- CONFIG ---------------------------------------------------------------
BR="br0"
SRV_IFACE="${WIRED_IFACE:-eth0}"          # faces the SERVER (built-in port)
RTR_IFACE="${SECOND_IFACE:-usb0}"          # faces the ROUTER (this rig: USB uplink NIC)

# Service identity the SERVER uses to reach the Pi at http://karasu.local.
# !! PER-DEPLOYMENT, EPHEMERAL: this is NOT a fixed value. It MUST be a FREE host
#    address in whatever subnet the field router actually hands out, so the server
#    treats karasu.local as on-link. Set it fresh every engagement. It must NOT
#    collide with: the server's own IP, the gateway/router IP, the DHCP pool, any
#    live host (confirm free with 'arping -c3 <ip>' from the server side), OR the
#    MGMT subnet (if ENABLE_MGMT=1). KARASU_PREFIX must match the real netmask.
#    Run './pi_bridge_setup.sh detect' from the SERVER side to discover the subnet.
#    (detect is only reliable once the real server is on eth0 — on a bench where
#    the Pi's own AP DHCP is still feeding eth0 it will report the wrong subnet.)
# It is fenced off from RTR_IFACE, so the router never sees it.
KARASU_IP="${KARASU_IP:-192.168.0.254}" # EXAMPLE ONLY — re-set per deployment (see note above)
KARASU_PREFIX="${KARASU_PREFIX:-24}"        # the server subnet's prefix length (match the real mask)
KARASU_HOSTNAME="${PI_HOSTNAME:-karasu}"  # advertised as <name>.local on the server side (mDNS)
UPLOAD_PORT="${UPLOAD_PORT:-80}"

ENABLE_MDNS="1"           # advertise karasu.local on the bridge (server side only)

# Belt-and-suspenders: also clone the server's MAC onto the router-facing NIC.
# Not required (the bridge preserves the server's src MAC and the Pi is muted on
# RTR_IFACE anyway), but harmless. Needs SERVER_MAC or auto-learns it.
CLONE_SERVER_MAC="0"
SERVER_MAC=""             # auto-learned from SRV_IFACE if empty and cloning is on

# Fidelity switch: by default we do NOT touch the server's own multicast/mDNS
# toward the router (so its behaviour is identical to before). Set to 1 only if
# you want to also suppress the server's own :5353 toward the router side.
DROP_SERVER_MDNS_TO_ROUTER="0"

# --- Out-of-band MANAGEMENT NIC (your SSH home; kept OUT of the bridge) -------
# A THIRD wired NIC (e.g. a 2nd USB adapter) that is never enslaved to the
# bridge, so it survives 'up'. Static IP, its own subnet — reach the Pi here at
# http://MGMT_IP / ssh. MUST differ from SRV_IFACE and RTR_IFACE, and its subnet
# MUST NOT overlap the bridged (server/router) subnet or KARASU_IP.
ENABLE_MGMT="0"           # 0 = no dedicated mgmt NIC (manage over wlan0/console only)
MGMT_IFACE="${MGMT_IFACE:-eth2}"         # the 3rd NIC (NOT eth0/eth1)
MGMT_IP="${MGMT_IP:-192.168.160.1}"   # Pi's address on the mgmt net  -> ssh/http here
MGMT_PREFIX="${MGMT_PREFIX:-24}"
MGMT_DHCP="0"             # 1 = hand the mgmt laptop an address via a dedicated dnsmasq
MGMT_DHCP_START="192.168.160.50"
MGMT_DHCP_END="192.168.160.150"

# --- what the SERVER side may reach ON the Pi (KARASU_IP) ---------------------
# Space-separated TCP ports the server segment is allowed to open on the Pi.
# Everything else inbound to KARASU_IP is dropped (mDNS/5353 + ICMP kept when
# relevant). Does NOT touch pass-through traffic (that's bridged, not local).
#   BENCH / config (no 3rd NIC): "22 80"  -> you can SSH in over the server side
#   FIELD:                       "80"     -> server sees only the drop, no SSH
#   empty ""                     -> no restriction (allow all to KARASU_IP)
ALLOW_SERVER_PORTS="22 80"
### --------------------------------------------------------------------------

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
mac_of(){ cat "/sys/class/net/$1/address" 2>/dev/null; }

ensure_tools(){
  have ebtables || { echo "[*] installing ebtables..."; apt-get update -y && apt-get install -y ebtables; }
}

unmanage_nm(){   # keep NetworkManager / dhcpcd off the two wired ports
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-bridge-unmanaged.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${SRV_IFACE};interface-name:${RTR_IFACE};interface-name:${BR}$( [[ "$ENABLE_MGMT" == "1" ]] && echo ";interface-name:${MGMT_IFACE}" )
EOF
  systemctl reload NetworkManager 2>/dev/null || true
  # reload alone does NOT release an already-active device — force it, or NM keeps
  # the router NIC's lease+default route and the Pi half-routes despite the bridge.
  if have nmcli; then
    nmcli device set "$SRV_IFACE" managed no 2>/dev/null || true
    nmcli device set "$RTR_IFACE" managed no 2>/dev/null || true
  fi
  if have dhcpcd; then
    if ! grep -qE "^denyinterfaces .*${BR}" /etc/dhcpcd.conf 2>/dev/null; then
      { echo "denyinterfaces ${SRV_IFACE} ${RTR_IFACE} ${BR}$( [[ "$ENABLE_MGMT" == "1" ]] && echo " ${MGMT_IFACE}" )"; } >>/etc/dhcpcd.conf 2>/dev/null || true
      systemctl restart dhcpcd 2>/dev/null || true
    fi
  fi
}

no_ipv6(){ for i in "$@"; do sysctl -qw "net.ipv6.conf.$i.disable_ipv6=1" 2>/dev/null || true; done; }

strip_member_l3(){   # a transparent bridge member must carry NO IP/route of its own
  # Otherwise the Pi half-ROUTES (keeps a default route out the router NIC) and
  # leaks its own MAC+IP+IPv6 onto the wire. Flush both members before enslaving.
  local i
  for i in "$SRV_IFACE" "$RTR_IFACE"; do
    ip route flush dev "$i" 2>/dev/null || true
    ip addr  flush dev "$i" 2>/dev/null || true
  done
}

stop_ap_conflicts(){   # AP-mode wired services poison the bridged segment
  # eth-ip pins a static IP on eth0 (now a bridge member); the shared dnsmasq runs
  # a DHCP server that, once eth0 is bridged, offers leases onto the server/router
  # segment = a ROGUE DHCP fighting the real router. Stop them for bridge mode.
  # (wlan0 radio via hostapd/ap-ip is left alone, but note: with dnsmasq stopped,
  # wlan0 OOB has no DHCP — use a static client, the MGMT NIC, or the console.)
  local u
  for u in dnsmasq eth-ip; do
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      echo "    stopping AP-mode unit '$u' (would collide with the bridge)"
      systemctl stop "$u" 2>/dev/null || true
    fi
  done
}

verify_stealth(){   # refuse a half-applied (leaky) bridge
  local out; out="$(ebtables -t filter -L OUTPUT 2>/dev/null || true)"
  grep -q "DROP" <<<"$out" && grep -q "$RTR_IFACE" <<<"$out"
}

restore_ap(){   # undo stop_ap_conflicts on 'down' so the AP-mode baseline returns
  # Without this, eth0 comes back bare after 'down' (its 192.168.160.1 only
  # reappears on reboot, when the eth-ip oneshot re-runs). Re-run them now.
  local u
  for u in eth-ip dnsmasq; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${u}\."; then
      echo "    restoring AP-mode unit '$u'"
      systemctl restart "$u" 2>/dev/null || systemctl start "$u" 2>/dev/null || true
    fi
  done
}

detect_server(){   # best-effort: sniff the server side, suggest subnet + a free IP
  need_root
  echo "[*] Bringing ${SRV_IFACE} up (promisc, no IP) and sniffing ~8s for the server..."
  ip link set "$SRV_IFACE" up 2>/dev/null || true
  ip link set "$SRV_IFACE" promisc on 2>/dev/null || true
  if ! have tcpdump; then
    echo "!! tcpdump not installed — run: sudo apt install -y tcpdump   (or set KARASU_IP by hand)"; exit 1
  fi
  local line src net
  line="$(timeout 8 tcpdump -i "$SRV_IFACE" -nn -c 40 'ip' 2>/dev/null \
          | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -vE '^(0\.|127\.|224\.|239\.|255\.)' \
          | sort | uniq -c | sort -rn | head -n1 || true)"
  src="$(awk '{print $2}' <<<"$line")"
  if [[ -z "$src" ]]; then
    echo "   no server IPv4 seen (idle server?). Plug the server into ${SRV_IFACE} and retry, or set KARASU_IP manually."; exit 1
  fi
  net="${src%.*}"
  echo "   server looks like ${src}  ->  subnet ${net}.0/24"
  echo "   suggestion: set  KARASU_IP=\"${net}.254\"  KARASU_PREFIX=\"24\"  (verify .254 is actually free!)"
}

server_fw_clear(){   # remove our br0 INPUT filter (idempotent)
  iptables -D INPUT -i "$BR" -j UPDROP_BRIN 2>/dev/null || true
  iptables -F UPDROP_BRIN 2>/dev/null || true
  iptables -X UPDROP_BRIN 2>/dev/null || true
}

server_fw_apply(){   # restrict what the SERVER side can reach on KARASU_IP (br0)
  [[ -n "${ALLOW_SERVER_PORTS// /}" ]] || { echo "[*] ALLOW_SERVER_PORTS empty -> server side can reach ALL Pi ports on ${KARASU_IP}"; return 0; }
  have iptables || { echo "!! iptables missing — cannot restrict server-side ports; skipping" >&2; return 0; }
  echo "[*] Server-side filter on ${BR}: allow TCP [${ALLOW_SERVER_PORTS}]$( [[ "$ENABLE_MDNS" == "1" ]] && echo " + mDNS" ), drop the rest to ${KARASU_IP}..."
  server_fw_clear
  iptables -N UPDROP_BRIN
  # keep return traffic for anything the Pi itself initiated (updrop upstream, etc.)
  iptables -A UPDROP_BRIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  local port
  for port in $ALLOW_SERVER_PORTS; do
    iptables -A UPDROP_BRIN -p tcp --dport "$port" -j ACCEPT
  done
  [[ "$ENABLE_MDNS" == "1" ]] && iptables -A UPDROP_BRIN -p udp --dport 5353 -j ACCEPT
  iptables -A UPDROP_BRIN -p icmp -j ACCEPT                 # bench ping; harmless
  iptables -A UPDROP_BRIN -j DROP                           # everything else to the Pi
  iptables -I INPUT -i "$BR" -j UPDROP_BRIN                 # scoped to br0 only; wlan0/mgmt untouched
}

preflight_guard(){   # fail fast on impossible / dangerous interface choices
  if [[ "$ENABLE_MGMT" == "1" ]]; then
    [[ "$MGMT_IFACE" != "$SRV_IFACE" && "$MGMT_IFACE" != "$RTR_IFACE" ]] || {
      echo "!! MGMT_IFACE ($MGMT_IFACE) must differ from SRV_IFACE/RTR_IFACE — it is NOT bridged" >&2; exit 2; }
    [[ -e "/sys/class/net/$MGMT_IFACE" ]] || {
      echo "!! MGMT_IFACE ($MGMT_IFACE) not present. Plug the 3rd NIC in, fix MGMT_IFACE, or set ENABLE_MGMT=0" >&2; exit 2; }
    if [[ -n "$KARASU_IP" && "$MGMT_PREFIX" == "$KARASU_PREFIX" ]]; then
      local mnet="${MGMT_IP%.*}" knet="${KARASU_IP%.*}"
      [[ "$mnet" != "$knet" ]] || {
        echo "!! mgmt subnet ($MGMT_IP/$MGMT_PREFIX) overlaps the bridged subnet ($KARASU_IP/$KARASU_PREFIX)." >&2
        echo "   Put management on a DIFFERENT subnet than the server/router net." >&2; exit 2; }
    fi
  fi
}

mgmt_up(){   # bring up the out-of-band mgmt NIC with a static IP, OUTSIDE the bridge
  [[ "$ENABLE_MGMT" == "1" ]] || return 0
  echo "[*] Management NIC ${MGMT_IFACE} -> ${MGMT_IP}/${MGMT_PREFIX} (not bridged)..."
  ip link set "$MGMT_IFACE" nomaster 2>/dev/null || true
  ip addr flush dev "$MGMT_IFACE" 2>/dev/null || true
  ip link set "$MGMT_IFACE" up
  ip addr add "${MGMT_IP}/${MGMT_PREFIX}" dev "$MGMT_IFACE"
  if [[ "$MGMT_DHCP" == "1" ]] && have dnsmasq; then
    pkill -f "dnsmasq.*--conf-file=/etc/dnsmasq-mgmt.conf" 2>/dev/null || true
    cat >/etc/dnsmasq-mgmt.conf <<EOF
interface=${MGMT_IFACE}
bind-interfaces
no-resolv
dhcp-range=${MGMT_DHCP_START},${MGMT_DHCP_END},255.255.255.0,12h
dhcp-option=3
dhcp-option=6
EOF
    dnsmasq --conf-file=/etc/dnsmasq-mgmt.conf --pid-file=/run/dnsmasq-mgmt.pid
    echo "    mgmt DHCP on ${MGMT_IFACE}: ${MGMT_DHCP_START}-${MGMT_DHCP_END} (no gw/dns)"
  fi
  echo "    reach the Pi out-of-band at: ssh ...@${MGMT_IP}   /   http://${MGMT_IP}/"
}

mgmt_down(){
  [[ "$ENABLE_MGMT" == "1" ]] || return 0
  pkill -f "dnsmasq.*--conf-file=/etc/dnsmasq-mgmt.conf" 2>/dev/null || true
  ip addr flush dev "$MGMT_IFACE" 2>/dev/null || true
}

bridge_up(){
  need_root
  preflight_guard
  [[ -n "$KARASU_IP" ]] || { echo "!! set KARASU_IP (a FREE address in the server's subnet). Run: sudo $0 detect" >&2; exit 2; }
  [[ -e "/sys/class/net/$SRV_IFACE" ]] || { echo "!! $SRV_IFACE not present" >&2; exit 2; }
  [[ -e "/sys/class/net/$RTR_IFACE" ]] || { echo "!! $RTR_IFACE not present (USB NIC plugged in?)" >&2; exit 2; }
  ensure_tools
  unmanage_nm
  stop_ap_conflicts
  strip_member_l3

  echo "[*] Optional MAC clone: ${CLONE_SERVER_MAC}"
  if [[ "$CLONE_SERVER_MAC" == "1" ]]; then
    if [[ -z "$SERVER_MAC" ]]; then
      ip link set "$SRV_IFACE" up 2>/dev/null || true; ip link set "$SRV_IFACE" promisc on 2>/dev/null || true
      if have tcpdump; then
        SERVER_MAC="$(timeout 6 tcpdump -i "$SRV_IFACE" -e -nn -c 5 'ip or arp' 2>/dev/null \
                      | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -n1 || true)"
      fi
    fi
    [[ -n "$SERVER_MAC" ]] && echo "    cloning server MAC ${SERVER_MAC} onto ${RTR_IFACE}" || echo "    !! could not learn server MAC; skipping clone"
  fi

  echo "[*] Building bridge ${BR} (${SRV_IFACE}=server, ${RTR_IFACE}=router)..."
  ip link set "$SRV_IFACE" down 2>/dev/null || true
  ip link set "$RTR_IFACE" down 2>/dev/null || true
  ip link del "$BR" 2>/dev/null || true
  ip link add "$BR" type bridge
  ip link set "$BR" type bridge stp_state 0          # no STP -> no BPDUs toward a BPDU-guarded switch
  ip link set "$BR" type bridge forward_delay 0 2>/dev/null || true

  # kill IPv6 chatter from the Pi on every bridge interface
  no_ipv6 "$BR" "$SRV_IFACE" "$RTR_IFACE"

  ip link set "$SRV_IFACE" master "$BR"
  ip link set "$RTR_IFACE" master "$BR"
  ip link set "$SRV_IFACE" promisc on
  ip link set "$RTR_IFACE" promisc on
  [[ "$CLONE_SERVER_MAC" == "1" && -n "$SERVER_MAC" ]] && ip link set "$RTR_IFACE" address "$SERVER_MAC" 2>/dev/null || true

  ip link set "$SRV_IFACE" up
  ip link set "$RTR_IFACE" up
  ip link set "$BR" up

  # confined service IP: reachable from the SERVER side, fenced from the ROUTER by ebtables below
  ip addr flush dev "$BR" 2>/dev/null || true
  ip addr add "${KARASU_IP}/${KARASU_PREFIX}" dev "$BR"

  apply_stealth
  if ! verify_stealth; then
    echo "!! core stealth rule ('-o ${RTR_IFACE} -j DROP') did NOT apply — tearing down to avoid a leaky bridge" >&2
    bridge_down; exit 3
  fi
  mgmt_up
  start_service
  server_fw_apply

  echo
  echo "[OK] bridge up.  Router sees ONLY the server's MAC+IP (verify from the switch/router)."
  echo "     server reaches the drop at:  http://${KARASU_HOSTNAME}.local/   and   http://${KARASU_IP}/"
  if [[ -n "${ALLOW_SERVER_PORTS// /}" ]]; then
    echo "     server-side ports allowed on the Pi: ${ALLOW_SERVER_PORTS}$( printf %s "$ALLOW_SERVER_PORTS" | grep -qw 22 && echo "   (SSH OPEN — bench; set ALLOW_SERVER_PORTS=\"80\" for the field)" )"
  fi
  echo "     Wi-Fi stays reachable out-of-band on wlan0 (unchanged)."
  [[ "$ENABLE_MGMT" == "1" ]] && echo "     Management (survives 'up'): ssh/http on ${MGMT_IP} via ${MGMT_IFACE} (not bridged)."
  echo "     tear down (LAB ONLY, drops the server link):  sudo $0 down"
}

apply_stealth(){
  echo "[*] Applying stealth (ebtables): the Pi is mute on ${RTR_IFACE}; ${KARASU_IP} fenced off..."
  # transparent by default
  ebtables -t filter -P INPUT  ACCEPT
  ebtables -t filter -P OUTPUT ACCEPT
  ebtables -t filter -P FORWARD ACCEPT
  ebtables -t filter -F

  # 1) THE core rule: nothing the Pi itself generates may leave toward the router.
  #    Kills Pi-origin ARP, IPv6, mDNS, BPDU, the service IP, USB-NIC MAC — all of it.
  ebtables -t filter -A OUTPUT -o "$RTR_IFACE" -j DROP

  # 2) Keep the service IP off the router side even as *transit* (it's local anyway).
  ebtables -t filter -A FORWARD -o "$RTR_IFACE" -p ARP  --arp-ip-dst "$KARASU_IP" -j DROP
  ebtables -t filter -A FORWARD -o "$RTR_IFACE" -p ARP  --arp-ip-src "$KARASU_IP" -j DROP
  ebtables -t filter -A FORWARD -o "$RTR_IFACE" -p IPv4 --ip-dst   "$KARASU_IP" -j DROP
  ebtables -t filter -A FORWARD -o "$RTR_IFACE" -p IPv4 --ip-src   "$KARASU_IP" -j DROP

  # 3) belt: drop STP/BPDU toward the router (stp is already off, so this is spare)
  ebtables -t filter -A OUTPUT  -o "$RTR_IFACE" -d 01:80:c2:00:00:00/ff:ff:ff:ff:ff:f0 -j DROP

  # 4) optional: also suppress the SERVER's own mDNS toward the router (changes fidelity)
  if [[ "$DROP_SERVER_MDNS_TO_ROUTER" == "1" ]]; then
    ebtables -t filter -A FORWARD -o "$RTR_IFACE" -p IPv4 --ip-proto udp --ip-destination-port 5353 -j DROP
  fi

  # do NOT let iptables touch bridged frames — keep it pure L2
  sysctl -qw net.bridge.bridge-nf-call-iptables=0 2>/dev/null || true
  sysctl -qw net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
  sysctl -qw net.bridge.bridge-nf-call-arptables=0 2>/dev/null || true
  sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true            # pure L2: the Pi must not route
}

start_service(){
  # Avahi: advertise karasu.local on the bridge (server side). mDNS responses are
  # Pi-originated -> rule (1) already blocks their copy toward the router.
  if [[ "$ENABLE_MDNS" == "1" ]] && have apt-get; then
    apt-get install -y avahi-daemon >/dev/null 2>&1 || true
    if [[ -f /etc/avahi/avahi-daemon.conf ]]; then
      sed -i "s/^#\?host-name=.*/host-name=${KARASU_HOSTNAME}/" /etc/avahi/avahi-daemon.conf
      if grep -q '^allow-interfaces=' /etc/avahi/avahi-daemon.conf; then
        grep -q "${BR}" /etc/avahi/avahi-daemon.conf || sed -i "s/^allow-interfaces=.*/&,${BR}/" /etc/avahi/avahi-daemon.conf
      else
        sed -i "s/^\[server\]/[server]\nallow-interfaces=${BR}/" /etc/avahi/avahi-daemon.conf
      fi
      systemctl restart avahi-daemon 2>/dev/null || true
    fi
  fi
  # updrop: if the AP setup already installed it bound to :: it is ALREADY serving
  # on ${KARASU_IP} (br0). Only start a fallback instance if nothing is listening.
  if systemctl list-unit-files 2>/dev/null | grep -q '^updrop.service'; then
    systemctl is-active --quiet updrop || systemctl restart updrop 2>/dev/null || true
    echo "    updrop.service active (bound ::) -> reachable on ${KARASU_IP}:${UPLOAD_PORT}"
  elif [[ -x /usr/local/bin/updrop ]]; then
    echo "    starting fallback updrop on ${KARASU_IP}:${UPLOAD_PORT} (nohup)"
    pkill -f "/usr/local/bin/updrop" 2>/dev/null || true
    nohup /usr/local/bin/updrop -port "$UPLOAD_PORT" -dir /srv/updrop -bind :: >/var/log/updrop-bridge.log 2>&1 &
  else
    echo "    !! /usr/local/bin/updrop not found — run the AP setup first, or drop the binary in place."
  fi
}

bridge_down(){
  need_root
  echo "!! tearing down ${BR} — if the Pi is inline, the SERVER LOSES ITS LINK until re-cabled."
  ebtables -t filter -F 2>/dev/null || true
  ip link set "$SRV_IFACE" nomaster 2>/dev/null || true
  ip link set "$RTR_IFACE" nomaster 2>/dev/null || true
  ip link set "$SRV_IFACE" promisc off 2>/dev/null || true
  ip link set "$RTR_IFACE" promisc off 2>/dev/null || true
  server_fw_clear
  ip link del "$BR" 2>/dev/null || true
  # re-enable IPv6 on the former members (no_ipv6 disabled it at runtime)
  for i in "$SRV_IFACE" "$RTR_IFACE"; do sysctl -qw "net.ipv6.conf.$i.disable_ipv6=0" 2>/dev/null || true; done
  mgmt_down
  # hand the router NIC back to NM so the Pi regains its own uplink (eth0 stays
  # unmanaged — AP mode owns it via its own conf + the eth-ip oneshot below).
  rm -f /etc/NetworkManager/conf.d/99-bridge-unmanaged.conf
  systemctl reload NetworkManager 2>/dev/null || true
  have nmcli && nmcli device set "$RTR_IFACE" managed yes 2>/dev/null || true
  # revert the denyinterfaces line we appended on 'up' (was never reverted before)
  if [[ -f /etc/dhcpcd.conf ]] && grep -qE "^denyinterfaces .*${BR}" /etc/dhcpcd.conf; then
    sed -i "/^denyinterfaces .*${BR}/d" /etc/dhcpcd.conf
    systemctl restart dhcpcd 2>/dev/null || true
  fi
  sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
  restore_ap           # bring eth0's 192.168.160.1 + AP DHCP/DNS back without a reboot
  echo "[OK] bridge removed; AP-mode baseline restored (no reboot needed)."
}

bridge_status(){
  echo "== bridge =="; ip -br link show "$BR" 2>/dev/null || echo "  $BR not present"
  echo "== members =="; bridge link show 2>/dev/null | grep -E "${SRV_IFACE}|${RTR_IFACE}" || true
  echo "== stp (want 0) =="; cat "/sys/class/net/$BR/bridge/stp_state" 2>/dev/null || true
  echo "== MACs ==";
  printf '  %-6s %s\n' "$SRV_IFACE" "$(mac_of "$SRV_IFACE")"
  printf '  %-6s %s\n' "$RTR_IFACE" "$(mac_of "$RTR_IFACE")"
  printf '  %-6s %s (service %s/%s)\n' "$BR" "$(mac_of "$BR")" "$KARASU_IP" "$KARASU_PREFIX"
  echo "== ipv6 disabled? (want 1) =="
  for i in "$BR" "$SRV_IFACE" "$RTR_IFACE"; do printf '  %-6s %s\n' "$i" "$(cat /proc/sys/net/ipv6/conf/$i/disable_ipv6 2>/dev/null)"; done
  echo "== server-side filter on br0 (what the SERVER can reach on the Pi) =="
  if iptables -L UPDROP_BRIN -n >/dev/null 2>&1; then
    iptables -L UPDROP_BRIN -n --line-numbers 2>/dev/null | sed 's/^/  /'
  else echo "  (no filter — server side can reach ALL Pi ports; ALLOW_SERVER_PORTS empty)"; fi
  echo "== mgmt NIC (out-of-band, NOT bridged) =="
  if [[ "$ENABLE_MGMT" == "1" ]]; then
    printf '  %-6s %s\n' "$MGMT_IFACE" "$(ip -br addr show "$MGMT_IFACE" 2>/dev/null | awk '{$1="";print}')"
    bridge link show 2>/dev/null | grep -q "$MGMT_IFACE" && echo "  !! WARNING: $MGMT_IFACE is enslaved to a bridge - it must not be" || echo "  ok: $MGMT_IFACE is standalone (good)"
  else echo "  (ENABLE_MGMT=0)"; fi
  echo "== ebtables (router port must be fully fenced) =="; ebtables -t filter -L 2>/dev/null || true
  echo
  echo "VERIFY FROM THE ROUTER/SWITCH SIDE: the port should show ONLY the server's MAC,"
  echo "and the ARP/neighbour table should map the server's IP to the server's MAC — nothing new."
}

case "${1:-help}" in
  up)     bridge_up ;;
  down)   bridge_down ;;
  status) bridge_status ;;
  detect) detect_server ;;
  help|-h|--help) sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//' ;;
  *) echo "usage: $0 {up|down|status|detect|help}" >&2; exit 2 ;;
esac
