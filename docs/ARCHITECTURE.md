# Architecture

## Components

| Path | Role |
|---|---|
| `/etc/wa-call/wa-call.sh` | Engine: `apply`, `down`, `stop`, `status [--json]`, `update-list`, `check-miss`, `daemon` |
| `/etc/wa-call/meta-ipv4.default` | Bundled Meta (AS32934) prefix list, used until the first successful download |
| `/etc/wa-call/meta-ipv4.txt` | Downloaded prefix list (RIPEstat), refreshed every `refresh_days` |
| `/etc/wa-call/fw-include.sh` | fw3 include: runs `apply` after every firewall start/reload |
| `/etc/config/wa_call` | UCI configuration |
| `/etc/init.d/wa-call` | procd service: runs `apply` and supervises the monitor daemon; reloads on UCI change |
| `/etc/hotplug.d/iface/99-wa-call` | Runs `apply` on `ifup`/`ifdown`/`ifupdate` of the VPN interface |
| `/lib/upgrade/keep.d/wa-call` | Preserves all files across sysupgrade |
| `/www/luci-static/resources/view/wa-call.js` | LuCI view |
| `/usr/share/luci/menu.d/luci-app-wa-call.json` | LuCI menu entry (Services) |
| `/usr/share/rpcd/acl.d/luci-app-wa-call.json` | rpcd ACL: the page may only run `status --json`, `apply`, `update-list`, and read/write the miss log |
| `/tmp/wa-call/` | Runtime: lock file, miss log |

## Netfilter and routing

All objects are private to this package:

| Object | Name / value |
|---|---|
| ipset | `wa_meta` (`hash:net`) |
| fwmark bit | `0x01000000` (mask `0x01000000`) |
| routing table | `2001` |
| ip rule priority | `5200` |
| chains | mangle `WA_CALL`, filter `WA_CALL_FWD`, nat `WA_CALL_NAT` |

### Rules (catch-all off)
```
mangle PREROUTING  -i <lan_if> -j WA_CALL            (one per lan_if, inserted first)
  WA_CALL:
    CONNMARK --restore-mark  mask 0x01000000         # keep the decision for the whole flow
    mark 0x01000000/0x01000000        -> RETURN
    ! -p udp                          -> RETURN
    -p udp ! --dport <port>           -> RETURN
    -d 10/8, 172.16/12, 192.168/16, 100.64/10, 127/8 -> RETURN
    -m set --match-set wa_meta dst --ctstate NEW -> MARK 0x01000000
    mark 0x01000000 -> CONNMARK --save-mark

filter FORWARD     -j WA_CALL_FWD                    (inserted first)
  WA_CALL_FWD: -i <lan_if> -o <vpn_if> -m mark 0x01000000 -> ACCEPT

nat POSTROUTING    -j WA_CALL_NAT                    (inserted first)
  WA_CALL_NAT: -o <vpn_if> -m mark 0x01000000 -> MASQUERADE

ip rule  5200: fwmark 0x01000000/0x01000000 lookup 2001
table 2001:     default dev <vpn_if>
```
With `catch_all=1`, the `-m set` match is omitted, so every public destination on the port is marked.

### Why these values
- **Mark bit `0x01000000`** avoids the bits GL.iNet firmware already uses:
  `0xf0` (DPI QoS), `0xf00` (DPI allow), `0xf000` (GL VPN policy), `0xff0000` (kmwan / Tailscale), `0xf00000` (DPI block).
- **Priority 5200** runs before GL's VPN policy rules (6000) and its kill-switch blackholes (9910/9920), and after the local/main exceptions (0-50).
- **Table 2001 has no blackhole.** If the VPN device disappears, the kernel removes the route, the lookup fails,
  and routing falls through to `main`, so it **fails open**. The hotplug hook then removes the rules and deletes the marked conntrack entries
  so calls reconnect via WAN.
- **Own MASQUERADE and FORWARD accept**, so it works even when the firewall has no zone forwarding from LAN to the VPN.

## Lifecycle

```
boot ─► init.d start ─► apply ─┬─ enabled && vpn up ─► rules_up
                               └─ otherwise          ─► rules_down
VPN ifup/ifdown ─► hotplug ─► apply
firewall reload ─► fw3 include ─► apply        (idempotent; logs only on state change)
UCI change (LuCI Save & Apply) ─► procd reload trigger ─► start ─► apply + daemon instance update
daemon (every 60 s) ─► check-miss ; hourly: update-list if list older than refresh_days
```

- `rules_up` is idempotent: it rebuilds chains in place and doesn't flush marked flows, so an active call survives a re-apply.
- On activation it deletes *unmarked* UDP/`port` conntrack entries, so a call stuck on WAN reconnects through the VPN immediately.
- All mutating commands take `flock /tmp/wa-call/lock`.

## Prefix list
- Source: `https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS32934`
- Parsed with `jsonfilter`. IPv6 is filtered out.
- **Sanity check:** a download with fewer than 20 prefixes is rejected and the current list is kept.
- Loaded atomically with `ipset swap`.

## Missed-relay detector
Every 60 s while active, the detector looks for conntrack entries that are:
- UDP to `port`, **unmarked** (went via WAN), `[UNREPLIED]`
- from a LAN device that **currently has a marked call flow** (a call is in progress)
- not from a source port in `miss_ignore_sport` (default Tailscale `41641`)

Matches are logged to `/tmp/wa-call/misses.log` and syslog. Repeated entries mean WhatsApp is using a relay outside
the Meta list: enable catch-all mode, or report it in an issue.

## Why not DPI
The first design used GL.iNet's DPI (Netify agent + flow-actions plugin) to learn WhatsApp destinations. It was dropped because:
1. The DPI verdict arrives after the first packets are already routed and NATed to WAN, and an established NATed flow can't be moved to another interface.
   It would need a "learn, reject, reconnect" loop.
2. The investigation showed call media is **always** UDP 3478 to Meta, which a static rule matches from the first packet.
3. It has fewer moving parts and no dependency on the DPI license or feature toggles.

## Limitations
- iptables/ipset only (fw3). fw4/nftables is not supported yet.
- IPv4 only.
- Assumes the VPN interface is a point-to-point device (`default dev <vpn_if>`), as with WireGuard and OpenVPN tun.
