# pi-ap-dropbox

Turn a Raspberry Pi into a standalone Wi-Fi access point with a streaming file-drop server. Connect a laptop or phone to the Pi's own network and upload/download over HTTP — no internet uplink required, the Pi *is* the network.

Built for portable / field use: one control script with a `setup` mode and live `ops` commands, a dependency-free Go upload server (single static binary, streams straight to disk), and a systemd health-check timer.

## Features

- **Self-contained AP** — `hostapd` + `dnsmasq`, isolated (no NAT/uplink needed)
- **Streaming uploads** — the Go server uses `MultipartReader` → `io.Copy`, so multi-GB files never buffer in RAM; single static binary that cross-compiles to any Pi
- **Browse + download** at `/`, **upload** at `/upload` (multipart field `files`)
- **Modal control** — `setup` once; then `pi-ap ssid|pass|hidden|channel|restart|show|status` apply live, no reboot, no re-provision
- **Hardened** — server runs as a non-root `updrop` user under a systemd sandbox
- **Self-monitoring** — health-check timer verifies the whole stack every 5 minutes
- **Correct TX power** — sets the regulatory domain + `ieee80211d=1` so the radio isn't power-capped (the classic "AP only reaches 30 cm" trap)

## Repo layout

| File | Purpose |
|---|---|
| `pi_ap_dropbox_v0.5.sh` | control script — `setup` + live ops; installs itself as `/usr/local/bin/pi-ap` |
| `updrop_v0.1.go` | the upload/download HTTP server (streaming, Go stdlib only) |
| `pi_ap_healthcheck_v0.1.sh` | layered health check (services, AP, DHCP, HTTP, upload integrity) |

## Requirements

- Raspberry Pi with Wi-Fi (onboard or USB), Raspberry Pi OS **Bookworm/Trixie** (NetworkManager default)
- A Go toolchain to build the server on the Pi (`sudo apt install golang`), **or** cross-compile it elsewhere and drop the `updrop` binary next to the script
- Root (`sudo`)

## Quick start

```bash
git clone https://github.com/<you>/pi-ap-dropbox.git
cd pi-ap-dropbox
# edit the CONFIG block at the top of pi_ap_dropbox_v0.5.sh (SSID, PSK, COUNTRY, ...)
sudo bash pi_ap_dropbox_v0.5.sh setup
sudo reboot          # first run only — lets NetworkManager fully release wlan0
```

After reboot:

```bash
sudo pi-ap show      # SSID, channel, TX power, regdomain, service states
sudo pi-ap status    # full health check
```

Connect a client to the SSID, then open `http://192.168.50.1:8000/upload`.

> First run over SSH: do it from the console or over Ethernet — the moment hostapd grabs `wlan0`, any SSH session riding that interface drops.

## Building the server

`setup` builds it automatically if `go` is present. To cross-compile from another machine and skip installing Go on the Pi:

```bash
GOOS=linux GOARCH=arm64 go build -o updrop updrop_v0.1.go        # Pi 3/4/5, 64-bit OS
GOOS=linux GOARCH=arm GOARM=7 go build -o updrop updrop_v0.1.go  # 32-bit OS / Zero 2 W
```

Drop the resulting `updrop` binary next to the script; `setup` installs it as-is.

## Managing it

`setup` installs the script as `pi-ap`. These are **live** changes — they edit the deployed config and restart only what's needed, no reboot:

| Command | Action |
|---|---|
| `sudo pi-ap show` | SSID, hidden, channel, TX power, regdomain, service states |
| `sudo pi-ap status [args]` | run the health check (`--strict`, `--no-upload`, …) |
| `sudo pi-ap ssid <NAME>` | change SSID |
| `sudo pi-ap pass <PASS>` | change WPA2 passphrase (8–63 chars) |
| `sudo pi-ap hidden <on\|off>` | toggle SSID broadcast |
| `sudo pi-ap channel <N>` | change channel |
| `sudo pi-ap restart` | restart the whole stack |

Every hostapd-affecting change is verified — if it fails to come back up (e.g. an invalid passphrase), you're told immediately instead of silently losing the AP.

## Upload / download

```bash
# upload (field name is 'files'; multiple allowed):
curl -F 'files=@disk.img' http://192.168.50.1:8000/upload
curl -F 'files=@a' -F 'files=@b' http://192.168.50.1:8000/upload
```

Browse and download by opening `http://192.168.50.1:8000/` in a browser. Uploaded files land in `/srv/updrop` (owned by the `updrop` user).

## Connecting a client

Broadcast SSID: just pick it from the Wi-Fi list. Hidden SSID (`HIDDEN=1`): enter the name manually.

```bash
# Linux (NetworkManager) — works for hidden networks too:
sudo nmcli connection add type wifi con-name pidrop ifname wlan0 ssid "pidropbox" \
  802-11-wireless.hidden yes wifi-sec.key-mgmt wpa-psk wifi-sec.psk "pidropbox"
sudo nmcli connection up pidrop
```

- **macOS:** `networksetup -setairportnetwork en0 pidropbox pidropbox` (works for hidden), or Wi-Fi menu → Other…
- **Windows:** add the network manually and tick *connect even if not broadcasting*.

Clients get a `192.168.50.x` lease and **no internet** — expected, it's an isolated AP.

## Monitoring

The `pi-ap-healthcheck.timer` runs every 5 minutes (read-only checks):

```bash
systemctl list-timers pi-ap-healthcheck.timer
journalctl -u pi-ap-healthcheck -e
sudo /usr/local/bin/pi_ap_healthcheck.sh      # full check on demand (incl. upload integrity)
```

Exit codes: `0` healthy, `1` a check failed (or any warning under `--strict`), `2` bad argument.

## Configuration

Edit the `CONFIG` block at the top of `pi_ap_dropbox_v0.5.sh` before `setup`:

| Var | Default | Notes |
|---|---|---|
| `IFACE` | `wlan0` | AP interface (set to your USB adapter, e.g. `wlan1`, if used) |
| `SSID` / `PSK` | `pidropbox` / `pidropbox` | **change these** |
| `COUNTRY` | `CZ` | ISO-3166 regulatory domain — drives legal TX power |
| `CHANNEL` | `7` | 2.4 GHz; 1/6/11 are non-overlapping |
| `HW_MODE` | `g` | `g` = 2.4 GHz, `a` = 5 GHz |
| `HIDDEN` | `0` | `1` = don't broadcast the SSID |
| `AP_IP` | `192.168.50.1` | gateway / server address |
| `DHCP_START`–`DHCP_END` | `.50`–`.150` | lease pool |
| `UPLOAD_DIR` | `/srv/updrop` | where uploads are saved |
| `UPLOAD_PORT` | `8000` | server port |
| `UPLOAD_USER` | `updrop` | non-root account the server runs as |
| `ENABLE_MONITOR` | `1` | deploy the health-check timer |
| `HC_INTERVAL` | `5min` | monitor cadence |

## How it works

`setup` writes and enables:

- **`ap-ip.service`** — assigns the static IP to `wlan0`
- **`hostapd`** — the access point (with a restart-guard drop-in for the boot race)
- **`dnsmasq`** — DHCP for clients
- **`updrop.service`** — the upload server, non-root + sandboxed
- **`pi-ap-healthcheck.timer`** — periodic stack checks

`wlan0` is removed from NetworkManager's control so hostapd owns it.

## Security notes

- **Change the default SSID/PSK.** `pidropbox`/`pidropbox` are placeholders for testing.
- **Hidden ≠ secure.** `HIDDEN=1` only omits the SSID from beacons; it still leaks in probe/association frames and is trivially recovered (`airodump-ng`). Treat it as cosmetic.
- Isolated AP by default — no route to any other network.
- The upload server has **no authentication** — anyone associated to the AP can upload and download. That's fine for an isolated, trusted drop; add HTTP Basic auth + TLS before exposing it anywhere less trusted. It does run as a non-root user under a systemd sandbox (`ProtectSystem=strict`, `NoNewPrivileges`, writable only within `UPLOAD_DIR`).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| SSID only visible right next to the Pi | TX power capped (regdomain not applied) | v0.5 sets `COUNTRY` + `ieee80211d=1`; check `pi-ap show` → TX power should read ~20 dBm |
| SSID not visible at all | not broadcasting / hostapd down | `pi-ap show` (Hidden=0? hostapd active?), `pi-ap status`, `journalctl -u hostapd -e` |
| hostapd dead after a reboot | interface/regdom not ready at boot | handled by the restart-guard drop-in; inspect `journalctl -u hostapd` |
| Client connects but gets no IP | dnsmasq | `journalctl -u dnsmasq`, `cat /var/lib/misc/dnsmasq.leases` |
| "No internet" warning on client | expected — isolated AP | stay connected |
| Range still poor at full power | onboard antenna limit | USB adapter with an external antenna (MT7612U / RTL8812AU / AR9271); set `IFACE` accordingly |

## License

MIT — see `LICENSE` (add one).

