#!/usr/bin/env bash
# =============================================================================
#  pi_ap_healthcheck  |  Author: d3vn0mi
#  Health check for the Raspberry Pi AP + updrop file-upload stack.
#
#  Verifies, layer by layer:
#    services -> AP/radio -> addressing -> DHCP -> upload socket
#    -> HTTP -> upload round-trip w/ sha256 integrity -> resources
#  Prints PASS/WARN/FAIL per check and exits non-zero if anything FAILED
#  (with --strict, warnings fail too), so it drops straight into monitoring.
#
#  Run    : sudo bash pi_ap_healthcheck.sh          (sudo = full coverage)
#  Flags  : -q/--quiet      only failures + summary
#           --no-upload     skip the write/integrity round-trip (read-only)
#           --strict        exit non-zero on warnings too
#           -h/--help
#  Config : override any default via env, e.g.
#           AP_IP=10.42.0.1 UPLOAD_PORT=9000 sudo bash pi_ap_healthcheck.sh
#
#  Changelog:
#    v0.2  default AP_IP -> 192.168.150.1 (new Wi-Fi subnet)
#    v0.1  initial release
# =============================================================================
set -u

### ---- CONFIG (env-overridable) ---------------------------------------------
IFACE="${IFACE:-wlan0}"
SSID="${SSID:-karasu}"
AP_IP="${AP_IP:-192.168.150.1}"
UPLOAD_PORT="${UPLOAD_PORT:-8000}"
UPLOAD_DIR="${UPLOAD_DIR:-/srv/updrop}"
read -r -a SERVICES <<< "${SERVICES:-hostapd dnsmasq updrop ap-ip}"
### --------------------------------------------------------------------------

QUIET=0; DO_UPLOAD=1; STRICT=0
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet)  QUIET=1 ;;
    --no-upload) DO_UPLOAD=0 ;;
    --strict)    STRICT=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[34m'; N=$'\e[0m'; BOLD=$'\e[1m'
else
  G=""; R=""; Y=""; B=""; N=""; BOLD=""
fi

pass=0; warn=0; fail=0
ok()  { pass=$((pass+1)); [[ $QUIET -eq 1 ]] || printf ' %s[ PASS ]%s %s\n' "$G" "$N" "$1"; }
wrn() { warn=$((warn+1)); [[ $QUIET -eq 1 ]] || printf ' %s[ WARN ]%s %s\n' "$Y" "$N" "$1"; }
inf() { [[ $QUIET -eq 1 ]] || printf ' %s[ INFO ]%s %s\n' "$B" "$N" "$1"; }
bad() { fail=$((fail+1)); printf ' %s[ FAIL ]%s %s\n' "$R" "$N" "$1"
        [[ -n "${2:-}" ]] && printf '          %s^ %s%s\n' "$Y" "$2" "$N"; return 0; }
sec() { [[ $QUIET -eq 1 ]] || printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$N"; }
have(){ command -v "$1" >/dev/null 2>&1; }

[[ $QUIET -eq 1 ]] || printf '%supdrop AP health check%s  target %s:%s  %s\n' \
  "$BOLD" "$N" "$AP_IP" "$UPLOAD_PORT" "$(date '+%F %T')"
[[ $EUID -eq 0 ]] || wrn "not root — process names, cleanup and some sockets may be hidden (re-run with sudo for full coverage)"
for c in systemctl iw ip ss curl sha256sum; do have "$c" || wrn "missing '$c' — related checks will be skipped"; done

# --- services ---------------------------------------------------------------
sec "Services"
if have systemctl; then
  for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then ok "$svc active"
    else bad "$svc not active" "systemctl status $svc --no-pager -l"; fi
  done
else
  wrn "systemctl unavailable — skipping service checks"
fi

# --- AP / radio -------------------------------------------------------------
sec "Access point / radio"
if have iw; then
  info_out="$(iw dev "$IFACE" info 2>/dev/null || true)"
  if [[ -z "$info_out" ]]; then
    bad "$IFACE not found by iw"
  else
    grep -q 'type AP' <<<"$info_out" && ok "$IFACE in AP mode" || bad "$IFACE not in AP mode"
    cur_ssid="$(sed -n 's/^[[:space:]]*ssid //p' <<<"$info_out")"
    if [[ "$cur_ssid" == "$SSID" ]]; then ok "SSID = $SSID"
    else wrn "SSID = '${cur_ssid:-none}', expected '$SSID'"; fi
    if grep -q '^[[:space:]]*channel ' <<<"$info_out"; then
      ch="$(sed -n 's/^[[:space:]]*channel \([0-9]\{1,\}\).*/\1/p' <<<"$info_out" | head -n1)"
      ok "operating on channel ${ch:-?} (BSS enabled / beaconing)"
    else
      bad "no operating channel — AP likely not enabled" "journalctl -u hostapd -b -e --no-pager"
    fi
  fi
fi

# --- addressing -------------------------------------------------------------
sec "Addressing"
if have ip; then
  if ip -brief addr show "$IFACE" 2>/dev/null | grep -qF "${AP_IP}/24"; then
    ok "$IFACE has ${AP_IP}/24"
  else
    cur_ip="$(ip -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
    bad "$IFACE address is '${cur_ip:-none}', expected ${AP_IP}/24" "systemctl status ap-ip --no-pager"
  fi
fi

# --- DHCP (dnsmasq) ---------------------------------------------------------
sec "DHCP (dnsmasq)"
if have ss; then
  if ss -H -ulnp 2>/dev/null | awk '{print $5}' | grep -qE ':(67|53)$'; then
    ok "dnsmasq DHCP/DNS sockets present"
  else
    wrn "no :67/:53 listener seen (run with sudo, or check dnsmasq)"
  fi
fi
LEASES="/var/lib/misc/dnsmasq.leases"
if [[ -r "$LEASES" ]]; then
  n="$(wc -l <"$LEASES" 2>/dev/null || echo 0)"
  inf "active DHCP leases: $n"
  [[ "${n:-0}" -gt 0 ]] && inf "  $(awk '{print $3" ("$4")"}' "$LEASES" | paste -sd', ' -)"
fi

# --- upload server socket ---------------------------------------------------
sec "Upload server"
base="http://${AP_IP}:${UPLOAD_PORT}"
if have ss; then
  line="$(ss -H -tlnp 2>/dev/null | awk -v p=":${UPLOAD_PORT}" '$4 ~ p"$"' | head -n1)"
  if [[ -n "$line" ]]; then
    baddr="$(awk '{print $4}' <<<"$line")"
    backend="$(sed -nE 's/.*users:\(\("([^"]+)".*/\1/p' <<<"$line")"
    ok "listening on ${baddr}${backend:+  (backend: $backend)}"
    [[ "$baddr" == 0.0.0.0:* || "$baddr" == '*:'* || "$baddr" == '[::]:'* ]] && \
      wrn "bound to all interfaces — reachable beyond the AP; prefer -bind ${AP_IP}"
  else
    bad "nothing listening on :${UPLOAD_PORT}" "systemctl status updrop --no-pager"
  fi
fi

# --- HTTP functional --------------------------------------------------------
sec "HTTP"
if have curl; then
  curl -sf -o /dev/null --max-time 5 "${base}/"        && ok "GET / -> 200 (browse/download)"      || bad "GET ${base}/ failed"       "curl -v ${base}/"
  curl -sf -o /dev/null --max-time 5 "${base}/upload"  && ok "GET /upload -> 200 (form served)"     || bad "GET ${base}/upload failed"
fi

# --- upload round-trip + integrity -----------------------------------------
if [[ $DO_UPLOAD -eq 1 ]] && have curl && have sha256sum; then
  sec "Upload round-trip (integrity)"
  tmp="$(mktemp)"; testname="healthcheck-$$-$(date +%s).bin"
  head -c 65536 /dev/urandom >"$tmp"
  want="$(sha256sum "$tmp" | awk '{print $1}')"
  resp="$(curl -s --max-time 10 -F "files=@${tmp};filename=${testname}" "${base}/upload" || true)"
  grep -q 'Saved' <<<"$resp" && ok "POST /upload accepted the file" \
    || bad "POST /upload not confirmed" "resp: $(tr -d '\n' <<<"$resp" | head -c 100)"
  dest="${UPLOAD_DIR}/${testname}"
  if [[ -f "$dest" ]]; then
    ok "file landed in ${UPLOAD_DIR}"
    got="$(sha256sum "$dest" | awk '{print $1}')"
    [[ "$want" == "$got" ]] && ok "sha256 matches (binary-safe, no corruption)" \
      || bad "sha256 MISMATCH" "want ${want:0:16}.. got ${got:0:16}.."
    rm -f "$dest" 2>/dev/null || wrn "left test file behind (need sudo to remove ${dest})"
  else
    bad "uploaded file not found at ${dest}" "wrong UPLOAD_DIR, or server --directory differs"
  fi
  rm -f "$tmp"
fi

# --- resources --------------------------------------------------------------
sec "Resources"
if have df && [[ -d "$UPLOAD_DIR" ]]; then
  read -r du da dp <<<"$(df -h --output=used,avail,pcent "$UPLOAD_DIR" 2>/dev/null | tail -n1)"
  inf "disk ${UPLOAD_DIR}: ${du:-?} used, ${da:-?} free (${dp:-?})"
  pn="${dp%\%}"; [[ "${pn:-x}" =~ ^[0-9]+$ ]] && (( pn >= 90 )) && wrn "disk usage high (${dp}) — drop box filling up"
fi
if have iw; then
  st="$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')"
  inf "associated clients now: ${st:-0}"
fi
have free && inf "memory: $(free -m | awk '/^Mem:/{print $3"/"$2" MB used"}')"

# --- summary ----------------------------------------------------------------
sec "Summary"
printf ' %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' "$G" "$pass" "$N" "$Y" "$warn" "$N" "$R" "$fail" "$N"
if (( fail > 0 )); then
  printf '%sHEALTH: FAIL%s\n' "$R" "$N"; exit 1
elif (( warn > 0 && STRICT == 1 )); then
  printf '%sHEALTH: WARN (strict)%s\n' "$Y" "$N"; exit 1
elif (( warn > 0 )); then
  printf '%sHEALTH: OK (warnings)%s\n' "$Y" "$N"; exit 0
else
  printf '%sHEALTH: OK%s\n' "$G" "$N"; exit 0
fi
