#!/usr/bin/env bash
# =============================================================================
#  Yatagarasu  |  pi_ap_dropbox_setup  |  Author: d3vn0mi
#  Portable Raspberry Pi Wi-Fi Access Point + wired workstation link + file-drop server.
#  (Yatagarasu — the three-legged guiding crow, a RavenSec relay. Repo: RPid-dropbox.)
#
#  MODES:
#    setup                      full provision (Wi-Fi AP, eth0 link, server, monitor)
#    ssid <NAME>                change SSID              (live, restarts hostapd)
#    pass <PASSPHRASE>          change WPA2 passphrase   (live, restarts hostapd)
#    hidden <on|off>            toggle SSID broadcast    (live, restarts hostapd)
#    channel <N>                change channel           (live, restarts hostapd)
#    ethmac <keep|random|MAC>   set eth0 MAC before plugging in (live + persists)
#    hostname <NAME>            set the Pi hostname -> <NAME>.local (mDNS)
#    share <on|off|status>      share the Pi's internet to clients (NAT via uplink)
#    restart                    restart the whole stack
#    show                       print current config (Wi-Fi + eth0 + bind + services)
#    status [hc args...]        run the health check
#
#  Dual-homed: laptops join the Wi-Fi, a workstation plugs into eth0, and both
#  reach the SAME updrop server (bound to :: = all IPv4+IPv6). Files land in one
#  place, visible to both sides. With 'share' off (default) the two client nets
#  are isolated and get NO internet — just the drop server. With 'share' on, an
#  uplink NIC's internet is NAT'd out to both client nets.
#
#  Run    : sudo bash pi_ap_dropbox_setup.sh setup
#           (keep updrop.go and pi_ap_healthcheck.sh next to it)
#           Run from the console or a Wi-Fi SSH session, NOT over eth0 — setup
#           reassigns eth0's IP and will drop an eth0 SSH session.
#
#  Changelog:
#    v0.12 client subnets moved to 192.168.150.0/24 (Wi-Fi) + 192.168.160.0/24 (eth0)
#          (old .50/.60 nets collided with another network in use)
#    v0.11 name resolution in ISOLATED mode: DHCP now hands out the Pi as DNS
#          (never as gateway) and dnsmasq answers ONLY the Pi's own name — no
#          upstream, everything else REFUSED so dual-homed clients fall through
#          to their real DNS. http://karasu/ + karasu.lan now work without
#          'share on' (LOCAL_DNS=1). 'hostname' op re-syncs dnsmasq in both modes.
#    v0.10 rebrand: product name 'Yatagarasu'; default hostname + SSID 'karasu'
#          (reach it at http://karasu/ in share mode, http://karasu.local otherwise)
#    v0.9  internet sharing: SHARE_INTERNET + UPLINK_IFACE, ip_forward + iptables
#          MASQUERADE/FORWARD via pi-ap-nat.service, 'share on|off|status' op;
#          in share mode dnsmasq hands out Pi as gateway+DNS and resolves the Pi
#          by name (karasu / karasu.<domain>) over unicast DNS (no mDNS needed)
#    v0.8  hostname + mDNS (<name>.local via Avahi on wlan0/eth0); default port 80 (portless);
#          any uplink NIC left to NetworkManager (workstation keeps its own network)
#    v0.7  eth0 MAC option: ETH_MAC keep|random|specific + 'ethmac' op (set before plugging in)
#    v0.6  dual-homed: eth0 static IP + optional DHCP for a wired workstation;
#          updrop binds :: (IPv4+IPv6); 'show' reports eth0 v4/v6 + bind
#    v0.5  regulatory domain + ieee80211d=1 (full TX power); show TX power/regdom
#    v0.4  modal setup vs live ops; installs itself as /usr/local/bin/pi-ap
#    v0.3  hidden SSID; hostapd restart-guard; non-root sandboxed user; monitor
#    v0.2  build/install the upload server binary
#    v0.1  initial
# =============================================================================
set -euo pipefail

### ---- CONFIG (used by 'setup' only) ----------------------------------------
IFACE="wlan0"
SSID="karasu"
PSK="yatagarasu"                                 # >= 8 chars (TEST cred — change before real use)
COUNTRY="CZ"                                    # ISO-3166 regulatory domain — REQUIRED (drives TX power)
CHANNEL="7"                                      # 2.4GHz: 1-13 (1/6/11 non-overlapping)
HW_MODE="g"                                      # g = 2.4GHz (a = 5GHz)
BSSID=""                                         # optional custom BSSID (empty = adapter default)
HIDDEN="0"                                        # 1 = hidden, 0 = broadcast
AP_IP="192.168.150.1"
DHCP_START="192.168.150.50"
DHCP_END="192.168.150.150"
NETMASK="255.255.255.0"

# --- hostname / mDNS (reach the Pi by name, no IP or port) ---
PI_HOSTNAME="karasu"                          # system hostname -> http://karasu.local  (mDNS)
ENABLE_MDNS="1"                                  # advertise <PI_HOSTNAME>.local on wlan0+eth0 only (never on an uplink NIC)

# --- wired workstation link (eth0) ---
ENABLE_ETH="1"                                   # 1 = configure eth0 for a wired workstation
ETH_IFACE="eth0"
ETH_MAC="keep"                                   # eth0 MAC before it hits the wire: keep | random | AA:BB:CC:DD:EE:FF
ETH_IP="192.168.160.1"                            # Pi's fixed address on the wire
ETH_DHCP="1"                                     # 1 = hand the workstation an IP (SAFE ONLY on a direct/dedicated cable)
ETH_DHCP_START="192.168.160.50"
ETH_DHCP_END="192.168.160.150"

# --- internet sharing (route clients OUT to the internet via an uplink NIC) ---
SHARE_INTERNET="0"                               # 1 = NAT wlan0+eth0 clients out through the uplink; 0 = isolated (no internet, drop server only)
UPLINK_IFACE="auto"                              # auto = the NIC that holds the default route (not wlan0/eth0); or set e.g. eth1, wlan1, usb0
UPSTREAM_DNS="1.1.1.1 8.8.8.8"                   # resolvers dnsmasq forwards to in share mode (empty = use the Pi's /etc/resolv.conf)
LOCAL_DOMAIN="lan"                               # <PI_HOSTNAME>.<LOCAL_DOMAIN> also resolves (e.g. karasu.lan)
LOCAL_DNS="1"                                    # 1 = isolated mode still serves http://<PI_HOSTNAME>/ over unicast DNS
                                                 #     (DHCP gives DNS=Pi, NO gateway; only the Pi's name answers, rest REFUSED)
                                                 # 0 = isolated clients get no DNS at all -> only IP or <name>.local (mDNS)

UPLOAD_DIR="/srv/updrop"
UPLOAD_PORT="80"                                 # 80 = reach it portless (http://karasu.local); non-root binds it via CAP_NET_BIND_SERVICE
UPLOAD_USER="updrop"
SERVER_BIND="::"                                 # :: = all IPv4+IPv6 ; 0.0.0.0 = all IPv4 ; or one address

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${HERE}/$(basename "${BASH_SOURCE[0]}")"
GO_SRC="${HERE}/updrop.go"
GO_BIN="${HERE}/updrop"

ENABLE_MONITOR="1"
HC_SRC="${HERE}/pi_ap_healthcheck.sh"
HC_INTERVAL="5min"
### --------------------------------------------------------------------------

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HC_UNIT="/etc/systemd/system/pi-ap-healthcheck.service"
NAT_UNIT="/etc/systemd/system/pi-ap-nat.service"

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root (use sudo)" >&2; exit 1; }; }
require_deployed(){ [[ -f "$HOSTAPD_CONF" ]] || { echo "!! $HOSTAPD_CONF not found — run 'setup' first" >&2; exit 1; }; }
bytelen(){ printf '%s' "$1" | wc -c; }

hconf_set(){
  local key="$1" val="$2" tmp; tmp="$(mktemp)"
  grep -v "^${key}=" "$HOSTAPD_CONF" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$HOSTAPD_CONF"; rm -f "$tmp"
}
hc_set_ssid(){
  [[ -f "$HC_UNIT" ]] || return 0
  local v="$1" tmp; tmp="$(mktemp)"
  awk -v val="$v" '/^Environment=SSID=/{print "Environment=SSID=" val; next}{print}' "$HC_UNIT" > "$tmp"
  cat "$tmp" > "$HC_UNIT"; rm -f "$tmp"
  systemctl daemon-reload
}
set_regdomain(){
  command -v raspi-config >/dev/null 2>&1 && raspi-config nonint do_wifi_country "$COUNTRY" || true
  iw reg set "$COUNTRY" 2>/dev/null || true
}
gen_random_mac(){ printf '%02x:%02x:%02x:%02x:%02x:%02x' $(( (RANDOM & 0xFC) | 0x02 )) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)); }
mac_apply(){                                     # iface  keep|random|AA:BB:CC:DD:EE:FF  — set NIC MAC (brings iface down/up)
  local iface="$1" mode="${2:-keep}" mac
  case "$mode" in
    keep|"") return 0 ;;
    random)  mac="$(gen_random_mac)" ;;
    *) [[ "$mode" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo "!! invalid MAC '$mode' (use keep|random|AA:BB:CC:DD:EE:FF)" >&2; return 1; }
       mac="$mode" ;;
  esac
  ip link set dev "$iface" down 2>/dev/null || true
  ip link set dev "$iface" address "$mac" || { echo "!! could not set MAC on $iface" >&2; return 1; }
  ip link set dev "$iface" up 2>/dev/null || true
  echo "${iface} MAC -> ${mac}"
}
set_hostname(){                                  # <name> — system hostname (+ /etc/hosts) so Avahi advertises <name>.local
  local h="$1"
  hostnamectl set-hostname "$h" 2>/dev/null || { echo "$h" >/etc/hostname; hostname "$h" 2>/dev/null || true; }
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$h/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$h" >> /etc/hosts
  fi
}
reload_hostapd(){
  if systemctl is-active --quiet hostapd; then systemctl restart hostapd; else systemctl start hostapd; fi
  sleep 1
  systemctl is-active --quiet hostapd || {
    echo "!! hostapd did NOT come up after the change — check: journalctl -u hostapd -e --no-pager" >&2
    exit 1; }
}

# ---- INTERNET SHARING (NAT) ------------------------------------------------
share_is_on(){ systemctl is-enabled --quiet pi-ap-nat.service 2>/dev/null; }
resolve_uplink(){                                # print the uplink NIC (explicit, or the default-route dev that isn't wlan0/eth0)
  if [[ "$UPLINK_IFACE" != "auto" && -n "$UPLINK_IFACE" ]]; then echo "$UPLINK_IFACE"; return 0; fi
  ip route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1)}}' \
    | grep -vxE "${IFACE}|${ETH_IFACE}" | head -n1
}
nat_apply(){                                     # enable forwarding + MASQUERADE + FORWARD rules (idempotent)
  local up; up="$(resolve_uplink)"
  [[ -n "$up" ]] || { echo "!! no uplink interface found (set UPLINK_IFACE, or check the internet NIC has a default route)" >&2; return 1; }
  sysctl -qw net.ipv4.ip_forward=1
  iptables -t nat -C POSTROUTING -o "$up" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$up" -j MASQUERADE
  local lan
  for lan in "$IFACE" "$ETH_IFACE"; do
    [[ "$lan" == "$ETH_IFACE" && "$ENABLE_ETH" != "1" ]] && continue
    iptables -C FORWARD -i "$up" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$up" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -C FORWARD -i "$lan" -o "$up" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -i "$lan" -o "$up" -j ACCEPT
  done
  echo "uplink=${up}"
}
nat_clear(){                                     # remove our NAT/FORWARD rules; drop forwarding
  local up; up="$(resolve_uplink)"
  if [[ -n "$up" ]]; then
    iptables -t nat -D POSTROUTING -o "$up" -j MASQUERADE 2>/dev/null || true
    local lan
    for lan in "$IFACE" "$ETH_IFACE"; do
      iptables -D FORWARD -i "$up" -o "$lan" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i "$lan" -o "$up" -j ACCEPT 2>/dev/null || true
    done
  fi
  sysctl -qw net.ipv4.ip_forward=0 2>/dev/null || true
}
write_sysctl_forward(){                          # 1 = persist ip_forward across reboot ; 0 = remove
  if [[ "${1:-0}" == "1" ]]; then
    echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-pi-ap.conf
  else
    rm -f /etc/sysctl.d/99-pi-ap.conf
  fi
  sysctl --system >/dev/null 2>&1 || true
}
write_nat_unit(){                                # oneshot that (re)applies NAT at boot and clears it on stop
  cat >"$NAT_UNIT" <<EOF
[Unit]
Description=pi-ap internet sharing (NAT via uplink)
After=network-online.target ap-ip.service$( [[ "$ENABLE_ETH" == "1" ]] && echo " eth-ip.service" )
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/pi-ap _natapply
ExecStop=/usr/local/bin/pi-ap _natclear

[Install]
WantedBy=multi-user.target
EOF
}
write_dnsmasq_conf(){                            # <share:0|1> — regenerate /etc/dnsmasq.d/ap.conf for the current mode
  local share="${1:-0}" dns=0
  [[ "$share" == "1" || "$LOCAL_DNS" == "1" ]] && dns=1   # serve the Pi's name over unicast DNS?
  [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.orig ]] && mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
  install -d /etc/dnsmasq.d
  rm -f /etc/dnsmasq.d/ap-hosts    # never inside the conf-dir: dnsmasq parses every file there as config (removes any stale landmine)
  {
    echo "interface=${IFACE}"
    [[ "$ENABLE_ETH" == "1" && "$ETH_DHCP" == "1" ]] && echo "interface=${ETH_IFACE}"
    echo "bind-dynamic"
    echo "domain-needed"
    echo "bogus-priv"
    echo "dhcp-range=set:wlan,${DHCP_START},${DHCP_END},${NETMASK},24h"
    # option 3 (gateway) only when sharing; option 6 (DNS) whenever the Pi serves its own name
    if [[ "$share" == "1" ]]; then echo "dhcp-option=tag:wlan,3,${AP_IP}"; else echo "dhcp-option=tag:wlan,3"; fi
    if [[ "$dns"   == "1" ]]; then echo "dhcp-option=tag:wlan,6,${AP_IP}"; else echo "dhcp-option=tag:wlan,6"; fi
    if [[ "$ENABLE_ETH" == "1" && "$ETH_DHCP" == "1" ]]; then
      echo "dhcp-range=set:eth,${ETH_DHCP_START},${ETH_DHCP_END},${NETMASK},24h"
      # isolated: never a gateway on the wire -> the workstation keeps its own default route
      if [[ "$share" == "1" ]]; then echo "dhcp-option=tag:eth,3,${ETH_IP}"; else echo "dhcp-option=tag:eth,3"; fi
      if [[ "$dns"   == "1" ]]; then echo "dhcp-option=tag:eth,6,${ETH_IP}"; else echo "dhcp-option=tag:eth,6"; fi
    fi
    if [[ "$share" == "1" ]]; then
      # deterministic upstream resolvers (ignore the host resolv.conf -> no 127.0.0.53 loop)
      if [[ -n "${UPSTREAM_DNS// /}" ]]; then
        echo "no-resolv"
        local s; for s in $UPSTREAM_DNS; do echo "server=${s}"; done
      fi
    elif [[ "$dns" == "1" ]]; then
      # isolated: NO upstream. dnsmasq answers only the Pi's own name; anything else gets REFUSED,
      # so a dual-homed client (Wi-Fi here + internet elsewhere) falls through to its real resolver.
      echo "no-resolv"
    fi
    if [[ "$dns" == "1" ]]; then
      # resolve the Pi by name over unicast DNS (reliable where Windows .local/mDNS is flaky).
      # localise-queries returns the Pi address on the SAME subnet as the asking client.
      echo "no-hosts"
      echo "addn-hosts=/etc/dnsmasq-ap-hosts"    # OUTSIDE /etc/dnsmasq.d (that dir is a conf-dir; a hosts file there fails to parse)
      echo "expand-hosts"
      echo "domain=${LOCAL_DOMAIN}"              # also DHCP option 15 -> clients search-suffix bare 'karasu' to karasu.lan
      echo "local=/${LOCAL_DOMAIN}/"             # never forward the local domain upstream
      echo "localise-queries"
    fi
  } >/etc/dnsmasq.d/ap.conf

  if [[ "$dns" == "1" ]]; then
    {
      echo "${AP_IP} ${PI_HOSTNAME}"
      [[ "$ENABLE_ETH" == "1" ]] && echo "${ETH_IP} ${PI_HOSTNAME}"
    } >/etc/dnsmasq-ap-hosts
  else
    rm -f /etc/dnsmasq-ap-hosts
  fi
}
names_on(){ share_is_on || [[ "$LOCAL_DNS" == "1" ]]; }   # is http://<name>/ served over unicast DNS right now?

usage(){ sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'; }

# ---- OPS -------------------------------------------------------------------
op_ssid(){
  local v="${1:-}"; [[ -n "$v" ]] || { echo "usage: $0 ssid <NAME>" >&2; exit 2; }
  (( $(bytelen "$v") <= 32 )) || { echo "!! SSID must be <= 32 bytes" >&2; exit 2; }
  require_deployed
  hconf_set ssid "$v"; hc_set_ssid "$v"; reload_hostapd
  echo "[OK] SSID = '$v' — clients must reconnect (if hidden, re-add it manually)"
}
op_pass(){
  local v="${1:-}" n; [[ -n "$v" ]] || { echo "usage: $0 pass <PASSPHRASE>" >&2; exit 2; }
  n="$(bytelen "$v")"; (( n >= 8 && n <= 63 )) || { echo "!! WPA2 passphrase must be 8-63 chars (got $n)" >&2; exit 2; }
  require_deployed
  hconf_set wpa_passphrase "$v"; reload_hostapd
  echo "[OK] passphrase updated — clients must reconnect with the new key"
}
op_hidden(){
  local m="${1:-}" val
  case "$m" in
    on|1|yes|true)  val=1 ;;
    off|0|no|false) val=0 ;;
    *) echo "usage: $0 hidden <on|off>" >&2; exit 2 ;;
  esac
  require_deployed
  hconf_set ignore_broadcast_ssid "$val"; reload_hostapd
  echo "[OK] hidden=$val ($( ((val==1)) && echo 'SSID not broadcast' || echo 'SSID broadcasting' ))"
}
op_channel(){
  local c="${1:-}"; [[ "$c" =~ ^[0-9]+$ ]] || { echo "usage: $0 channel <number>" >&2; exit 2; }
  require_deployed
  hconf_set channel "$c"; reload_hostapd
  echo "[OK] channel = $c"
}
op_hostname(){                                   # set the Pi hostname -> <name>.local (mDNS)
  local h="${1:-}"; [[ -n "$h" ]] || { echo "usage: $0 hostname <NAME>" >&2; exit 2; }
  [[ "$h" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || { echo "!! invalid hostname (letters, digits, hyphens)" >&2; exit 2; }
  set_hostname "$h"
  if [[ -f /etc/avahi/avahi-daemon.conf ]]; then
    sed -i "s/^host-name=.*/host-name=$h/" /etc/avahi/avahi-daemon.conf
    systemctl restart avahi-daemon 2>/dev/null || true
  fi
  # keep the unicast-DNS name in sync (share mode, or isolated with LOCAL_DNS=1)
  PI_HOSTNAME="$h"
  if [[ -f /etc/dnsmasq.d/ap.conf ]]; then
    write_dnsmasq_conf "$( share_is_on && echo 1 || echo 0 )"; systemctl restart dnsmasq 2>/dev/null || true
  fi
  echo "[OK] hostname = $h  ->  http://$h.local$( names_on && echo "  (or http://$h / http://$h.${LOCAL_DOMAIN} via DHCP-DNS)" )"
}
op_ethmac(){                                     # set eth0 MAC now + persist for next boot
  local mode="${1:-}"
  [[ -n "$mode" ]] || { echo "usage: $0 ethmac <keep|random|AA:BB:CC:DD:EE:FF>" >&2; exit 2; }
  case "$mode" in
    keep|random) ;;
    *) [[ "$mode" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] || { echo "!! invalid MAC (use keep|random|AA:BB:CC:DD:EE:FF)" >&2; exit 2; } ;;
  esac
  local unit=/etc/systemd/system/eth-ip.service persisted=""
  if [[ -f "$unit" ]] && grep -q '^Environment=ETH_MAC=' "$unit"; then
    local tmp; tmp="$(mktemp)"
    awk -v v="$mode" '/^Environment=ETH_MAC=/{print "Environment=ETH_MAC=" v; next}{print}' "$unit" > "$tmp"
    cat "$tmp" > "$unit"; rm -f "$tmp"; systemctl daemon-reload
    persisted="  (persists on reboot)"
  fi
  mac_apply "$ETH_IFACE" "$mode" || exit 1
  echo "[OK] ${ETH_IFACE} MAC mode = ${mode}${persisted}"
}
op_share(){                                      # on|off|status — share the Pi's internet to clients
  local m="${1:-status}"
  case "$m" in
    on|1|yes|true)
      require_deployed
      local up; up="$(resolve_uplink)"
      [[ -n "$up" ]] || { echo "!! no uplink NIC found. Set UPLINK_IFACE in the script (e.g. eth1/wlan1/usb0) and re-run, or check the internet NIC is up with a default route." >&2; exit 1; }
      write_nat_unit
      write_sysctl_forward 1
      systemctl daemon-reload
      systemctl enable --now pi-ap-nat.service
      write_dnsmasq_conf 1; systemctl restart dnsmasq
      echo "[OK] internet sharing ON  (uplink=${up})"
      echo "     clients: renew DHCP (or reconnect) to pick up the Pi as gateway + DNS"
      echo "     name   : http://${PI_HOSTNAME}/  or  http://${PI_HOSTNAME}.${LOCAL_DOMAIN}/  (unicast DNS, no mDNS needed)"
      ;;
    off|0|no|false)
      systemctl disable --now pi-ap-nat.service 2>/dev/null || true
      nat_clear
      write_sysctl_forward 0
      write_dnsmasq_conf 0; systemctl restart dnsmasq 2>/dev/null || true
      echo "[OK] internet sharing OFF (isolated) — clients renew DHCP to drop the gateway$( [[ "$LOCAL_DNS" == "1" ]] && echo " (name http://${PI_HOSTNAME}/ still resolves via the Pi)" || echo "/DNS" )"
      ;;
    status|show)
      if share_is_on; then
        printf 'internet sharing: ON   uplink=%s   ip_forward=%s\n' "$(resolve_uplink || echo '?')" "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)"
        iptables -t nat -C POSTROUTING -o "$(resolve_uplink)" -j MASQUERADE 2>/dev/null \
          && echo 'masquerade      : present' || echo 'masquerade      : MISSING (run: sudo pi-ap share on)'
      else
        echo 'internet sharing: OFF (isolated — clients get the drop server only, no internet)'
      fi
      ;;
    *) echo "usage: $0 share <on|off|status>" >&2; exit 2 ;;
  esac
}
op_restart(){
  systemctl restart ap-ip.service hostapd dnsmasq updrop.service 2>/dev/null
  systemctl restart eth-ip.service 2>/dev/null || true
  share_is_on && systemctl restart pi-ap-nat.service 2>/dev/null || true
  echo "[OK] stack restarted$( share_is_on && echo ' (internet sharing ON)' )"
}
op_show(){
  require_deployed
  local ssid hid ch txp reg ethv4 ethv6 ethmac bind
  ssid="$(sed -n 's/^ssid=//p' "$HOSTAPD_CONF")"
  hid="$(sed -n 's/^ignore_broadcast_ssid=//p' "$HOSTAPD_CONF")"; hid="${hid:-0}"
  ch="$(sed -n 's/^channel=//p' "$HOSTAPD_CONF")"
  txp="$(iw dev "$IFACE" info 2>/dev/null | sed -n 's/^[[:space:]]*txpower //p')"
  reg="$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -n1)"
  ethv4="$(ip -brief addr show "$ETH_IFACE" 2>/dev/null | awk '{print $3}')"
  ethv6="$(ip -6 addr show "$ETH_IFACE" 2>/dev/null | sed -n 's/.*inet6 \(fe80[^/ ]*\).*/\1/p' | head -n1)"
  ethmac="$(cat /sys/class/net/${ETH_IFACE}/address 2>/dev/null)"
  bind="$(sed -n 's/.*-bind \([^ ]*\).*/\1/p' /etc/systemd/system/updrop.service 2>/dev/null)"
  printf 'Host     : http://%s.local%s/\n' "$(hostname 2>/dev/null)" "$( [[ "$UPLOAD_PORT" != 80 ]] && echo ":${UPLOAD_PORT}" )"
  printf 'SSID     : %s%s\n' "$ssid" "$( ((hid==1)) && echo '  [hidden]' )"
  printf 'Channel  : %s   TXpower: %s   RegDom: %s\n' "$ch" "${txp:-?}" "${reg:-?}"
  printf 'Wi-Fi IP : %s/24\n' "$AP_IP"
  printf 'Eth0 IP  : %s\n' "${ethv4:-not configured}"
  printf 'Eth0 MAC : %s\n' "${ethmac:-?}"
  printf 'Eth0 v6  : %s%s\n' "${ethv6:-none}" "$( [[ -n "$ethv6" ]] && echo "%${ETH_IFACE} (link-local)" )"
  if share_is_on; then
    printf 'Internet : shared via %s (NAT)  ->  clients get gateway+DNS = the Pi\n' "$(resolve_uplink || echo '?')"
  else
    printf 'Internet : isolated (clients get the drop server only; run: sudo pi-ap share on)\n'
  fi
  if names_on; then
    printf 'Name DNS : http://%s/  http://%s.%s/   (unicast, DHCP DNS = the Pi)\n' "$(hostname 2>/dev/null)" "$(hostname 2>/dev/null)" "$LOCAL_DOMAIN"
  else
    printf 'Name DNS : off (LOCAL_DNS=0, isolated) — use the IP or .local\n'
  fi
  printf 'Server   : bind=%s port=%s dir=%s\n' "${bind:-?}" "$UPLOAD_PORT" "$UPLOAD_DIR"
  printf 'Services : hostapd=%s dnsmasq=%s updrop=%s%s\n' \
    "$(systemctl is-active hostapd 2>/dev/null)" \
    "$(systemctl is-active dnsmasq 2>/dev/null)" \
    "$(systemctl is-active updrop 2>/dev/null)" \
    "$( share_is_on && printf ' nat=%s' "$(systemctl is-active pi-ap-nat.service 2>/dev/null)" )"
}
op_status(){
  if [[ -x /usr/local/bin/pi_ap_healthcheck.sh ]]; then
    IFACE="$IFACE" SSID="$SSID" AP_IP="$AP_IP" UPLOAD_PORT="$UPLOAD_PORT" UPLOAD_DIR="$UPLOAD_DIR" \
      /usr/local/bin/pi_ap_healthcheck.sh "$@"
  else
    systemctl status hostapd dnsmasq updrop --no-pager || true
  fi
}

# ---- SETUP -----------------------------------------------------------------
do_setup(){
  echo "[*] Installing packages..."
  apt-get update -y
  apt-get install -y hostapd dnsmasq iw rfkill iptables

  echo "[*] Unblocking Wi-Fi radio + setting regulatory domain to ${COUNTRY}..."
  rfkill unblock wlan || true
  set_regdomain

  echo "[*] Hostname '${PI_HOSTNAME}'$( [[ "$ENABLE_MDNS" == "1" ]] && echo " + mDNS (${PI_HOSTNAME}.local)" )..."
  set_hostname "$PI_HOSTNAME"
  if [[ "$ENABLE_MDNS" == "1" ]]; then
    apt-get install -y avahi-daemon
    cat >/etc/avahi/avahi-daemon.conf <<EOF
[server]
host-name=${PI_HOSTNAME}
allow-interfaces=${IFACE}$( [[ "$ENABLE_ETH" == "1" ]] && echo ",${ETH_IFACE}" )
use-ipv4=yes
use-ipv6=yes
[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
EOF
    systemctl enable avahi-daemon 2>/dev/null || true
    systemctl restart avahi-daemon 2>/dev/null || true
  fi

  echo "[*] Removing ${IFACE}$( [[ "$ENABLE_ETH" == "1" ]] && echo "+${ETH_IFACE}" ) from NetworkManager (the uplink NIC stays NM-managed for its own DHCP + default route)..."
  local unmanaged="interface-name:${IFACE}"
  [[ "$ENABLE_ETH" == "1" ]] && unmanaged="${unmanaged};interface-name:${ETH_IFACE}"
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-unmanaged-ap.conf <<EOF
[keyfile]
unmanaged-devices=${unmanaged}
EOF
  systemctl reload NetworkManager || true

  echo "[*] Static-IP oneshot for $IFACE (Wi-Fi)..."
  cat >/etc/systemd/system/ap-ip.service <<EOF
[Unit]
Description=Static IP for AP interface ${IFACE}
Wants=network-pre.target
Before=hostapd.service dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip link set ${IFACE} up
ExecStart=/sbin/ip addr flush dev ${IFACE}
ExecStart=/sbin/ip addr add ${AP_IP}/24 dev ${IFACE}
ExecStop=/sbin/ip addr flush dev ${IFACE}

[Install]
WantedBy=multi-user.target
EOF

  if [[ "$ENABLE_ETH" == "1" ]]; then
    echo "[*] Static-IP oneshot for ${ETH_IFACE} (wired workstation)..."
    cat >/etc/systemd/system/eth-ip.service <<EOF
[Unit]
Description=Static IP for wired interface ${ETH_IFACE}
Wants=network-pre.target
Before=dnsmasq.service

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=ETH_MAC=${ETH_MAC}
ExecStartPre=-/usr/local/bin/pi-ap _macapply ${ETH_IFACE} \${ETH_MAC}
ExecStart=/sbin/ip link set ${ETH_IFACE} up
ExecStart=/sbin/ip addr flush dev ${ETH_IFACE}
ExecStart=/sbin/ip addr add ${ETH_IP}/24 dev ${ETH_IFACE}
ExecStop=/sbin/ip addr flush dev ${ETH_IFACE}

[Install]
WantedBy=multi-user.target
EOF
  fi

  echo "[*] hostapd config (hidden=${HIDDEN})..."
  install -d /etc/hostapd
  local bssid_line=""; [[ -n "$BSSID" ]] && bssid_line="bssid=${BSSID}"
  cat >"$HOSTAPD_CONF" <<EOF
interface=${IFACE}
driver=nl80211
ssid=${SSID}
${bssid_line}
country_code=${COUNTRY}
ieee80211d=1
hw_mode=${HW_MODE}
channel=${CHANNEL}
ieee80211n=1
wmm_enabled=1
auth_algs=1
macaddr_acl=0
ignore_broadcast_ssid=${HIDDEN}
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=${PSK}
EOF
  chmod 600 "$HOSTAPD_CONF"
  if grep -q '^#\?DAEMON_CONF=' /etc/default/hostapd 2>/dev/null; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >>/etc/default/hostapd
  fi

  echo "[*] hostapd restart-guard drop-in (boot race fix)..."
  install -d /etc/systemd/system/hostapd.service.d
  cat >/etc/systemd/system/hostapd.service.d/override.conf <<EOF
[Unit]
After=ap-ip.service
Wants=ap-ip.service

[Service]
ExecStartPre=/bin/sleep 2
Restart=on-failure
RestartSec=3
EOF

  echo "[*] dnsmasq config (DHCP for Wi-Fi$( [[ "$ENABLE_ETH" == "1" && "$ETH_DHCP" == "1" ]] && echo ' + eth0' ); internet sharing=$( [[ "$SHARE_INTERNET" == "1" ]] && echo on || echo off ))..."
  write_dnsmasq_conf "$SHARE_INTERNET"

  echo "[*] Creating non-root service user '${UPLOAD_USER}'..."
  id -u "$UPLOAD_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$UPLOAD_USER"
  install -d -o "$UPLOAD_USER" -g "$UPLOAD_USER" "$UPLOAD_DIR"
  chown -R "$UPLOAD_USER":"$UPLOAD_USER" "$UPLOAD_DIR"

  echo "[*] Deploying upload server (Go, bind ${SERVER_BIND})..."
  if [[ -x "$GO_BIN" ]]; then
    echo "    using prebuilt binary: $GO_BIN"; install -m755 "$GO_BIN" /usr/local/bin/updrop
  elif command -v go >/dev/null 2>&1; then
    [[ -f "$GO_SRC" ]] || { echo "!! missing $GO_SRC"; exit 1; }
    echo "    building $GO_SRC ..."; ( cd "$HERE" && go build -o /usr/local/bin/updrop "$(basename "$GO_SRC")" )
  else
    echo "!! no prebuilt '$GO_BIN' and no 'go' toolchain to build it."
    echo "   cross-compile: GOOS=linux GOARCH=arm64 go build -o updrop $(basename "$GO_SRC")  (drop next to this script)"
    echo "   or: sudo apt install -y golang"; exit 1
  fi
  local EXEC="/usr/local/bin/updrop -port ${UPLOAD_PORT} -dir ${UPLOAD_DIR} -bind ${SERVER_BIND}"

  local cap_line=""; [[ "$UPLOAD_PORT" -lt 1024 ]] && cap_line="AmbientCapabilities=CAP_NET_BIND_SERVICE"
  local after="network.target ap-ip.service"
  [[ "$ENABLE_ETH" == "1" ]] && after="${after} eth-ip.service"
  cat >/etc/systemd/system/updrop.service <<EOF
[Unit]
Description=updrop file upload server
After=${after}

[Service]
ExecStart=${EXEC}
Restart=on-failure
RestartSec=3
User=${UPLOAD_USER}
Group=${UPLOAD_USER}
${cap_line}
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectControlGroups=true
ProtectKernelTunables=true
ProtectKernelModules=true
RestrictSUIDSGID=true
ReadWritePaths=${UPLOAD_DIR}

[Install]
WantedBy=multi-user.target
EOF

  local monitor_ok=0
  if [[ "$ENABLE_MONITOR" == "1" ]]; then
    if [[ -f "$HC_SRC" ]]; then
      echo "[*] Deploying health-check timer (every ${HC_INTERVAL})..."
      install -m755 "$HC_SRC" /usr/local/bin/pi_ap_healthcheck.sh
      cat >"$HC_UNIT" <<EOF
[Unit]
Description=updrop AP health check
After=updrop.service

[Service]
Type=oneshot
Environment=IFACE=${IFACE}
Environment=SSID=${SSID}
Environment=AP_IP=${AP_IP}
Environment=UPLOAD_PORT=${UPLOAD_PORT}
Environment=UPLOAD_DIR=${UPLOAD_DIR}
ExecStart=/usr/local/bin/pi_ap_healthcheck.sh --quiet --no-upload
EOF
      cat >/etc/systemd/system/pi-ap-healthcheck.timer <<EOF
[Unit]
Description=Run updrop AP health check every ${HC_INTERVAL}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${HC_INTERVAL}
AccuracySec=30s

[Install]
WantedBy=timers.target
EOF
      monitor_ok=1
    else
      echo "!! monitor requested but $HC_SRC not found — skipping timer"
    fi
  fi

  echo "[*] Installing control script as /usr/local/bin/pi-ap..."
  install -m755 "$SELF" /usr/local/bin/pi-ap

  echo "[*] Enabling + (re)starting services..."
  systemctl unmask hostapd
  systemctl daemon-reload
  systemctl enable ap-ip.service hostapd dnsmasq updrop.service
  [[ "$ENABLE_ETH" == "1" ]] && systemctl enable eth-ip.service
  systemctl restart ap-ip.service
  [[ "$ENABLE_ETH" == "1" ]] && systemctl restart eth-ip.service
  reload_hostapd
  systemctl restart dnsmasq updrop.service
  [[ "$monitor_ok" == "1" ]] && systemctl enable --now pi-ap-healthcheck.timer

  if [[ "$SHARE_INTERNET" == "1" ]]; then
    echo "[*] Internet sharing: enabling NAT (uplink=$(resolve_uplink || echo '?'))..."
    write_nat_unit
    write_sysctl_forward 1
    systemctl daemon-reload
    systemctl enable --now pi-ap-nat.service || echo "!! NAT service failed to start — check UPLINK_IFACE / uplink default route, then: sudo pi-ap share on"
  fi

  echo
  local psfx=""; [[ "$UPLOAD_PORT" != "80" ]] && psfx=":${UPLOAD_PORT}"
  echo "[OK] setup complete  (hidden: ${HIDDEN}, bind: ${SERVER_BIND}, internet sharing: $( [[ "$SHARE_INTERNET" == "1" ]] && echo ON || echo OFF ))"
  [[ "$ENABLE_MDNS" == "1" ]] && echo "     Name   : http://${PI_HOSTNAME}.local${psfx}/    (mDNS on Wi-Fi + eth0)"
  echo "     Wi-Fi  : SSID ${SSID} / pass ${PSK}  ->  http://${AP_IP}${psfx}/"
  if [[ "$ENABLE_ETH" == "1" ]]; then
    echo "     Eth0   : ${ETH_IP}$( [[ "$ETH_DHCP" == "1" ]] && echo " (+DHCP ${ETH_DHCP_START}-${ETH_DHCP_END})" )  ->  http://${ETH_IP}${psfx}/"
  fi
  if [[ "$SHARE_INTERNET" == "1" || "$LOCAL_DNS" == "1" ]]; then
    echo "     Name   : http://${PI_HOSTNAME}${psfx}/  or  http://${PI_HOSTNAME}.${LOCAL_DOMAIN}${psfx}/   (unicast DNS via the Pi)"
  fi
  if [[ "$SHARE_INTERNET" == "1" ]]; then
    echo "     Internet: shared via $(resolve_uplink || echo '?')"
  fi
  echo "     Ops    : sudo pi-ap show | status | share on|off | hostname NAME | ethmac random | ssid NAME | hidden off"
}

# ---- DISPATCH --------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)   need_root; do_setup ;;
  ssid)    need_root; op_ssid   "${1:-}" ;;
  pass)    need_root; op_pass   "${1:-}" ;;
  hidden)  need_root; op_hidden "${1:-}" ;;
  channel) need_root; op_channel "${1:-}" ;;
  hostname) need_root; op_hostname "${1:-}" ;;
  ethmac)  need_root; op_ethmac "${1:-}" ;;
  share)   need_root; op_share "${1:-status}" ;;
  _macapply) need_root; mac_apply "${1:-}" "${2:-}" ;;
  _natapply) need_root; nat_apply ;;
  _natclear) need_root; nat_clear ;;
  restart) need_root; op_restart ;;
  show)    need_root; op_show ;;
  status)  op_status "$@" ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac
