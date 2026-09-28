# Yatagarasu

Turn a Raspberry Pi into a standalone Wi-Fi access point **and** a wired-Ethernet drop, with a streaming file-drop server. Laptops join the Wi-Fi, a workstation plugs into Ethernet, and both sides upload/download from the *same* server over HTTP — the Pi *is* the network. Runs fully isolated, or shares its own uplink's internet out to every client.

*Named for **Yatagarasu** (八咫烏), the three-legged guiding crow of myth — a RavenSec relay. Reachable by name at `http://karasu/`. Repo: `RPid-dropbox`.*

Built for portable / field use: one control script with a `setup` mode and live `ops` commands, a dependency-free Go upload server (single static binary, streams straight to disk), and a systemd health-check timer.

## Features

- **Self-contained AP** — `hostapd` + `dnsmasq`, isolated by default; optional one-command internet sharing (NAT) out through an uplink
- **Dual-homed transfer** — Wi-Fi laptops and a wired workstation on `eth0` reach the same server; the Pi is a shared drop between them, no routing needed. The server binds IPv4 **and** IPv6
- **Streaming uploads** — the Go server uses `MultipartReader` → `io.Copy`, so multi-GB files never buffer in RAM; single static binary that cross-compiles to any Pi
- **Folder-aware** — browse into subfolders (breadcrumbs, dirs-first, filter), upload whole folders (picker **or** drag-drop, structure preserved), and download any folder — or a multi-select of items — as a streamed `.zip`
- **Clean web UI** — drag-and-drop with per-transfer progress, a sortable file table, light & dark themes; delete / rename / new-folder from the page; scriptable endpoints (`PUT`, `?json`, `?sha`, `/healthz`) for CLI use
- **Safe by construction** — every path confined to the served dir (traversal + zip-slip can't escape), atomic temp-then-rename writes (no half-files served), disk-space guard, and a `-readonly` switch
- **Modal control** — `setup` once; then `pi-ap ssid|pass|hidden|channel|ethmac|hostname|share|restart|show|status` apply live, no reboot, no re-provision
- **Hardened** — server runs as a non-root `updrop` user under a systemd sandbox
- **Self-monitoring** — health-check timer verifies the whole stack every 5 minutes
- **Correct TX power** — sets the regulatory domain + `ieee80211d=1` so the radio isn't power-capped (the classic "AP only reaches 30 cm" trap)

## Repo layout

| File | Purpose |
|---|---|
| `pi_ap_dropbox_setup.sh` | control script — `setup` (Wi-Fi + eth0) + live ops; installs itself as `/usr/local/bin/pi-ap` |
| `updrop.go` | the upload/download HTTP server — streaming uploads, styled web UI, dual-stack IPv4+IPv6 |
| `pi_ap_healthcheck.sh` | layered health check (services, AP, DHCP, HTTP, upload integrity) |

## Requirements

- Raspberry Pi with Wi-Fi (onboard or USB), Raspberry Pi OS **Bookworm/Trixie** (NetworkManager default)
- A Go toolchain to build the server on the Pi (`sudo apt install golang`), **or** cross-compile it elsewhere and drop the `updrop` binary next to the script
- Root (`sudo`)

## Quick start

```bash
git clone https://github.com/d3vn0mi/RPid-dropbox.git
cd RPid-dropbox
# edit the CONFIG block at the top of pi_ap_dropbox_setup.sh (SSID, PSK, COUNTRY, ETH_*, ...)
sudo bash pi_ap_dropbox_setup.sh setup
sudo reboot          # first run only — lets NetworkManager fully release wlan0
```

After reboot:

```bash
sudo pi-ap show      # SSID, channel, TX power, regdomain, service states
sudo pi-ap status    # full health check
```

Connect a client to the SSID, then open `http://karasu.local/upload`.

> First run over SSH: do it from the **console** — setup reassigns both `wlan0` and `eth0`, so an SSH session riding either interface will drop.

## Building the server

`setup` builds it automatically if `go` is present. To cross-compile from another machine and skip installing Go on the Pi:

```bash
GOOS=linux GOARCH=arm64 go build -o updrop updrop.go        # Pi 3/4/5, 64-bit OS
GOOS=linux GOARCH=arm GOARM=7 go build -o updrop updrop.go  # 32-bit OS / Zero 2 W
```

Drop the resulting `updrop` binary next to the script; `setup` installs it as-is.

## Managing it

`setup` installs the script as `pi-ap`. These are **live** changes — they edit the deployed config and restart only what's needed, no reboot:

| Command | Action |
|---|---|
| `sudo pi-ap show` | SSID, hidden, channel, TX power, regdom, Wi-Fi + eth0 IP/MAC, bind, services |
| `sudo pi-ap status [args]` | run the health check (`--strict`, `--no-upload`, …) |
| `sudo pi-ap ssid <NAME>` | change SSID |
| `sudo pi-ap pass <PASS>` | change WPA2 passphrase (8–63 chars) |
| `sudo pi-ap hidden <on\|off>` | toggle SSID broadcast |
| `sudo pi-ap channel <N>` | change channel |
| `sudo pi-ap ethmac <keep\|random\|MAC>` | set eth0's MAC (live + persists) — do it before plugging in the cable |
| `sudo pi-ap hostname <NAME>` | set the Pi hostname → `<NAME>.local` |
| `sudo pi-ap share <on\|off\|status>` | share the Pi's internet to clients (NAT via the uplink) / go back to isolated |
| `sudo pi-ap restart` | restart the whole stack |

Every hostapd-affecting change is verified — if it fails to come back up (e.g. an invalid passphrase), you're told immediately instead of silently losing the AP.

## Common tasks

**Deploy a new server build.** systemd runs `/usr/local/bin/updrop`, so a rebuilt binary has to be copied there. You can't overwrite a running executable (`Text file busy`), so stop it first:

```bash
go build -o updrop updrop.go            # or cross-compile — see "Building the server"
sudo systemctl stop updrop
sudo install -m755 ./updrop /usr/local/bin/updrop
sudo systemctl start updrop
journalctl -u updrop -n 3 --no-pager    # confirm it came up
```

No-downtime variant (atomic replace, no stop):

```bash
sudo install -m755 ./updrop /usr/local/bin/updrop.new
sudo mv -f /usr/local/bin/updrop.new /usr/local/bin/updrop
sudo systemctl restart updrop
```

Or let the script do build + install + restart: `sudo bash pi_ap_dropbox_setup.sh setup`.

**Make the network hidden (or visible)** — live, no reboot:

```bash
sudo pi-ap hidden on       # stop broadcasting the SSID
sudo pi-ap hidden off      # broadcast again
```

Manual equivalent:

```bash
sudo sed -i 's/^ignore_broadcast_ssid=.*/ignore_broadcast_ssid=1/' /etc/hostapd/hostapd.conf  # 1=hidden, 0=visible
sudo systemctl restart hostapd
```

Hidden clients must be added by exact name (see "Connecting a client").

**Change SSID / password / channel** — live:

```bash
sudo pi-ap ssid lab-drop
sudo pi-ap pass 'newsecret123'     # 8–63 chars
sudo pi-ap channel 6               # 1/6/11 are non-overlapping
```

Each rewrites `hostapd.conf`, restarts hostapd, and verifies it comes back; clients then reconnect.

**Set the eth0 MAC before connecting the cable.** Random (fresh, locally-administered) or a specific address — applied live and persisted for next boot:

```bash
sudo pi-ap ethmac random               # fresh random MAC now (a new one again each reboot)
sudo pi-ap ethmac 02:11:22:33:44:55    # a specific MAC
sudo pi-ap ethmac keep                 # revert to the hardware MAC
```

Do it *before* you plug in — it bounces `eth0` down/up. `sudo pi-ap show` prints the current `Eth0 MAC`. (Or bake a default in with `ETH_MAC` in the CONFIG block.)

**Give clients internet through the Pi** — when the Pi has its own uplink and the clients (workstation on `eth0`, laptops on Wi-Fi) have none of their own:

```bash
sudo pi-ap share on        # NAT clients out through the uplink; hand out the Pi as gateway + DNS
sudo pi-ap share status     # uplink, ip_forward, MASQUERADE present?
sudo pi-ap share off        # back to isolated (no internet, drop server only)
```

`share on` is idempotent and survives reboot (a `pi-ap-nat.service` re-applies the rules). The uplink is auto-detected (the NIC holding the default route); if detection fails, set `UPLINK_IFACE` in the CONFIG block (e.g. `eth1`, `wlan1`, `usb0`) and re-run. After turning it on, clients must **renew their DHCP lease** (reconnect, or unplug/replug the cable) to pick up the gateway + DNS. In share mode the Pi also answers `http://karasu/` and `http://karasu.lan/` over normal DNS — handy when Windows mDNS (`.local`) is flaky.

**Apply a change made in the CONFIG block.** Re-run setup — it's restart-aware, applies everything, reinstalls the `pi-ap` shortcut, and re-verifies:

```bash
sudo bash pi_ap_dropbox_setup.sh setup
```

(A bare `systemctl restart` won't pick up a CONFIG change until the file is rewritten — re-running setup rewrites *and* restarts.)

**Inspect state / restart everything.**

```bash
sudo pi-ap show       # SSID, hidden, channel, TX power, regdom, Wi-Fi + eth0 IPs, bind, services
sudo pi-ap status     # full health check (add --no-upload for read-only)
sudo pi-ap restart    # bounce the whole stack
```

## Upload / download / manage

Everything works from the web UI (`http://karasu/`) — drag files **or whole folders** onto the page (or use **Upload files** / **Upload folder**), browse into subfolders, tick items to download or delete, and grab any folder as a zip. It's also fully scriptable:

```bash
# upload files (field 'files'; multiple allowed)
curl -F 'files=@disk.img' http://karasu/upload
curl -F 'files=@a' -F 'files=@b' http://karasu/upload

# raw streamed upload — nicer for one big file (creates parent dirs)
curl -T ./loot.tar http://karasu/cases/2026/loot.tar

# download a whole folder as a streamed zip
curl -o cases.zip 'http://karasu/cases/?zip'

# machine-readable listing + integrity
curl 'http://karasu/?json'
curl 'http://karasu/cases/loot.tar?sha'      # sha-256 of one file
```

Uploaded files land in `/srv/updrop` (owned by the `updrop` user).

**Endpoints**

| Method / path | Does |
|---|---|
| `GET /<dir>/` | browse (HTML); `?zip` downloads the folder, `?json` returns a listing |
| `GET /<file>` | download (Range-enabled); `?dl` forces attachment, `?sha` returns sha-256 |
| `POST /upload?dir=<sub>` | multipart upload (field `files`); a part's filename may be a **relative path** (folder upload) |
| `PUT /<path>` | raw streamed upload; creates parent dirs |
| `POST /zip` | stream a zip of selected `paths[]` (multi-select download) |
| `POST /mkdir` · `/rename` · `/delete` | form ops — `path` · `from`,`to` · `path` (repeatable) |
| `GET /healthz` | JSON: status, version, free space (cheap liveness probe) |

**Server options** (flags on the `updrop` binary — set them in `updrop.service`'s `ExecStart`, or when running by hand)

| Flag | Default | Notes |
|---|---|---|
| `-port` / `-dir` / `-bind` | `8000` / `.` / `::` | listen port, served dir, bind address (setup passes `80 /srv/updrop ::`) |
| `-readonly` | off | disable **all** writes (upload/PUT/mkdir/rename/delete) — browse + download only |
| `-overwrite` | off | overwrite on name collision (default: keep both, add ` (n)`) |
| `-maxupload` | `0` | max MB per uploaded file (0 = unlimited) → clean `413` when exceeded |
| `-minfree` | `16` | refuse writes when free space would drop below this many MB → `507` |
| `-version` | — | print version and exit |

Safety is always on: every path is confined to `-dir` (directory traversal and zip-slip can't escape it), uploads are written to a temp file and atomically renamed (a half-transfer is never listed or served), and the disk guard stops a runaway upload from filling the card.

## Connecting a client

Broadcast SSID: just pick it from the Wi-Fi list. Hidden SSID (`HIDDEN=1`): enter the name manually.

```bash
# Linux (NetworkManager) — works for hidden networks too:
sudo nmcli connection add type wifi con-name karasu ifname wlan0 ssid "karasu" \
  802-11-wireless.hidden yes wifi-sec.key-mgmt wpa-psk wifi-sec.psk "yatagarasu"
sudo nmcli connection up pidrop
```

- **macOS:** `networksetup -setairportnetwork en0 karasu yatagarasu` (works for hidden), or Wi-Fi menu → Other…
- **Windows:** add the network manually and tick *connect even if not broadcasting*.

Clients get a `192.168.50.x` lease and **no internet** — expected, it's an isolated AP.

## Reach it by name

The server listens on **port 80** and the Pi advertises itself over **mDNS**, so from any connected machine you just open:

```
http://karasu.local/
```

No IP, no port. `.local` is resolved by mDNS — built in on macOS (Bonjour) and Windows 10+, and via `avahi` + `libnss-mdns` on Linux. The name is advertised **only on Wi-Fi and `eth0`**, never on an uplink NIC. Rename with `sudo pi-ap hostname <NAME>` (or `PI_HOSTNAME` in the config). Want a port instead? Set `UPLOAD_PORT` and use `http://karasu.local:PORT/`.

**If `.local` won't resolve** (common on Windows with multiple NICs, or where mDNS is filtered) but the IP works: that's an mDNS problem, not a server problem. The reliable fix is to let the Pi serve **unicast DNS** — turn on internet sharing (`sudo pi-ap share on`, see below) and the Pi hands itself out as the DNS server and answers `http://karasu/` and `http://karasu.lan/` directly, no mDNS involved. `localise-queries` returns the Pi's address on the *same subnet* as the asking client (`192.168.60.1` on the wire, `192.168.50.1` on Wi-Fi), so the name always points at the interface the client is actually on.

## Wired workstation (dual-homed transfer)

Plug the workstation into the Pi's `eth0` with a direct cable. The server listens on `::` (all interfaces), so once `eth0` has an address the workstation reaches the **same** drop the laptops use — upload from one side, download from the other. No routing between the Wi-Fi and the wire is needed.

`setup` gives `eth0` a static `192.168.60.1` and (with `ETH_DHCP=1`) runs DHCP on it — safe because it's a dedicated cable. By default it hands out **no default gateway or DNS**, so it never disturbs the workstation's real network. (If the workstation should instead get its *internet* from the Pi, see **Uplink & internet sharing** below — `share on` flips the DHCP to hand out the Pi as gateway + DNS.) Three ways to get the workstation on the link:

| Method | Workstation side | Reach the server at |
|---|---|---|
| **DHCP (auto)** | leave the adapter on "Obtain IP automatically" (default) | `http://karasu.local/` or `http://192.168.60.1/` |
| **Static** | set the adapter to `192.168.60.2` / `255.255.255.0`, no gateway | `http://karasu.local/` or `http://192.168.60.1/` |
| **IPv6 link-local** | nothing — both ends self-assign `fe80::` | `http://[<pi-eth0-fe80>%<zone>]/` |

**Windows, static:**

```
netsh interface ip set address name="Ethernet" static 192.168.60.2 255.255.255.0
```

(use the adapter name from `netsh interface show interface`).

**Windows, IPv6 link-local:** read the Pi's `eth0` link-local from `sudo pi-ap show` (the `Eth0 v6` line), find the Windows interface index with `netsh interface ipv6 show interfaces`, then browse `http://[fe80::…%<index>]/`. Browsers are fiddly about the `%zone` in a URL (Edge/Chrome may want it written `%25<index>`); `curl` handles it cleanly. For everyday browser use, DHCP or static is smoother.

`sudo pi-ap show` prints the current `eth0` MAC, v4/v6 addresses, and the server bind. To spoof the MAC before plugging in (random or a specific address), see **Common tasks** or set `ETH_MAC` in the CONFIG block.

## Uplink & internet sharing

Give the Pi its own internet by plugging a **second NIC** (e.g. a USB Ethernet `eth1`, or a Wi-Fi dongle `wlan1` as a client) into an upstream network — the script never touches it. Only `wlan0` and `eth0` are taken from NetworkManager, so any other interface stays a normal NM-managed DHCP client and the Pi gets internet (and a default route) there.

From there you pick one of **two modes**, depending on whether the clients have their own internet:

| Mode | `pi-ap share` | eth0/Wi-Fi DHCP hands out | IP forwarding | Use when |
|---|---|---|---|---|
| **Isolated** (default) | `off` | no gateway, no DNS | off | Clients have their own internet; the Pi is a pure transfer drop and must not touch their routing |
| **Shared** | `on` | Pi as gateway + DNS | on (NAT) | Clients have **no** internet of their own and should reach it *through* the Pi |

### Isolated (default)

- The Pi's `eth0`/Wi-Fi DHCP hands out **no default gateway and no DNS**, so it can never become a client's default route — each client's own NIC stays its path to the internet/corporate net.
- The Pi does **not** forward between interfaces (IP-forwarding off), so the Wi-Fi net, the `eth0` link, and the uplink stay isolated.
- mDNS is advertised only on `wlan0`+`eth0`, so `karasu.local` never leaks onto the uplink.

### Shared (`sudo pi-ap share on`)

Turns the Pi into a router for its clients. This is the setup where the workstation has no internet of its own and gets it from the Pi:

- **`net.ipv4.ip_forward=1`** (persisted in `/etc/sysctl.d/99-pi-ap.conf`).
- **One `iptables` NAT rule** — `MASQUERADE` on the uplink — carries *all* client traffic out: DNS, HTTP, HTTPS, everything. There is **no** per-protocol rule; NAT is L3, so DNS and HTTP ride the same rule. Plus `FORWARD` rules allowing `wlan0`/`eth0 → uplink` and the `RELATED,ESTABLISHED` replies back.
- **DHCP now hands out the Pi as gateway *and* DNS.** dnsmasq resolves for the clients by forwarding to `UPSTREAM_DNS` (default `1.1.1.1`, `8.8.8.8`) over the Pi's own uplink — so no separate DNS iptables rule is needed either.
- **Name resolution comes for free:** clients also resolve `http://karasu/` and `http://karasu.lan/` via the Pi over unicast DNS (bypasses flaky Windows `.local`/mDNS).
- Rules are re-applied at every boot by `pi-ap-nat.service`, and `share off` tears all of it back down (including `ip_forward`).

```bash
sudo pi-ap share on        # enable NAT + gateway/DNS
sudo pi-ap share status     # uplink=? ip_forward=? masquerade present?
# on the workstation: renew DHCP (ipconfig /renew, or replug the cable) to pick up the new gateway
```

Uplink is auto-detected as the NIC holding the default route. If you have several, set `UPLINK_IFACE` explicitly. IPv4-only (no IPv6 NAT).

Caveat 1: the Pi uses `192.168.50.0/24` (Wi-Fi) and `192.168.60.0/24` (eth0). If your uplink network overlaps either, change `AP_IP`/`ETH_IP` to a free subnet.
Caveat 2: if a host firewall (ufw/nftables) sets the `FORWARD` policy to `DROP` with rules ahead of ours, forwarding can still be blocked — check `sudo iptables -S FORWARD` and make sure the `pi-ap` ACCEPTs aren't shadowed.

## Monitoring

The `pi-ap-healthcheck.timer` runs every 5 minutes (read-only checks):

```bash
systemctl list-timers pi-ap-healthcheck.timer
journalctl -u pi-ap-healthcheck -e
sudo /usr/local/bin/pi_ap_healthcheck.sh      # full check on demand (incl. upload integrity)
```

Exit codes: `0` healthy, `1` a check failed (or any warning under `--strict`), `2` bad argument.

## Configuration

Edit the `CONFIG` block at the top of `pi_ap_dropbox_setup.sh` before `setup`:

| Var | Default | Notes |
|---|---|---|
| `IFACE` | `wlan0` | AP interface (set to your USB adapter, e.g. `wlan1`, if used) |
| `SSID` / `PSK` | `karasu` / `yatagarasu` | **change these** |
| `COUNTRY` | `CZ` | ISO-3166 regulatory domain — drives legal TX power |
| `CHANNEL` | `7` | 2.4 GHz; 1/6/11 are non-overlapping |
| `HW_MODE` | `g` | `g` = 2.4 GHz, `a` = 5 GHz |
| `HIDDEN` | `0` | `1` = don't broadcast the SSID |
| `AP_IP` | `192.168.50.1` | gateway / server address |
| `DHCP_START`–`DHCP_END` | `.50`–`.150` | lease pool |
| `UPLOAD_DIR` | `/srv/updrop` | where uploads are saved |
| `UPLOAD_PORT` | `80` | server port; **80** = portless (`http://karasu.local`) |
| `SERVER_BIND` | `::` | `::` = all IPv4+IPv6, `0.0.0.0` = IPv4 only, or one address |
| `PI_HOSTNAME` | `karasu` | system hostname → reachable as `karasu.local` (mDNS) |
| `ENABLE_MDNS` | `1` | advertise `<name>.local` via Avahi on `wlan0`+`eth0` only (not the uplink) |
| `ENABLE_ETH` | `1` | configure `eth0` for a wired workstation |
| `ETH_IP` | `192.168.60.1` | Pi's fixed address on the wire |
| `ETH_MAC` | `keep` | eth0 MAC before it hits the wire: `keep`, `random`, or a specific `AA:BB:CC:DD:EE:FF` |
| `ETH_DHCP` | `1` | hand the workstation an IP — **safe only on a direct/dedicated cable** |
| `ETH_DHCP_START`–`ETH_DHCP_END` | `.50`–`.150` | wired lease pool |
| `SHARE_INTERNET` | `0` | `1` = NAT clients out to the internet via the uplink (also toggled live with `pi-ap share`) |
| `UPLINK_IFACE` | `auto` | uplink NIC for sharing; `auto` = the default-route NIC (not `wlan0`/`eth0`), or set `eth1`/`wlan1`/`usb0` |
| `UPSTREAM_DNS` | `1.1.1.1 8.8.8.8` | resolvers dnsmasq forwards to in share mode (empty = use the Pi's `/etc/resolv.conf`) |
| `LOCAL_DOMAIN` | `lan` | in share mode, `<PI_HOSTNAME>.<LOCAL_DOMAIN>` also resolves (e.g. `karasu.lan`) |
| `UPLOAD_USER` | `updrop` | non-root account the server runs as |
| `ENABLE_MONITOR` | `1` | deploy the health-check timer |
| `HC_INTERVAL` | `5min` | monitor cadence |

## How it works

`setup` writes and enables:

- **`ap-ip.service`** — assigns the static IP to `wlan0`
- **`eth-ip.service`** — assigns the static IP to `eth0` for the wired workstation (when `ENABLE_ETH=1`)
- **`hostapd`** — the access point (with a restart-guard drop-in for the boot race)
- **`dnsmasq`** — DHCP for Wi-Fi clients (and `eth0` when `ETH_DHCP=1`)
- **`updrop.service`** — the upload server, non-root + sandboxed
- **`pi-ap-healthcheck.timer`** — periodic stack checks
- **`pi-ap-nat.service`** — *only in share mode* — re-applies `ip_forward` + the `MASQUERADE`/`FORWARD` rules at boot

`wlan0` (and `eth0`) are removed from NetworkManager's control so hostapd/dnsmasq own them; the uplink NIC stays NM-managed for its own DHCP + default route. In the default **isolated** mode the Pi never forwards between interfaces; **share** mode turns on `ip_forward` and NATs client traffic out through the uplink.

## Files installed on the system

`setup` creates these. Useful logs: `journalctl -u hostapd` (also `-u dnsmasq`, `-u updrop`, `-u pi-ap-healthcheck`).

| Path | What it is |
|---|---|
| `/usr/local/bin/pi-ap` | the control script (a copy of `pi_ap_dropbox_setup.sh`) — source of the `pi-ap` command |
| `/usr/local/bin/updrop` | the compiled Go server binary that systemd runs |
| `/usr/local/bin/pi_ap_healthcheck.sh` | the health-check script (run by the timer and by `pi-ap status`) |
| `/etc/hostapd/hostapd.conf` | AP config: SSID, PSK, channel, country, `ieee80211d`, hidden flag — the `pi-ap` ops edit this |
| `/etc/default/hostapd` | points hostapd at the conf above (`DAEMON_CONF=`) |
| `/etc/systemd/system/hostapd.service.d/override.conf` | restart-guard drop-in (fixes the boot race) |
| `/etc/dnsmasq.d/ap.conf` | DHCP ranges for `wlan0` (and `eth0` when enabled); isolated = no gateway/DNS, share = Pi as gateway+DNS |
| `/etc/dnsmasq-ap-hosts` | *share mode only* — maps `karasu` → the Pi's per-subnet IPs for unicast name resolution (kept **outside** `/etc/dnsmasq.d/`, which is a conf-dir) |
| `/etc/NetworkManager/conf.d/99-unmanaged-ap.conf` | tells NetworkManager to leave `wlan0`/`eth0` alone |
| `/etc/systemd/system/ap-ip.service` | oneshot: static IP on `wlan0` at boot |
| `/etc/systemd/system/eth-ip.service` | oneshot: static IP on `eth0` (when `ENABLE_ETH=1`) |
| `/etc/systemd/system/updrop.service` | runs the server as the non-root `updrop` user, sandboxed |
| `/etc/systemd/system/pi-ap-healthcheck.{service,timer}` | periodic health check (every `HC_INTERVAL`) |
| `/etc/systemd/system/pi-ap-nat.service` | *share mode only* — re-applies NAT/forwarding at boot |
| `/etc/sysctl.d/99-pi-ap.conf` | *share mode only* — persists `net.ipv4.ip_forward=1` |
| `/srv/updrop/` | the shared drop — uploaded files land here (owned by `updrop`) |
| `/var/lib/misc/dnsmasq.leases` | current DHCP leases (who's connected) |

Also created: a system user `updrop` (nologin) that the server runs as.

## Security notes

- **Change the default SSID/PSK.** `karasu`/`yatagarasu` are placeholders for testing.
- **Hidden ≠ secure.** `HIDDEN=1` only omits the SSID from beacons; it still leaks in probe/association frames and is trivially recovered (`airodump-ng`). Treat it as cosmetic.
- Isolated AP by default — no route to any other network. `pi-ap share on` deliberately reverses this: it enables IP forwarding and NATs clients out through the uplink, so treat the clients as being on the internet from that point. `share off` restores isolation.
- **`eth0` DHCP is for a *direct* cable only.** On a shared network it would be a rogue DHCP server — set `ETH_DHCP=0` and use a static IP there instead. In share mode it *also* advertises a gateway, so double-check you're on a dedicated cable before enabling it.
- The upload server has **no authentication or TLS yet** — anyone who can reach the port can browse, download, upload, **and now delete/rename/mkdir**. That's fine for an isolated, trusted drop; it's the reason auth + TLS are the next milestone. Two mitigations ship today: run it `-readonly` when you only need to hand files *out* (kills every write path), and it still runs as a non-root `updrop` user under a systemd sandbox (`ProtectSystem=strict`, `NoNewPrivileges`, writable only within `UPLOAD_DIR`).
- **Paths are confined, uploads are atomic.** Directory traversal and zip-slip are blocked (every request path is cleaned and re-checked against the served dir, symlinks included); uploads land via temp-then-rename so a half-transfer is never served; and `-minfree` stops an upload from filling the SD card.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| **SSID only reachable right next to the Pi** | TX power capped — regdomain not applied | script sets `COUNTRY` + `ieee80211d=1`; `pi-ap show` → TX power should read ~20 dBm. If not: `sudo raspi-config nonint do_wifi_country <CC>` then `sudo systemctl restart hostapd` |
| **SSID not visible at all** | not broadcasting, or hostapd down | `pi-ap show` (Hidden=0? hostapd active?), `pi-ap status`; `journalctl -u hostapd -e` |
| **Can't see it after `hidden off`** | change not applied, or client cached it as hidden | `pi-ap show` confirms Hidden=0 + hostapd active; on the client forget the network / toggle Wi-Fi; scan from a phone to isolate AP vs client |
| **hostapd won't start after a change** | passphrase <8 chars, or bad channel/country | `journalctl -u hostapd -e`; the `pi-ap pass`/`channel` ops validate and verify restart, so prefer them over hand edits |
| **hostapd dead after a reboot** | interface/regdom not ready at boot | handled by the restart-guard drop-in; if it recurs, `journalctl -u hostapd -b` |
| **A CONFIG/edit didn't take effect** | hostapd/updrop still running the old config | use the `pi-ap` ops (they restart for you), or re-run `setup` (restart-aware); a bare file edit needs `systemctl restart hostapd` |
| **`Text file busy` swapping the binary** | can't overwrite a running executable | `systemctl stop updrop` first, then `install`, then `start` — or the atomic `install .new && mv -f` (see Common tasks) |
| **`pi-ap: command not found`** | `setup` hasn't run yet (it installs the shortcut) | `sudo bash pi_ap_dropbox_setup.sh setup`, or call the script by its path |
| **Client connects but gets no IP** | dnsmasq not serving that interface | `journalctl -u dnsmasq`; `cat /var/lib/misc/dnsmasq.leases`; check `interface=` in `/etc/dnsmasq.d/ap.conf` |
| **"No internet" on client (and you want isolation)** | expected — isolated AP hands out no gateway | stay connected; it's a transfer link, not internet |
| **Workstation has no internet but should get it from the Pi** | share mode off — DHCP hands out no gateway/DNS | `sudo pi-ap share on`, then renew DHCP on the workstation (`ipconfig /renew` or replug). Confirm with `pi-ap share status` |
| **`share on` but clients still have no internet** | uplink not detected, forwarding blocked, or Pi itself offline | `pi-ap share status` (uplink set? `ip_forward=1`? masquerade present?); `ping 1.1.1.1` **from the Pi** first; `sudo iptables -S FORWARD` for a shadowing DROP; set `UPLINK_IFACE` if auto-detect picked wrong |
| **Internet works by IP but names don't resolve (share mode)** | client didn't pick up the Pi as DNS, or upstream DNS unreachable | renew DHCP so option 6 (DNS=Pi) applies; check `UPSTREAM_DNS` is reachable from the Pi; `journalctl -u dnsmasq -e` |
| **Workstation can't reach the server** | server bound to Wi-Fi only, or `eth0` has no address | `pi-ap show` → `Server bind=::` and an `Eth0 IP`; workstation adapter has a `192.168.60.x` (DHCP) or a static IP |
| **IPv6 link-local won't open in a browser** | browsers mangle the `%zone` in URLs | write the zone as `%25<ifindex>` (e.g. `http://[fe80::…%2512]/`), or use `curl`, or just use IPv4 |
| **`karasu.local` doesn't resolve** (IP works) | client-side mDNS problem (common on Windows w/ multiple NICs), or Avahi down | on the Pi: `systemctl status avahi-daemon`, and confirm `eth0` is in `allow-interfaces` (`/etc/avahi/avahi-daemon.conf`); on Linux clients install `avahi-daemon`+`libnss-mdns`. **Reliable fix:** `sudo pi-ap share on` → the Pi serves the name over unicast DNS; browse `http://karasu/` or `http://karasu.lan/` (no `.local`). Else use the IP |
| **Name resolves but page won't load** | server isn't on port 80 | `pi-ap show` → the `Host` line shows the URL; if `UPLOAD_PORT` isn't 80 use `karasu.local:PORT` |
| **Lost SSH during `setup`** | setup reassigns `wlan0` and `eth0` | run setup from the **console**; reconnect over Wi-Fi (`192.168.50.1`) afterwards |
| **Two clients can't see each other** | by design — no routing between Wi-Fi and eth0 | transfer via the drop: one side uploads, the other downloads |
| **Range still poor at full TX power** | onboard antenna limit | USB adapter with an external antenna (MT7612U / RTL8812AU / AR9271); set `IFACE` accordingly |

## License

MIT © 2026 **d3vn0mi**. See [`LICENSE`](LICENSE).
