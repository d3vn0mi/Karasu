# Mode-switch bench test — Yatagarasu `pi-mode`

> Validate every mode and every transition on the bench **before** any field use.
> `pi-mode` is `bash -n` clean but **unvalidated on hardware**; this is how you prove it.
> Status legend: ☐ not run · ✅ pass · ❌ fail (note what you saw).

---

## 0. Rig & safety

```
            ┌──────────────── Raspberry Pi (karasu) ────────────────┐
 "server/   │  eth0 (WIRED_IFACE)  ── built-in NIC                   │
  workstn"  │  usb0 (SECOND_IFACE) ── USB3 GbE NIC                   │
  (a laptop)│  eth2 (MGMT_IFACE)   ── optional OOB mgmt cable        │
            │  wlan0 (WLAN_IFACE)  ── Wi-Fi AP + updrop (OOB plane)  │
 router/sw ─┘                                                        │
```

- **Drive everything from the console, wlan0, or the eth2 mgmt cable — NEVER over the wire you are bridging**, and never over wlan0 when switching to `clean` (that tears down the AP you are on). Every `pi-mode <target>` **reboots by default**, which drops all sessions — expected.
- Keep a `tmux` session with a `tcpdump` window so captures survive the Pi going quiet (bridge mode mutes `usb0`).
- Have a second device (phone) to scan for the SSID, and access to the router/switch to read its MAC + ARP tables.

---

## 1. Prep (once)

- ☐ AP baseline provisioned: `sudo bash pi_ap_dropbox_setup.sh setup` → reboot once.
- ☐ `pi_mode.conf` roles match the rig (`WIRED_IFACE`/`SECOND_IFACE`/`MGMT_IFACE`/`WLAN_IFACE`).
- ☐ Install the switcher: `sudo bash pi_mode_setup.sh install` → `sudo pi-mode status` shows `boot-apply unit : enabled`.
- ☐ For bridge: set a correct `KARASU_IP` (free host in the server's real subnet) in `pi_bridge_setup.sh`.
- ☐ For intercept HTTPS: plan to install the mitmproxy CA on the target (`sudo pi-intercept-setup ca`).

---

## 2. Per-mode bring-up

### AP — `sudo pi-mode ap`
- ☐ `pi-mode status` → selected=ap, live=ap; `hostapd/dnsmasq/updrop/ap-ip/eth-ip` active.
- ☐ Phone sees SSID `karasu`; a Wi-Fi client gets `192.168.150.x`; `http://karasu/` loads updrop.
- ☐ Laptop on `eth0` gets `192.168.160.x`; reaches `http://192.168.160.1/`.
- ☐ `cat /proc/sys/net/ipv4/ip_forward` = `0` (isolated) unless `pi-ap share on`.

### Bridge — `sudo pi-mode bridge`
- ☐ `pi-mode status` → live reports bridge; `br0` up, `eth0`+`usb0` enslaved; `eth-ip`/`dnsmasq` **inactive**.
- ☐ `ebtables -t filter -L OUTPUT` shows the `-o usb0 … DROP` rule.
- ☐ `cat /proc/sys/net/ipv4/ip_forward` = `0`.
- ☐ **Money check, from the Pi:** `tcpdump -i usb0 -e -nn` → every egress frame's src MAC is the **server's**, never the Pi/USB MAC; no IPv6/mDNS/BPDU from the Pi.
- ☐ **From the router/switch:** the port shows only the server's MAC; ARP maps the server IP → server MAC; nothing new.
- ☐ Server reaches `http://<KARASU_IP>/` and `http://karasu.local/`; normal server traffic (ping gateway, browse) still works.
- ☐ wlan0 AP still up as OOB.

### Intercept — `sudo pi-mode intercept`
- ☐ `pi-mode status` → live reports intercept; `br0` has a **corporate IP**; `ip_forward`=`1`; `bridge-nf-call-iptables`=`1`.
- ☐ `iptables -t nat -L PREROUTING -n` shows the `REDIRECT … --to-ports 8080` for `--physdev-in eth0`.
- ☐ `pgrep -af mitmdump` → running as user `mitm`.
- ☐ Workstation browses normally; the one target URL (`TARGET_HOST``TARGET_PATH`) is rewritten.
- ☐ **Exposure check (fix #1):** from a *corporate-side* host, `curl --max-time 3 http://<br0-corp-ip>:80/` → **refused/timed out** (updrop fenced off the corp side). From wlan0/mgmt, updrop still serves.

### Clean — `sudo pi-mode clean`
- ☐ `pi-mode status` → selected=clean, live=clean.
- ☐ `systemctl is-active hostapd` = `inactive`; **phone scan shows NO `karasu` SSID** (no broadcast).
- ☐ `nmcli device status` → `wlan0`/`eth0`/`usb0` all `managed`; `br0` absent.
- ☐ A client cable on `eth0`/`usb0` behaves like stock networking (NM/upstream DHCP); the Pi itself gets its normal uplink.
- ☐ `cat /proc/sys/net/ipv4/ip_forward` = `0`; `iptables -S` has no updrop/REDIRECT/MASQUERADE rules; no `UPDROP_BRIN` chain.

---

## 3. Switch matrix (run each; after every switch run `pi-mode status` + the target's checks in §2)

| From → To | Command | Must verify |
|---|---|---|
| AP → bridge | `sudo pi-mode bridge` | eth-ip/dnsmasq off; bridge checks pass |
| bridge → AP | `sudo pi-mode ap` | eth0 back to `192.168.160.1`; `ebtables -L` empty; `ip_forward`=0 |
| AP → intercept | `sudo pi-mode intercept` | REDIRECT present; updrop fenced off corp |
| intercept → AP | `sudo pi-mode ap` | `ip_forward`=0; no REDIRECT; `pgrep mitmdump` empty |
| bridge → intercept | `sudo pi-mode intercept` | **no stale ebtables DROP** (fix #2); uplink works; REDIRECT present |
| intercept → bridge | `sudo pi-mode bridge` | `bridge-nf-call-iptables`=0; `ip_forward`=0; stealth DROP present |
| any → clean | `sudo pi-mode clean` | no SSID; all managed by NM; no rules |
| clean → AP | `sudo pi-mode ap` | full AP baseline returns |
| clean → bridge/intercept | `sudo pi-mode bridge` / `intercept` | overlay builds from stock |

- ☐ Also run one full cycle **live** (no reboot): append `--now`, e.g. `sudo pi-mode clean --now`, and confirm the same end state (best-effort path).

---

## 4. Reboot persistence

- ☐ In each of ap / bridge / intercept / clean: `sudo reboot`, wait, `sudo pi-mode status` → **live matches the selected marker** (bridge/intercept rebuilt by `pi-mode-apply.service`; clean stays stock; AP comes up as baseline).
- ☐ Reboot while in bridge **with the Pi inline**: confirm the server's link is restored to a working bridge (not left bare) once boot completes.

---

## 5. Regression checks (the bugs this release fixed — do these explicitly)

- ☐ **#1 updrop off corp:** intercept → corp-side `curl http://<br0-ip>/` blocked (see §2 Intercept).
- ☐ **#2/#3 no bridge residue in intercept:** do `bridge` then `intercept`; `ebtables -L` empty, no `UPDROP_BRIN` (`iptables -nL UPDROP_BRIN` → "No chain"), uplink works.
- ☐ **#4 no dhcpcd leak:** after any bridge cycle, `grep -c '^denyinterfaces .*br0' /etc/dhcpcd.conf` → `0` once back in ap/clean (and never >1 while bridged).
- ☐ **#5 ip_forward reset:** after intercept → ap/clean, `cat /proc/sys/net/ipv4/ip_forward` → `0`.
- ☐ **No stacked NM confs:** `ls /etc/NetworkManager/conf.d/99-*-unmanaged.conf` lists only the conf for the current mode (none in clean).

---

## 6. Recovery

- ☐ Lost access mid-switch: a reboot returns to whatever `pi-mode` last selected (`/etc/pi-mode/mode`).
- ☐ Force a known-good baseline from the console: `sudo pi-mode ap` (or `sudo pi-mode clean` for stock networking).
- ☐ Last resort: `cat /etc/pi-mode/mode`, set it with `echo ap | sudo tee /etc/pi-mode/mode`, reboot.
