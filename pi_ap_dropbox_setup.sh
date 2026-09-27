#!/usr/bin/env bash
# =============================================================================
#  pi_ap_dropbox  -  v0.5
#  Raspberry Pi Wi-Fi Access Point + file-upload web server. Modal control.
#
#  MODES:
#    setup                      full provision (packages, NM unmanage, user,
#                               server, hostapd/dnsmasq/units, monitor)
#    ssid <NAME>                change SSID              (live, restarts hostapd)
#    pass <PASSPHRASE>          change WPA2 passphrase   (live, restarts hostapd)
#    hidden <on|off>            toggle SSID broadcast    (live, restarts hostapd)
#    channel <N>                change channel           (live, restarts hostapd)
#    restart                    restart the whole stack
#    show                       print current AP config (incl. TX power + regdom)
#    status [hc args...]        run the health check
#
#  Ops modes edit the DEPLOYED config in /etc and restart only what's needed
#  (no reboot, no re-provision). 'setup' installs this script as
#  /usr/local/bin/pi-ap, so afterwards:  sudo pi-ap hidden off
#
#  Run    : sudo bash pi_ap_dropbox_v0.5.sh setup
#           (keep updrop_v0.2.go and pi_ap_healthcheck_v0.1.sh next to it)
#
#  Changelog:
#    v0.5  set regulatory domain + ieee80211d=1 so the AP uses full allowed TX
#          power (fixes weak/short-range signal); 'show' now reports TX power + regdom
#    v0.4  modal: setup vs live ops; ops restart only affected service + verify;
#          installs itself as /usr/local/bin/pi-ap
#    v0.3  hidden SSID; hostapd restart-guard; non-root sandboxed user; monitor timer
#    v0.2  build-or-install the upload server binary
#    v0.1  initial
# =============================================================================
set -euo pipefail

### ---- CONFIG (used by 'setup' only) ----------------------------------------
IFACE="wlan0"
SSID="pidropbox"
PSK="pidropbox"                                  # >= 8 chars (TEST cred — change before real use)
COUNTRY="CZ"                                    # ISO-3166 regulatory domain — REQUIRED (drives TX power)
CHANNEL="7"                                      # 2.4GHz: 1-13 (1/6/11 non-overlapping)
HW_MODE="g"                                      # g = 2.4GHz (a = 5GHz)
BSSID=""                                         # optional custom BSSID (empty = adapter default)
HIDDEN="0"                                        # 1 = hidden, 0 = broadcast
AP_IP="192.168.50.1"
DHCP_START="192.168.50.50"
DHCP_END="192.168.50.150"
NETMASK="255.255.255.0"

UPLOAD_DIR="/srv/updrop"
UPLOAD_PORT="8000"
UPLOAD_USER="updrop"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="${HERE}/$(basename "${BASH_SOURCE[0]}")"
GO_SRC="${HERE}/updrop.go"
GO_BIN="${HERE}/updrop"

ENABLE_MONITOR="1"
HC_SRC="${HERE}/pi_ap_healthcheck.sh"
HC_INTERVAL="5min"
### --------------------------------------------------------------------------

# constants shared by setup + ops
HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
HC_UNIT="/etc/systemd/system/pi-ap-healthcheck.service"

need_root(){ [[ $EUID -eq 0 ]] || { echo "run as root (use sudo)" >&2; exit 1; }; }
require_deployed(){ [[ -f "$HOSTAPD_CONF" ]] || { echo "!! $HOSTAPD_CONF not found — run 'setup' first" >&2; exit 1; }; }
bytelen(){ printf '%s' "$1" | wc -c; }

# set key=value in hostapd.conf (order-independent; preserves file perms/owner)
hconf_set(){
  local key="$1" val="$2" tmp; tmp="$(mktemp)"
  grep -v "^${key}=" "$HOSTAPD_CONF" > "$tmp" || true
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$HOSTAPD_CONF"; rm -f "$tmp"
}
# sync SSID env in the monitor unit (safe for arbitrary values via awk -v)
hc_set_ssid(){
  [[ -f "$HC_UNIT" ]] || return 0
  local v="$1" tmp; tmp="$(mktemp)"
  awk -v val="$v" '/^Environment=SSID=/{print "Environment=SSID=" val; next}{print}' "$HC_UNIT" > "$tmp"
  cat "$tmp" > "$HC_UNIT"; rm -f "$tmp"
  systemctl daemon-reload
}
# apply the OS regulatory domain (unlocks full TX power for the country)
set_regdomain(){
  command -v raspi-config >/dev/null 2>&1 && raspi-config nonint do_wifi_country "$COUNTRY" || true
  iw reg set "$COUNTRY" 2>/dev/null || true
}
# restart (or start) hostapd and confirm it actually came up
reload_hostapd(){
  if systemctl is-active --quiet hostapd; then systemctl restart hostapd; else systemctl start hostapd; fi
  sleep 1
  systemctl is-active --quiet hostapd || {
    echo "!! hostapd did NOT come up after the change — check: journalctl -u hostapd -e --no-pager" >&2
    exit 1; }
}

usage(){ sed -n '4,22p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'; }

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
op_restart(){
  systemctl restart ap-ip.service hostapd dnsmasq updrop.service
  echo "[OK] stack restarted"
}
op_show(){
  require_deployed
  local ssid hid ch txp reg
  ssid="$(sed -n 's/^ssid=//p' "$HOSTAPD_CONF")"
  hid="$(sed -n 's/^ignore_broadcast_ssid=//p' "$HOSTAPD_CONF")"; hid="${hid:-0}"
  ch="$(sed -n 's/^channel=//p' "$HOSTAPD_CONF")"
  txp="$(iw dev "$IFACE" info 2>/dev/null | sed -n 's/^[[:space:]]*txpower //p')"
  reg="$(iw reg get 2>/dev/null | sed -n 's/^country \([A-Z0-9]*\):.*/\1/p' | head -n1)"
  printf 'SSID     : %s\n'   "$ssid"
  printf 'Hidden   : %s (%s)\n' "$hid" "$( ((hid==1)) && echo hidden || echo broadcasting )"
  printf 'Channel  : %s\n'   "$ch"
  printf 'TX power : %s\n'   "${txp:-unknown}"
  printf 'RegDom   : %s\n'   "${reg:-unknown}"
  printf 'AP IP    : %s\n'   "$(ip -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
  printf 'Services : hostapd=%s dnsmasq=%s updrop=%s\n' \
    "$(systemctl is-active hostapd 2>/dev/null)" \
    "$(systemctl is-active dnsmasq 2>/dev/null)" \
    "$(systemctl is-active updrop 2>/dev/null)"
}
op_status(){
  if [[ -x /usr/local/bin/pi_ap_healthcheck.sh ]]; then
    /usr/local/bin/pi_ap_healthcheck.sh "$@"
  else
    systemctl status hostapd dnsmasq updrop --no-pager || true
  fi
}

# ---- SETUP -----------------------------------------------------------------
do_setup(){
  echo "[*] Installing packages..."
  apt-get update -y
  apt-get install -y hostapd dnsmasq iw rfkill

  echo "[*] Unblocking Wi-Fi radio + setting regulatory domain to ${COUNTRY}..."
  rfkill unblock wlan || true
  set_regdomain                          # unlocks full TX power for the country

  echo "[*] Removing $IFACE from NetworkManager control..."
  install -d /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/99-unmanaged-ap.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:${IFACE}
EOF
  systemctl reload NetworkManager || true

  echo "[*] Static-IP oneshot for $IFACE..."
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

  echo "[*] dnsmasq config..."
  [[ -f /etc/dnsmasq.conf && ! -f /etc/dnsmasq.conf.orig ]] && mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig || true
  install -d /etc/dnsmasq.d
  cat >/etc/dnsmasq.d/ap.conf <<EOF
interface=${IFACE}
bind-dynamic
domain-needed
bogus-priv
dhcp-range=${DHCP_START},${DHCP_END},${NETMASK},24h
dhcp-option=3,${AP_IP}
dhcp-option=6,${AP_IP}
EOF

  echo "[*] Creating non-root service user '${UPLOAD_USER}'..."
  id -u "$UPLOAD_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$UPLOAD_USER"
  install -d -o "$UPLOAD_USER" -g "$UPLOAD_USER" "$UPLOAD_DIR"
  chown -R "$UPLOAD_USER":"$UPLOAD_USER" "$UPLOAD_DIR"

  echo "[*] Deploying upload server (Go)..."
  local EXEC=""
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
  EXEC="/usr/local/bin/updrop -port ${UPLOAD_PORT} -dir ${UPLOAD_DIR} -bind ${AP_IP}"

  local cap_line=""; [[ "$UPLOAD_PORT" -lt 1024 ]] && cap_line="AmbientCapabilities=CAP_NET_BIND_SERVICE"
  cat >/etc/systemd/system/updrop.service <<EOF
[Unit]
Description=updrop file upload server
After=network.target ap-ip.service

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
  systemctl restart ap-ip.service      # oneshot: (re)adds the IP
  reload_hostapd                        # restart-or-start hostapd + verify it came up
  systemctl restart dnsmasq updrop.service
  [[ "$monitor_ok" == "1" ]] && systemctl enable --now pi-ap-healthcheck.timer

  echo
  echo "[OK] setup complete  (hidden: ${HIDDEN})"
  echo "     SSID   : ${SSID}   pass: ${PSK}"
  echo "     Upload : http://${AP_IP}:${UPLOAD_PORT}/upload"
  echo "     TXpwr  : $(iw dev "$IFACE" info 2>/dev/null | sed -n 's/^[[:space:]]*txpower //p')"
  echo "     Ops    : sudo pi-ap show | hidden off | ssid NAME | pass PW | status"
}

# ---- DISPATCH --------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)   need_root; do_setup ;;
  ssid)    need_root; op_ssid   "${1:-}" ;;
  pass)    need_root; op_pass   "${1:-}" ;;
  hidden)  need_root; op_hidden "${1:-}" ;;
  channel) need_root; op_channel "${1:-}" ;;
  restart) need_root; op_restart ;;
  show)    need_root; op_show ;;
  status)  op_status "$@" ;;
  help|-h|--help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac