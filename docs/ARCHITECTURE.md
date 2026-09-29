# Architecture

## Components

| Path | Role |
|---|---|
| `/etc/wa-call/wa-call.sh` | Engine: `apply`, `down`, `stop`, `status [--json]`, `update-list`, `check-miss`, `daemon` |
| `/etc/wa-call/meta-ipv4.default` | Bundled Meta (AS32934) prefix list, used until the first successful download |
| `/etc/wa-call/meta-ipv4.txt` | Downloaded prefix list (RIPEstat), refreshed every `refresh_days` |
| `/etc/wa-call/selftest.lua` | Call-path self-test (STUN via WAN, via VPN, WAN control), writes `/tmp/wa-call/selftest.json` |
| `/etc/wa-call/calltrack.lua` | Call tracker (procd instance `wa-call-tracker`): active calls + history |
| `/etc/wa-call/history.jsonl` | Call history, one JSON object per finished call (kept across reboots/upgrades) |
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
| ip rule priority | `5200` (fwmark), `5201` (oif `<vpn_if>`, for router-local probes bound to the VPN device) |
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

## Call-path self-test
`selftest.lua` uses Lua `nixio` sockets to send RFC 5389 STUN Binding Requests (`0x0001`, magic cookie `0x2112A442`, random
transaction ID) and accepts only a Binding Success (`0x0101`) with a matching transaction ID.

| Probe | Socket | Target |
|---|---|---|
| WAN control | bound to the WAN device | `selftest_control` (default Cloudflare STUN, port 3478) |
| WAN relays | bound to the WAN device | up to 3 of `selftest_target` |
| VPN relays | bound to `vpn_if` (routed by rule 5201 → table 2001; added temporarily if the feature is idle) | up to 3 of `selftest_target` |

Only some WhatsApp relays answer plain Binding requests. In testing, the `57.144.x.57` relays answered and the `x.54` / `157.240.x`
relays did not (they answer only WhatsApp's own Allocate requests), so the defaults are `.57` relays.

| Verdict code | Meaning |
|---|---|
| `blocked_vpn_ok` | Relays unreachable via WAN, control OK, reachable via VPN: the expected state when this package is needed |
| `not_blocked` | Relays reachable via WAN: the ISP isn't blocking right now |
| `blocked_vpn_down` | Blocked on WAN and the VPN device is down |
| `blocked_vpn_fail` | Blocked on WAN and the VPN server can't reach relays: switch server |
| `wan_down` | Control and relays fail on WAN: an internet or UDP problem |

## Tunnel health watchdog
Runs in the monitor loop every 60 s while the feature is active and the tunnel has been up for at least 90 s.

| Check | Failure condition |
|---|---|
| WireGuard handshake | `wg show <vpn_if> latest-handshakes` older than `watchdog_handshake` (default 180 s). Only when persistent keepalive is set, since an idle tunnel without keepalive legitimately has old handshakes |
| Relay probe | `selftest.lua --vpn-probe`: STUN Binding to up to 3 relays through the VPN, no reply |

- A probe-only failure is **ignored while a call is connected via the VPN**, because the call proves the path works (guards against a stale relay list).
- After `watchdog_failures` consecutive failures it **switches server**:
  - GL.iNet (`vpn-failover-trigger.sh check <vpn_if>` succeeds): `ifdown <vpn_if>`. GL's hotplug starts `tunnel-switch.sh`, which waits
    8 s and moves to the next profile of the tunnel, skipping servers that don't connect. It keeps the same interface name when the
    interface isn't shared by other tunnel rules.
  - Otherwise: `ifdown` + `ifup` (reconnect).
- At most `watchdog_max_per_hour` switches per hour. Beyond that it logs *"switch limit reached"* and waits.
- State: `/tmp/wa-call/watchdog.json` (read by LuCI). Actions: `/tmp/wa-call/watchdog.log` and syslog (`wa-call: watchdog: …`).

States: `healthy`, `suspect` (failed, below threshold), `switching`, `limit`, `settling` (tunnel up < 90 s), `idle`, `disabled`.

## Call tracker
`calltrack.lua` polls `conntrack -L -p udp --orig-port-dst <port>` every 5 s (conntrack accounting, `nf_conntrack_acct=1`).
- Flows count if the source is a client inside a configured `lan_if` subnet (not the router itself) and the destination is Meta
  (Lua CIDR match against the active prefix list) or the flow carries the call mark.
- Per-flow packet/byte deltas are summed into a session per device. A session ends after 20 s without packets.
- Status: **connected** (≥ 50 reply packets and ≥ 5 s), **setup only** (some replies), **no reply** (no packets back, i.e. blocked).
- Route: **vpn** if any flow had the call mark, otherwise **wan**.
- Active sessions are written to `/tmp/wa-call/calls.json` every tick. Finished ones are appended to `history.jsonl` (trimmed
  to `history_max`) and logged to syslog (`call ended: …`).

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
- Call tracking sees only traffic that crosses the router. LAN↔LAN calls that switch to a direct local path show only the relay phase.
- Assumes the VPN interface is a point-to-point device (`default dev <vpn_if>`), as with WireGuard and OpenVPN tun.
