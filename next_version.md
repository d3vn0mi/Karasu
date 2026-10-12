okay lets try to rethink the problem a bit, 
i have a server with 1 ethernet port connected to a router via cable. I cannot change the IP of server. 
I want to place the rasberry in between, and for it to work as a bridge between the two, as a transparent proxy (squid proxy). 
Then i want to use the AP to serve the files normally. For the server it shouldnt make any difference, but when accessing a specific URL lke http://karasu.local the server would be allowed to, otherwise its business as usual for the server. 
Ofc the Rasberry must replicate the MAC of the server for the other end so that the monitoring solution that watches the MAC of the server doesnt notice any difference

This is a real pivot — you're turning Yatagarasu from an access point into a **transparent bridging implant** (silentbridge / "bump-in-the-wire"), with the AP + updrop demoted to the out-of-band management and loot plane. Let me lay out the clean architecture and the parts that bite, then pin the few decisions that change the build.

**Reframe:** the wired path becomes an L2 bridge the server sees straight through; the Wi-Fi AP + updrop become out-of-band (management + file drop over `wlan0`, never the wire). Assuming this is your own kit on an authorized engagement, here's the clean build.

### Hard blocker first — you need two wired NICs
A transparent bridge joins two Ethernet segments; the Pi has one port.

| Pi | 2nd NIC | Reality |
|---|---|---|
| Pi 4 / 5 | USB3 GbE dongle → `eth1` | only sane option; ~0.9 Gbps real |
| Pi 3 / Zero 2 | USB2 only | caps ~300 Mbps — a GbE link through it is detectable (throughput drop) |
| CM4 + carrier | 2× native | cleanest, lowest latency/jitter |

```
Router ─[eth1]─┐
               ├─ br0  (no IP · promisc · STP off)   transparent L2, forwards server frames untouched
Server ─[eth0]─┘
        wlan0 = Yatagarasu AP + updrop   ← management + loot, OUT OF BAND
```

### 1 · Transparent bridge (server sees no difference)
`br0` enslaving `eth0`+`eth1`, **no IP on the wire**, both NICs promiscuous, `bridge stp off`, plus an **ebtables BPDU drop** so you don't trip BPDU-guard. Because a bridge forwards the server's own frames unchanged, the server's MAC **and IP appear on the router side naturally** — the monitor sees exactly what it saw before. That's the whole trick; you're not spoofing the server's MAC for its own traffic, the bridge just carries it.

### 2 · MAC cloning — the leak is Pi-originated traffic, not the server's
The server's frames are fine. The danger is anything the **Pi** emits on the wire (Squid fetching upstream, DNS, NTP, apt, your SSH). Two rules: clone the server's MAC onto `eth1`/`br0`, and keep the Pi **silent on the wire** — all management rides `wlan0`, with an nftables backstop dropping Pi-originated egress on `eth1`. Never let Pi + server use the same MAC+IP *simultaneously* (CAM flap / ARP conflict) — silent-on-the-wire avoids it.

### 3 · The `karasu.local` + Squid part — this is the fork
- **(A) Just serve `karasu.local`, pass everything else** → you don't need Squid at all. Give `br0` a *hidden* IP, dnsmasq/Avahi answers `karasu.local → that IP`, updrop serves on it; the server's other traffic L2-forwards untouched. Simplest, stealthiest.
- **(B) Transparently inspect / filter / log the server's web** → that's what Squid is for: `br_netfilter` + `REDIRECT` TCP 80 into Squid (intercept mode), ACLs on the `Host:` header (serve `karasu.local` locally, `allow` the rest). **Must be fail-open** — if Squid dies, a fallback restores direct forwarding or the server loses its uplink and "no difference" breaks.

### Where I'd push back
| Issue | Reality |
|---|---|
| **HTTPS** | Transparent Squid only does HTTP (80) cleanly. Intercepting 443 = SSL-bump = a CA the server must trust → install + detection + pinning breaks. "Transparent proxy" realistically = HTTP unless you truly want MITM. |
| **Single point of failure** | Software bridge → a Pi crash/reboot drops the server's uplink. If uptime is watched, add a hardware fail-through relay or accept the window. |
| **802.1X / NAC** | If the port authenticates, a naive bridge breaks the server's auth or gets the port killed. You'd need EAPOL transparent forwarding (ride the server's session — the silentbridge move). Big change to the build. |
| **Latency** | A USB-NIC bridge adds jitter; if the monitor baselines latency, a bump-in-the-wire is detectable. |
| **`.local` needs an IP** | For the server to resolve `karasu.local`, the Pi must hold a hidden bridge IP to answer mDNS — slight tension with "zero wired footprint." A non-`.local` trigger can be cleaner. |

### Fit with the repo
New **bridge mode**, separate from AP mode — I'd write `pi_bridge_setup.sh` (reusing updrop + AP as the mgmt/loot plane), phased: (1) pure transparent bridge + MAC clone → verify the monitor is happy; (2) add local `karasu.local` serve; (3) add Squid only if you need (B).

**Confirming my read of "accessing karasu.local the server would be allowed to, otherwise business as usual":** I'm taking it as *the Pi answers `karasu.local` locally (file drop) and everything else the server does passes straight through untouched* — not that you want to gate/restrict the server's normal access. Correct me if you meant Squid should actually restrict it.

Locked on approach A. Before I write anything, here's your constraint translated into the exact mechanism, because it drives every line — and the good news is a true L2 bridge gives you most of it *for free*:

**Your constraint → how it's guaranteed**

| Your requirement | Why it holds |
|---|---|
| Server **IP** unchanged (router's view) | Pure L2 bridge — the Pi never NATs or re-IPs. The server keeps its own DHCP/static address; its packets are forwarded verbatim. |
| Server **MAC** unchanged (router's view) | **Bridges don't rewrite source MAC.** The server's frames egress toward the router carrying the server's own MAC — nothing to spoof. |
| No *second* identity appears | The Pi is made **mute on the router-facing port**: one `ebtables OUTPUT -o <router-NIC> DROP` rule means the Pi can't emit a single frame that way — no ARP, no IPv6, no mDNS, no BPDU, no USB-NIC MAC. IPv6 is disabled on the bridge, STP is off. |
| "Like unplug / replug" | Correct — inserting the Pi is one link blip, then the same MAC+IP reappears to the router. The only honest caveat: a software bridge means **a Pi crash = the server's link drops** (no hardware fail-through). Bench-test before you put it inline. |

So MAC "replication" turns out to be the wrong framing for your own traffic — the bridge already preserves it; the work is *silencing the Pi*, which I do hard. (Optional MAC-clone of the router-facing NIC is in there as belt-and-suspenders, default off.)

Two assumptions I'm running with since you didn't pin them: **NIC = USB3 GbE on a Pi 4/5** (`eth0`=server, `eth1`=router), and **passive MAC monitoring, not 802.1X** — if that port actually does 802.1X, this naive bridge gets killed and we'd need EAPOL pass-through (flag it and I'll extend). Let me build it.

Syntax check and a look at the stealth core:

Syntax clean, all modes wired, the router-port fence is in. Syncing to the repo:

`pi_bridge_setup.sh` (v0.1) is in the chat and committed to the repo (untracked until you `git add`).

**One honest limitation:** I can't runtime-test a two-NIC bridge in this cloud sandbox — no second NIC, no real switch. So it's syntax-clean and the L2/ebtables logic is carefully reasoned, but it is **unvalidated on hardware**. Bench it before it goes anywhere real.

**Modes:** `up` · `down` · `status` · `detect`. Set `SRV_IFACE`/`RTR_IFACE` and a `KARASU_IP` (a free address in the server's subnet) in the CONFIG block — `sudo bash pi_bridge_setup.sh detect` sniffs the server side and suggests the subnet. Run everything over Wi-Fi/console, never over the bridged wire.

**How the constraint is enforced, in one line of ebtables:** `OUTPUT -o eth1 DROP` — the Pi is physically incapable of emitting a frame toward the router. Combined with IPv6 off + STP off, the router sees only the server's own forwarded frames (its real MAC + IP), and the `karasu` service IP is fenced to the server side.

## Bench test plan — do this first

Rig: a laptop acting as "server" → Pi → your switch/router.

1. **Baseline (Pi not inline):** on the router/switch, record what it sees — `show mac address-table` for the port, and the `IP→MAC` in its ARP table.
2. **Insert the Pi**, `sudo bash pi_bridge_setup.sh up`.
3. **The money check — from the Pi**, watch the router-facing NIC:
   ```bash
   tcpdump -i eth1 -e -nn        # every egress frame's src MAC must be the SERVER's — never the Pi/USB MAC, no IPv6, no mDNS from the Pi
   ```
4. **From the router/switch:** same server MAC on the port, same `IP→MAC` as step 1, **nothing new**. That's your "unplug/replug" proof.
5. **From the server:** normal traffic still works (ping gateway, browse) = business as usual; and `http://karasu.local/` + `http://<KARASU_IP>/` hit the drop.
6. `sudo bash pi_bridge_setup.sh status` summarizes all of the above and reminds you what to confirm router-side.

## Before you trust it inline

- **Bench only, first.** A Pi crash/reboot = the server's link drops (software bridge, no hardware fail-through). For anything that matters, add a fail-through relay or keep the window short.
- **802.1X:** if that switch port authenticates, this bridge gets killed — you'll see the port err-disable or the server lose auth. That's the signal you need EAPOL pass-through, which this version doesn't do yet.
- **`.local` fidelity:** the server resolving `karasu.local` is a new multicast from the *server's* own MAC; it looks like normal mDNS but it is new behaviour. For zero trace, put a static hosts entry on the server (`<KARASU_IP> karasu`) instead of relying on mDNS.

Once you've validated it on the bench, I'll fold a "Bridge mode" section into the README + HANDOVER and, if that port turns out to be 802.1X, extend the script with EAPOL transparent forwarding. Want me to queue the 802.1X pass-through design now, or wait for your bench results?