# Yatagarasu / RPid-dropbox — Handover & Context Guide

> **Purpose:** hand this project to a fresh chat with zero prior context. This doc is
> self-contained — attach it (or paste it) into the new session and it should be able to
> pick up work without re-deriving anything. Last updated: 2026-10-11.

---

## 0. Seed prompt for the next chat (copy-paste)

```
I'm continuing work on Yatagarasu (GitHub repo: RPid-dropbox) — a portable Raspberry Pi
Wi-Fi access point + wired-Ethernet drop with a streaming HTTP file-drop server.
Read the attached HANDOVER.md for full context before doing anything.

Current state: AP control script v0.12, Go server updrop.go v0.2, and a NEW second mode —
pi_bridge_setup.sh v0.4 (transparent bump-in-the-wire bridge), now under first hardware
bring-up on a 2-NIC rig (eth0=server, usb0=router). Stealth + karasu.local drop work;
server-side internet passthrough is INTERMITTENT and unconfirmed. Repo has uncommitted work.
Next milestones: nail down passthrough (likely a single-client/USB-tether uplink); then
v2 of the server = auth + TLS. See section 0.5 for the exact resume point.

My ask: <state what you want to do>
```

---

## 0.5 Session resume — bridge-mode first hardware bring-up (2026-10-11)

**Rig under test:** Pi (hostname `karasu`) with `eth0` = server side, `usb0` = USB-Ethernet = router
side. No `eth2` mgmt NIC yet (`ENABLE_MGMT=0`). `wlan0` AP exists but weak range. Management for
the test is the **console** (driving `up`/`down` over a bridged NIC kills the session). Operator laptop
= a Mac on `eth0` playing the "server" role. A `tmux` session (`config`, `tcpdump` windows) is kept so
captures survive the Pi going dark when the bridge mutes `usb0`.

**Rig facts learned:** router = `192.168.0.1`, subnet `192.168.0.0/24`, router MAC `0c:7f:b2:62:fc:a7`.
Pi `usb0` MAC `e2:01:50:75:59:05`. So `KARASU_IP=192.168.0.254` is CORRECT for this rig (free host in
the server/router subnet). `detect` misreported `192.168.160.x` because the Pi's own AP-mode DHCP on
`eth0` was still feeding the Mac — ignore `detect` on a bench where AP mode is live.

**What works (verified):**
- `up` builds `br0` (eth0+usb0), applies stealth, serves the drop. `karasu.local` + `http://192.168.0.254/`
  reach updrop from the server side. `verify_stealth` gates a leaky bring-up.
- Stealth: once `up` completes, the Pi is muted on `usb0` (its own uplink dies — expected; that's how we
  know the `-o usb0 DROP` rule landed). No Pi-origin frames on the router port.
- `down` now restores the AP baseline (`eth0`→`192.168.160.1`, dnsmasq) with no reboot (v0.4 fix).

**LIKELY ROOT CAUSE of flaky passthrough — the NM leak (fixed in v0.4):** `usb0` is a `cdc_ncm`
**USB-Ethernet adapter cabled to the operator's REAL router** (single Ethernet cable router→adapter;
`driver: cdc_ncm` is just how this adapter presents — NOT a phone tether, so "single-client" was a red
herring). The real bug: NetworkManager kept `usb0` managed despite the unmanaged conf (`nmcli device
status` showed it `connected`), so after `up` flushed it, NM re-leased `192.168.0.54` + the default route
and the Pi **half-routed** — it kept its own uplink and competed with the forwarded Mac (pinging from the
Pi "stole" the path → the Mac dropped). v0.4 forces `nmcli device set <nic> managed no` on `up`, so the
Pi can no longer hold the router NIC. **Not yet re-tested with that fix** — expected to pass now.

**Next step (retest, current layout is a valid test bed):** from the console, `up`, then from the Mac
(on eth0=server) renew DHCP and `ping 8.8.8.8`; the Pi itself should be OFFLINE while bridged (the proof
stealth is correct). Capture with `tcpdump -i usb0 -e -nn 'arp or port 67 or port 68 or icmp'` → `down` →
read it. If it still drops only when the Pi touches the internet, look for a remaining leak, not a tether.

**Optional reliability tweak (operator's idea):** put the ROUTER side on the **built-in eth0** (direct
cable) and the SERVER + ops-laptop on USB adapters, so the critical uplink/forwarding path is on the
quirk-free built-in NIC. Config: `RTR_IFACE="eth0"`, `SRV_IFACE="usb0"`. Not required to fix the bug.

**Still open:**
- Passthrough not yet confirmed on a real uplink *with the NM fix* (retest pending — above).
- EAPOL/802.1X pass-through, fail-open relay, wlan0-OOB-DHCP-in-bridge-mode (see §8) — all still design-only.

**v0.4 changes made this session (all in `pi_bridge_setup.sh`, uncommitted):**
- `strip_member_l3` — `up` flushes IP+routes off both bridge members (killed a half-routing leak where
  the Pi kept `usb0`'s `192.168.0.54` + default route and emitted its own MAC/IP/IPv6 to the router).
- `stop_ap_conflicts` — `up` stops AP-mode `dnsmasq`/`eth-ip` (once `eth0` is bridged the AP dnsmasq is a
  **rogue DHCP** on the server segment — the real cause of the earlier "internet flaky" symptom).
- `verify_stealth` — abort + tear down if the core `-o usb0 DROP` rule didn't apply.
- `restore_ap` — `down` restarts `eth-ip`+`dnsmasq` and re-enables IPv6 on the members (no reboot).
- NM force-release — `up` runs `nmcli device set <nic> managed no` (a reload alone left `usb0` managed, so
  NM re-leased it and the Pi half-routed); `down` hands the router NIC back to NM + removes the conf.
- `KARASU_IP` doc rewritten: it is per-deployment/ephemeral, must be a FREE host IN the server subnet,
  must not collide with server/gateway/DHCP-pool/live-host/MGMT subnet; `KARASU_PREFIX` must match.

**`KARASU_IP` is NOT a conflict with a `.54`:** `.254` and `.54` are different hosts in one `/24`. In a
correct bridge `usb0` has NO IP at all (v0.4 flushes it), so only `br0`'s `.254` exists. Max-stealth
alternative = give `br0` no IP and reach updrop only over wlan0/mgmt.

---

## 1. What this is

**Yatagarasu** is a portable Raspberry Pi appliance that is, at once:

- a **Wi-Fi access point** (`hostapd` + `dnsmasq`),
- a **wired-Ethernet drop** for a workstation on `eth0`, and
- a **streaming HTTP file-drop server** (`updrop`, Go) that both sides read/write.

The point: move files between a wired workstation and field laptops with no external
infrastructure — the Pi *is* the network. Red-team / field use on authorized engagements.

It now runs in **one of three mutually-exclusive wired roles** (the Wi-Fi AP + updrop drop
are common to both):

- **AP mode** (`pi_ap_dropbox_setup.sh`, original) — the Pi *is* the network: it hands out
  addressing on wlan0 + eth0 and clients connect to it.
- **Bridge mode** (`pi_bridge_setup.sh`, new) — the Pi is a **transparent L2 bump-in-the-wire**
  inserted between a server and its router. It forwards the server's frames verbatim (same MAC +
  IP to the router, like an unplug/replug), stays mute on the router-facing port, and answers only
  `http://karasu.local` on the server side for the drop. The AP + updrop become the out-of-band
  management / loot plane on wlan0. Use case: drop a file plane onto a server's link without the
  server's address changing and without a new identity appearing to MAC-watching monitoring.

| Name | Meaning |
|---|---|
| **Yatagarasu** | product name (Japanese lore — the three-legged guiding crow; nod to RavenSec) |
| **karasu** | device hostname / network identity → reach it at `http://karasu/` (or `.local`) |
| **RPid-dropbox** | the GitHub repo name (kept as-is) — `github.com/d3vn0mi/RPid-dropbox` |
| **updrop** | the Go server component (binary, systemd service, service user, `/srv/updrop`) — internal name, not rebranded |
| author | **d3vn0mi** |

---

## 2. Repo layout & where things live

Repo on disk (owner's Mac, via the desktop bridge):
`/Users/isomarakis/d3vn0mi-workspace/src/red/RPid-dropbox`

| File | Role |
|---|---|
| `pi_ap_dropbox_setup.sh` | **AP-mode control script** (v0.12). `setup` provisions everything; also installs itself as `/usr/local/bin/pi-ap` for live ops |
| `pi_bridge_setup.sh` | **bridge-mode control script** (v0.4). Transparent L2 bridge + stealth + confined `karasu` service + **out-of-band mgmt NIC** (`MGMT_IFACE`/`MGMT_IP`, kept out of the bridge). `up`/`down`/`status`/`detect`. v0.4 = first-hardware fixes (member-IP flush, AP-conflict stop, NM force-release, stealth verify, reversible `down`). **Stealth + drop work; passthrough needs a real (non-tether) uplink** — see §0.5 |
| `pi_intercept_setup.sh` | **intercept-mode control script** (v0.1). THIRD role: inline **active MITM** — bridge (WS_IFACE+UP_IFACE) with `br_netfilter`+`ip_forward` ON, `br0` takes a real **corporate IP**, workstation :80 (+:443) `REDIRECT`ed to a local **mitmproxy** addon that rewrites one exact URL. **Not stealthy** (Pi is a visible host; HTTPS needs its CA installed on the target). Keeps the **AP + mgmt-cable** plane for the ops laptop. `up`/`down`/`status`/`ca`. **UNVALIDATED on hardware** — bench-test first |
| `updrop.go` | **the server** (v0.2). Single-file Go stdlib; compiles to one static binary |
| `pi_ap_healthcheck.sh` | layered health check (services/AP/DHCP/HTTP/upload), run by a systemd timer and `pi-ap status` |
| `README.md` | full runbook (features, quick start, building, ops, uplink/NAT, config, endpoints, security, troubleshooting) |
| `LICENSE` | MIT © 2026 d3vn0mi |
| `.gitignore` | ignores the compiled `updrop` binary + build/editor cruft |

Filenames are **canonical / unversioned** (no `_v0.3` suffixes in the repo) — versions live in each file's top comment + changelog. `next_version.md` is scratch (the bridge-mode design discussion) — not part of the shipped repo. Git state at handover: **uncommitted** — `README.md` / `pi_ap_dropbox_setup.sh` / `pi_ap_healthcheck.sh` modified (v0.11 name-resolution fix + v0.12 subnet move), `pi_bridge_setup.sh` + `HANDOVER.md` + `next_version.md` untracked. Prior history: 3 commits (`init` → rebrand+LICENSE+gitignore → "updated go server and readme").

---

## 3. Topology / how it's wired

```
                 ┌─────────────────── Raspberry Pi (Yatagarasu) ───────────────────┐
  laptops  )))  wlan0  AP 192.168.150.1/24  (SSID "karasu", WPA2)                   │
                 │                                                                   │
  workstation ── eth0  192.168.160.1/24  (Pi runs DHCP on a DIRECT cable only)      │
                 │                                                                   │
  internet  ──── uplink NIC (eth1/usb0/wlan1)  ← NM-managed, holds the default route │
                 └───────────────────────────────────────────────────────────────┘
        updrop server binds :: (all IPv4+IPv6) → reachable from BOTH client nets
```

AP mode has two sub-modes (set by `SHARE_INTERNET` / toggled live with `pi-ap share`):

| Mode | Default | Clients get | IP forwarding |
|---|---|---|---|
| **Isolated** | ✅ | the drop server only — **no** gateway/DNS, no internet | off |
| **Shared** | — | Pi as gateway + DNS, NAT'd out the uplink | on (1 × MASQUERADE) |

Subnets: `192.168.150.0/24` (Wi-Fi), `192.168.160.0/24` (eth0). Change `AP_IP`/`ETH_IP` if they collide with the uplink LAN.

### Bridge mode (`pi_bridge_setup.sh`) — bump-in-the-wire

```
            ┌──────────────── Raspberry Pi (Yatagarasu, bridge mode) ────────────────┐
 Router ─[eth1]─┐                                                                      │
               ├─ br0  (STP off · IPv6 off · promisc · NO routable id on the wire)     │
 Server ─[eth0]─┘        server frames forwarded verbatim → router sees server MAC+IP  │
            │   br0 holds a HIDDEN service IP (KARASU_IP, in the server's subnet),      │
            │   fenced off eth1 by ebtables → only the SERVER can reach it              │
 mgmt-laptop ─[eth2]  192.168.160.1  = OUT-OF-BAND mgmt, NOT bridged, survives 'up'     │
   laptops )))  wlan0 = AP + updrop  ← second OOB path + loot (unchanged)               │
            └──────────────────────────────────────────────────────────────────────┘
   Core stealth rule: ebtables OUTPUT -o eth1 DROP  → the Pi cannot emit a single frame
   toward the router (no ARP/IPv6/mDNS/BPDU/USB-NIC MAC). All Pi I/O rides wlan0.
```

| | AP mode | Bridge mode |
|---|---|---|
| Wired role | Pi *is* the network (DHCP/DNS to clients) | transparent L2 passthrough between server↔router |
| Router's view | — | **unchanged**: server's own MAC + IP, like unplug/replug |
| Needs | 1 wired NIC | **2 wired NICs** (built-in eth0 + USB3 GbE eth1 on a Pi 4/5) |
| Drop reachable at | `http://karasu/`, `.local`, IPs | `http://karasu.local/` + `KARASU_IP` (server side only); AP side on wlan0 |
| Assumes | — | **passive MAC monitoring, not 802.1X** (no EAPOL pass-through yet) |

**Bridge-mode interfaces (3 NICs):** `eth0`=server + `eth1`=router (both in `br0`); `eth2`=dedicated OOB management on `192.168.160.1/24`, **not** bridged, survives `up` (v0.2). Management options, best→worst: `wlan0` AP (cleanest, no wired footprint) · `eth2` mgmt NIC (`MGMT_IP`) · server-side via `KARASU_IP` (reconnect-after-`up`, costs a MAC on the server segment). `eth1` is never reachable (muted). Mgmt subnet must not overlap the bridged subnet.

---

## 4. Current status — what's done

**Control script `pi_ap_dropbox_setup.sh` (v0.12):**
- AP via hostapd + dnsmasq; static-IP oneshots for wlan0 & eth0; NetworkManager leaves wlan0/eth0 unmanaged (uplink stays managed).
- Correct **TX power** (regulatory domain `CZ` + `ieee80211d=1`) — fixes the "signal only reaches 30 cm" trap.
- Hidden-SSID toggle; hostapd restart-guard drop-in (boot race).
- **mDNS** via Avahi (`karasu.local`) on wlan0+eth0 only.
- **Hostname** op; **eth0 MAC** set-before-plug (`keep|random|specific`, persists).
- **Internet sharing / NAT** (`share on|off|status`): `ip_forward` + iptables `MASQUERADE` + FORWARD, DHCP hands out Pi as gw+DNS, unicast name resolution (`karasu` / `karasu.lan`) via dnsmasq — reliable where Windows `.local`/mDNS is flaky.
- Non-root sandboxed `updrop` service user; health-check timer.
- Modal: `setup` once, then live ops (no reboot): `ssid|pass|hidden|channel|ethmac|hostname|share|restart|show|status`.

**Server `updrop.go` (v0.2)** — this session's main work:
- **Folders end to end:** browse into subdirs (breadcrumbs, dirs-first, filter, sortable); upload whole folders (picker `webkitdirectory` **and** drag-drop tree) with structure preserved; download any folder — or a multi-select — as a streamed `.zip`.
- **API:** raw `PUT /path`, `GET /?json`, `GET /file?sha`, `GET /healthz`, `POST /zip`, `POST /mkdir|/rename|/delete`.
- **Safety:** path + zip-slip confinement to `-dir`; atomic temp→rename writes; disk-space guard (`-minfree`); `-readonly` kills all writes.
- Streaming multipart upload (constant RAM); zips use `Store` (fast, low CPU on a Pi); graceful SIGTERM shutdown.

Rebrand to Yatagarasu/karasu is complete across script, server UI, and README.

**Bridge-mode script `pi_bridge_setup.sh` (v0.1)** — the new pivot, approach "A" (serve
`karasu.local` locally, pass everything else untouched; no Squid):
- `up` builds `br0` enslaving `SRV_IFACE`+`RTR_IFACE`, **STP off**, **IPv6 off** on all three, both
  members promisc, `bridge-nf-call-{ip,ip6,arp}tables=0` so iptables never touches bridged frames.
- **Stealth core:** `ebtables OUTPUT -o <router NIC> DROP` — the Pi emits nothing toward the router.
  Plus FORWARD rules fencing `KARASU_IP` (ARP + IPv4, both directions) off the router port, and a
  spare BPDU drop.
- **Confined service:** `br0` holds `KARASU_IP` (a free address *in the server's subnet*), Avahi
  advertises `karasu.local` on `br0`, updrop (already bound `::`) serves it — reachable from the
  server, invisible to the router.
- `detect` sniffs the server side (~8 s tcpdump) to suggest the subnet + a free `.254`.
- Optional `CLONE_SERVER_MAC` (default **off**) clones the server MAC onto the router NIC —
  belt-and-suspenders only; the bridge already preserves the server's src MAC, so the real work is
  *silencing the Pi*, not spoofing.
- `down`/`status`; `status` prints the router-side verification checklist + mgmt-NIC state.
- **(v0.3) `ALLOW_SERVER_PORTS`:** restrict what the SERVER side can reach *on the Pi* (`KARASU_IP`) via an `iptables` INPUT filter on `br0` (custom chain `UPDROP_BRIN`). Locally-delivered traffic only, so L2 transparency is untouched; pass-through is unaffected (bridged, `bridge-nf=0`). **Bench default `"22 80"`** = SSH over the server side without a 3rd NIC; **field = `"80"`** hides SSH; empty = no restriction. `status` prints the chain; `up` warns when 22 is open.
- **(v0.2) dedicated OOB mgmt NIC:** `MGMT_IFACE`/`MGMT_IP` (default `eth2` / `192.168.160.1/24`), kept out of `br0` with a static IP, optional tiny dnsmasq (`MGMT_DHCP`) bound to that NIC only. Guards: refuses if `MGMT_IFACE` == a bridge member or is absent, and refuses an obvious same-prefix subnet overlap with the bridged net (does NOT catch mixed-prefix overlaps — pick non-overlapping subnets).
- **NOT validated on hardware** — no second NIC in the build/test env. Syntax-clean, L2 logic
  reasoned, but bench-test before inline use. A Pi crash = the server's link drops (software bridge,
  no hardware fail-through).

---

## 5. Component reference

### 5a. `pi_ap_dropbox_setup.sh` — CONFIG defaults (top of file)

| Var | Default | Var | Default |
|---|---|---|---|
| `IFACE` | `wlan0` | `ETH_IFACE` | `eth0` |
| `SSID` | `karasu` | `ETH_MAC` | `keep` |
| `PSK` | `yatagarasu` (≥8 chars) | `ETH_IP` | `192.168.160.1` |
| `COUNTRY` | `CZ` | `ETH_DHCP` | `1` |
| `CHANNEL` | `7` | `ETH_DHCP_START/END` | `.50`/`.150` |
| `HW_MODE` | `g` (2.4 GHz) | `SHARE_INTERNET` | `0` (isolated) |
| `HIDDEN` | `0` | `UPLINK_IFACE` | `auto` (default-route NIC) |
| `AP_IP` | `192.168.150.1` | `UPSTREAM_DNS` | `1.1.1.1 8.8.8.8` |
| `DHCP_START/END` | `.50`/`.150` | `LOCAL_DOMAIN` | `lan` |
| `PI_HOSTNAME` | `karasu` | `UPLOAD_DIR` | `/srv/updrop` |
| `ENABLE_MDNS` | `1` | `UPLOAD_PORT` | `80` (portless) |
| `ENABLE_ETH` | `1` | `SERVER_BIND` | `::` (all v4+v6) |
| `ENABLE_MONITOR` | `1` | `HC_INTERVAL` | `5min` |

**What `setup` installs on the Pi:** `/usr/local/bin/pi-ap` (this script), `/usr/local/bin/updrop` (binary), `/usr/local/bin/pi_ap_healthcheck.sh`; systemd units `ap-ip`, `eth-ip`, `hostapd`(+`override.conf`), `dnsmasq`, `updrop`, `pi-ap-healthcheck.{service,timer}`, and — share mode only — `pi-ap-nat.service`; configs `/etc/hostapd/hostapd.conf`, `/etc/dnsmasq.d/ap.conf`, `/etc/dnsmasq-ap-hosts` (share), `/etc/sysctl.d/99-pi-ap.conf` (share), `/etc/NetworkManager/conf.d/99-unmanaged-ap.conf`, `/etc/avahi/avahi-daemon.conf`.

### 5b. `updrop.go` — endpoints & flags

| Method / path | Does |
|---|---|
| `GET /<dir>/` | browse HTML; `?zip` folder download, `?json` listing |
| `GET /<file>` | download (Range); `?dl` attachment, `?sha` sha-256 |
| `POST /upload?dir=<sub>` | multipart (field `files`); part filename may be a relative path (folder upload) |
| `PUT /<path>` | raw streamed upload; creates parent dirs |
| `POST /zip` | zip of selected `paths[]` |
| `POST /mkdir`·`/rename`·`/delete` | `path` · `from`,`to` · `path` (repeatable) |
| `GET /healthz` | JSON status/version/free space |

Flags: `-port 8000` · `-dir .` · `-bind ::` · `-readonly` (off) · `-overwrite` (off; default keeps both, adds ` (n)`) · `-maxupload 0` (MB, 0=∞ → `413`) · `-minfree 16` (MB → `507`) · `-version`. Setup runs it as `-port 80 -dir /srv/updrop -bind ::`.

---

## 6. Operate it (cheat sheet)

```bash
# First provision (run from console or a Wi-Fi SSH session — NOT over eth0):
sudo bash pi_ap_dropbox_setup.sh setup

# Deploy a rebuilt server binary (ExecStart is unchanged, no new required flags):
go build -o updrop updrop.go                       # on the Pi; or cross-compile:
GOOS=linux GOARCH=arm64 go build -o updrop updrop.go      # Pi 3/4/5 64-bit
GOOS=linux GOARCH=arm GOARM=7 go build -o updrop updrop.go # 32-bit / Zero 2 W
sudo systemctl stop updrop && sudo install -m755 ./updrop /usr/local/bin/updrop && sudo systemctl start updrop

# Live ops (no reboot):
sudo pi-ap show | status
sudo pi-ap ssid <NAME> | pass <PASS> | hidden on|off | channel <N>
sudo pi-ap hostname <NAME> | ethmac random|keep|AA:BB:CC:DD:EE:FF
sudo pi-ap share on|off|status      # internet sharing (NAT) to clients
```

**Bridge mode** (needs 2 wired NICs; run over Wi-Fi/console, NEVER over the bridged wire):
```bash
# 1. set SRV_IFACE/RTR_IFACE + KARASU_IP in the CONFIG block (detect helps):
sudo bash pi_bridge_setup.sh detect     # sniffs the server side, suggests subnet + a free .254
# 2. go inline:
sudo bash pi_bridge_setup.sh up         # build bridge + stealth + karasu service
sudo bash pi_bridge_setup.sh status     # bridge/members/stealth + router-side verify checklist
sudo bash pi_bridge_setup.sh down       # LAB ONLY — drops the server's link
# money check from the Pi: every egress frame's src MAC must be the SERVER's, never the Pi/USB:
tcpdump -i eth1 -e -nn
```

---

## 7. Gotchas / hard-won lessons (the landmines)

1. **TX power is capped until the regdomain is applied.** Symptom: SSID only visible ~30 cm away. Fix is baked in (`COUNTRY` + `ieee80211d=1` + `raspi-config nonint do_wifi_country`). If it regresses, check `pi-ap show` → TXpower should be ~20 dBm.
2. **dnsmasq's conf-dir parses every file in `/etc/dnsmasq.d/`.** A hosts-format file there crashes dnsmasq (`bad option at line 1`). The unicast-name hosts file therefore lives at **`/etc/dnsmasq-ap-hosts`** (outside the dir), referenced via `addn-hosts=`. Never put non-`.conf` data files in `/etc/dnsmasq.d/`.
3. **Go's `multipart.Part.FileName()` strips the directory path** (RFC 7578 `filepath.Base`). That flattened folder uploads. Fix: read the raw `Content-Disposition` filename via `mime.ParseMediaType(part.Header.Get(...))`, then confine with `resolveWithin`. Don't "simplify" back to `part.FileName()`.
4. **`pi-ap` only exists after `setup` has run** (setup installs it). Before that, call the script by path.
5. **`setup` reassigns eth0's IP** → it will drop an eth0 SSH session. Run from console or Wi-Fi.
6. **Internet sharing is L3, not per-protocol.** One `MASQUERADE` on the uplink covers DNS + HTTP + everything; the only extra is DHCP handing out gateway+DNS (which isolated mode deliberately suppresses). No separate "DNS rule" / "HTTP rule" needed.
7. **No auth / no TLS yet.** Anyone who can reach the port can read, write, **and delete/rename**. Mitigation today: run `-readonly` when only handing files out. This is why v2 = auth + TLS.
8. **Upload collision default is keep-both** (`a.txt` → `a (1).txt`). Pass `-overwrite` to clobber (matters when re-uploading a folder).
9. **Stale `git` lock:** if `git add` fails with `index.lock: File exists` and no git process is running, `rm -f .git/index.lock` (confirm no live git first).
10. **Bare-name resolution needs DHCP option 6.** Pre-v0.11, isolated mode blanked option 6, so `http://<name>/` never resolved (only IP / `.local`). v0.11 hands out the Pi as DNS in isolated mode too (`LOCAL_DNS=1`) with **no upstream** → other names `REFUSED` so dual-homed clients fall through. Never add `server=` lines in isolated mode, and never return NXDOMAIN for foreign names — that would black-hole a dual-homed client's DNS.
11. **The Pi in the field may lag the repo.** A unit provisioned before v0.10 is still hostname/SSID `pidropbox`; the repo default is `karasu`. Fix on the Pi: deploy the new script, `sudo pi-ap hostname karasu`, `sudo pi-ap ssid karasu`.
12. **(Bridge) a bridge preserves the server's source MAC — you do NOT spoof it.** The server's own frames egress carrying the server's MAC+IP already. The leak is anything *the Pi* emits; `ebtables OUTPUT -o <router NIC> DROP` is the whole trick. Never run the Pi + server with the same MAC+IP live simultaneously (CAM flap / ARP conflict) — silent-on-the-wire avoids it.
13. **(Bridge) `KARASU_IP` must be a free address in the SERVER's own subnet**, or the server won't treat `karasu.local` as on-link. Run `detect` first and confirm `.254` is actually free.
14. **(Bridge) assumes passive MAC monitoring, not 802.1X.** If the switch port authenticates, a naive bridge breaks the server's auth or err-disables the port — you need EAPOL transparent pass-through, not in v0.1. Symptom = port drops on insertion.
15. **(Bridge) HTTPS can't be transparently intercepted without SSL-bump** (a CA the server must trust → install footprint + pinning breaks). Approach A dodges this by *not* proxying — it only serves `karasu.local` locally and L2-forwards everything else, 80 and 443 alike.
16. **(Bridge) keep `bridge-nf-call-*tables=0`.** If iptables starts seeing bridged frames you lose pure-L2 transparency and can silently mangle the server's traffic.
17. **(Bridge) the router side must be a real switch/router port, not a single-client NAT uplink.** A phone/USB *tether* (RNDIS/CDC) is single-client (one MAC, NAT) and can't bridge a second host. NOTE: `driver: cdc_ncm` does NOT by itself mean tether — plain USB-ETH adapters use it too; this rig's `usb0` is a cdc_ncm adapter cabled to a real router and is a valid uplink. Reliability tip: prefer the built-in `eth0` for the uplink/forwarding path over a USB adapter.
18. **(Bridge) NetworkManager must actually release the bridge members.** Writing the unmanaged conf + reload leaves an already-active NIC managed (`nmcli device status` still shows it `connected`), so NM re-leases it (IP + default route) after `up` flushes it → the Pi half-routes. v0.4 forces `nmcli device set <nic> managed no` on `up` and hands it back on `down`.
19. **(Bridge) `down` must restore the AP baseline.** Pre-v0.4, `down` left `eth0` bare and `192.168.160.1` only returned after a reboot. v0.4 `restore_ap` restarts `eth-ip`+`dnsmasq`. Never pull the plug on a half-torn-down bridge — run `down`.

---

## 8. Open items / roadmap

Server features were scoped into tiers. **v1 shipped = "Core folders/zip + power UX & API"** (section 4). Not yet built:

**v2 — access control (next, highest value — closes the network-exposure gap):**
- HTTP Basic auth or shared token (gate up/down).
- Optional TLS (self-signed on the fly, `-tls`).
- Mode switch: **blind-drop** (upload-only, no listing) in addition to the existing `-readonly`.
- Audit log (IP, file, size, sha, ts → logfile) — fits the owner's NIS2/ISO habit.
- IP allowlist (confine to the Wi-Fi/eth subnets); basic rate/conn limit.

**Bridge mode (`pi_bridge_setup.sh`) — next steps:**
- **Bench-validate on two-NIC hardware** (highest priority — it's unproven). Rig: laptop-as-server → Pi → switch; confirm from the router side that only the server's MAC+IP appear (test plan is in `next_version.md`).
- **EAPOL / 802.1X transparent pass-through** (the silentbridge move) — required if the port authenticates. Big change; design only so far.
- **Fail-open / hardware fail-through relay** so a Pi crash doesn't drop the server's link.
- **Optional approach "B" (Squid intercept)** only if the owner actually wants to inspect/filter/log the server's HTTP — `br_netfilter` + REDIRECT :80, must be fail-open. Not needed for the current "serve karasu.local, pass the rest" goal.

**v3 — remaining robustness / UX / field extras (deferred):**
- Upload a `.zip` and auto-extract (with zip-slip guard).
- Resumable/chunked upload (`Content-Range`) for multi-GB over flaky Wi-Fi.
- Per-file parallel upload progress (current bar is overall); sha sidecar in listings.
- Inline preview (image/text), QR of the URL, paste-to-upload (Ctrl-V screenshot).
- Ephemeral: auto-delete older than N / wipe-on-shutdown; one-time download links; bandwidth throttle.

---

## 9. Conventions & working style (owner preferences)

- **Be direct**; lead with the answer, then detail. Push back on weak reasoning; flag flawed assumptions. No unrequested disclaimers.
- **Tables** for structured comparisons/checklists. Match a deep technical register (offensive security, AD, OT/ICS, Go) — don't explain basics unless asked.
- **Versioning:** Excel files `v0.01`+ in filename; **PowerShell** scripts `v0.1` (+0.1/change) in filename **and** a top comment block. Default to reusable, versioned, structured output. (In this repo, Go/bash files keep canonical names with the version in the header/changelog.)
- Edit the real files in the connected repo folder and keep them synced; verify (build / `bash -n` / smoke test) before declaring done.

---

## 10. Environment notes

- Work happens in a **cloud session linked to the owner's Mac** via a desktop bridge; the repo folder is mounted and files are written back with the bridge. **The bridge has been flaky this session** — if a sync fails with "device not connected", deliver files into the chat and retry the repo write when it reconnects.
- The Pi itself is **not** the linked machine — deploy steps (build/install/restart) are run by the owner on the Pi (e.g. over SSH).
- Build/verify of `updrop.go` can be done in the cloud workspace (`go build`, cross-compile, smoke test) without the Pi.

**End of handover.**
