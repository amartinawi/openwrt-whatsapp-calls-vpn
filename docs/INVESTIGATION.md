# Investigation: why WhatsApp calls fail and what exactly to route

This is a summary of the packet-capture investigation behind the design. It was done on a GL.iNet GL-BE14000
(OpenWrt 21.02, fw3) where WhatsApp calls failed on the ISP connection but worked over a VPN.

## Symptom
- Outgoing and incoming calls **ring** normally.
- After answering, the call stays on **"Connecting…"** and never establishes.
- With the whole router behind a VPN, calls work.

## Method
For each test, the router captured:
- `tcpdump` on the LAN bridge (`br-lan`): what the clients send
- `tcpdump` on the WAN device (UDP only): what leaves the router and whether anything comes back
- `tcpdump` on the VPN device (when up)
- `conntrack -L -p udp` snapshots every 2 s

Test devices: an Android phone and a Windows PC with WhatsApp Desktop, both on the LAN.

| Test | Setup | Result |
|---|---|---|
| A | Phone → PC voice call, **VPN off** | ❌ rings, stuck on "Connecting…" |
| C | Phone → PC voice call, **VPN on (global)** | ✅ audio |
| E | PC → phone on **mobile data**, VPN on | ✅ audio |
| P1 | Phone → PC, **only UDP 3478 → Meta routed via VPN** (this project) | ✅ audio |

## Findings

### Test A: VPN off (call fails)
- **Signalling works:** the phone keeps a TCP connection to `57.144.x.33:5222` / `:443` (WhatsApp chat servers) with normal two-way traffic. That's why it rings.
- **Media setup fails:** both devices send STUN/TURN allocate requests (352-byte UDP, magic cookie `0x2112A442`)
  to relays such as `57.144.{43,149,213}.54:3478` and `.57:3478`.
  - About 185 packets left the WAN interface over ~30 s.
  - **0 replies** came back. conntrack showed every flow as `[UNREPLIED]` with `mark=0` (the router didn't drop anything).
- **Control:** Tailscale on the PC sent STUN to *non-Meta* servers on the **same UDP port 3478** and got replies.
  → Port 3478 is not blocked in general. The ISP targets WhatsApp's relays, by IP range or by recognising the traffic.

### Test C: VPN on, same call (works)
All media was **UDP 3478 to Meta relays**:

| Flow | Packets (out/in) |
|---|---|
| PC ↔ `157.240.227.133:3478` | 574 / 600 |
| Phone ↔ `157.240.227.62:3478` | 439 / 200 |
| PC ↔ `57.144.55.57:3478`, Phone ↔ `57.144.55.54:3478` | 97 / 96, 80 / 11 |
| Both ↔ `157.240.13.x:3478` (candidates) | replies received |

- No direct phone↔PC traffic, even though both were on the same LAN. WhatsApp relays the call.
- No Meta UDP on any port other than 3478 (and 443 for QUIC chat).
- **Relays change with location:** without the VPN WhatsApp picked `57.144.x`; via the VPN exit it picked `157.240.x` and `57.144.x`.

### Test E: call to a phone on mobile data (works via VPN)
- Media: `57.144.149.57:3478` (~1,200 packets), plus `57.144.69.57`, `57.144.187.57`.
- **No peer-to-peer** traffic to the mobile phone's carrier IP. Calls to external peers are relayed too.

### Test P1: selective routing (this project)
- VPN carried: UDP 3478 ↔ `157.240.227.x`, `57.144.55.x`, `57.144.125.57` (a relay not seen before, matched by prefix). About 1,000 packets.
- WAN carried: **0** UDP-3478 packets to Meta.
- Signalling (TCP 5222/443) stayed on WAN. **Split path works**: the relays don't require signalling and media to share a public IP.

## Conclusions
1. The ISP blocks WhatsApp **call relays** (UDP 3478 to Meta). Signalling and chat are not affected.
2. Call media always goes through **Meta relays on UDP 3478**. No P2P was observed, including LAN↔LAN and LAN↔mobile.
3. Relay IPs vary by location, so matching **all of Meta's announced IPv4 space (AS32934)** is required, not individual IPs.
   All relays observed were in `57.144.0.0/14`, `157.240.0.0/17`, `157.240.192.0/18`.
4. A static rule matches the **first packet**, so no DPI is needed and there is no learning delay.
5. Large UDP packets are IP-fragmented. Conntrack defragments before the mangle table, so the port match still works.

## Reproducing on your network
```sh
# on the router, replace PHONE_IP and WAN_DEV
tcpdump -ni br-lan  -w /tmp/lan.pcap host PHONE_IP and not port 53 &
tcpdump -ni WAN_DEV -w /tmp/wan.pcap udp port 3478 &
# make a WhatsApp call, then stop tcpdump
tcpdump -nr /tmp/wan.pcap -q | awk '{print $3,$5}' | sort | uniq -c
```
Outgoing packets to `*.3478` with no reverse lines means the same block described above.
