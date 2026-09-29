# Troubleshooting

Start with:
```sh
/etc/wa-call/wa-call.sh status
logread -e wa-call | tail -20
```

## State shows "idle - calls via WAN"
- **VPN is down.** Check `ip -br link show <vpn_if>`. The feature only activates while the device exists and is UP.
- **Wrong device name.** `uci get wa_call.main.vpn_if` must match `ip -br link` (GL.iNet: `wgclient1`, `ovpnclient1`).
- **Disabled.** Check `uci get wa_call.main.enabled`.

## Active, but calls still stuck on "Connecting…"
1. During a call, check that media is going through the VPN:
   ```sh
   tcpdump -ni <vpn_if> udp port 3478      # should show two-way traffic during a call
   conntrack -L -m 0x01000000/0x01000000    # marked call flows
   ```
2. If nothing is marked, check the **LAN bridge**: `uci get wa_call.main.lan_if` must include the bridge the phone is on (e.g. `br-guest`).
3. Look at **missed relays** (LuCI or `cat /tmp/wa-call/misses.log`). IPs listed there are relays outside the Meta list. Enable **catch-all mode**.
4. Check that the VPN itself passes UDP: some VPN servers or protocols block or throttle STUN. Try another server.
5. Check that the phone isn't using its own VPN or Private Relay, which bypasses the router's routing.

## "Possible missed relays" lists non-Meta IPs, but calls work
The detector flags any UDP/3478 flow without a reply from a device that is in a call at that moment.
PCs often run other apps that probe public STUN servers on port 3478 (softphones, games, P2P clients, Tailscale), and these
can coincide with a call. Check the owner of a flagged IP:
```sh
curl -s "https://stat.ripe.net/data/prefix-overview/data.json?resource=IP" | jsonfilter -e '@.data.asns[*].holder'
```
If it isn't Meta/Facebook and calls work, it's harmless. Add the app's source port to `miss_ignore_sport`, or ignore it.
Only enable catch-all mode if calls actually fail.

## Everything goes through the VPN, not only calls
That's the VPN's own configuration, not this package. On GL.iNet, **global mode** routes all traffic through the VPN.
Switch to policy mode with a source that has no devices (see the README, Installation step 1).
Check with `ip route get 8.8.8.8 from <lan-ip> iif br-lan`: it should show your WAN device.

## Rules disappear after changing firewall settings
The fw3 include should restore them. Check that it's there:
```sh
uci show firewall.wa_call     # type=script, path=/etc/wa-call/fw-include.sh, reload=1
```
If it's missing, re-run `install.sh`.

## Meta list doesn't update
```sh
/etc/wa-call/wa-call.sh update-list; logread -e wa-call | tail -3
curl -fsS 'https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS32934' | head -c 200
```
If the download fails, the current list (or the bundled default) stays in use.

## LuCI page missing or "Access denied"
```sh
ls /usr/share/luci/menu.d/luci-app-wa-call.json /usr/share/rpcd/acl.d/luci-app-wa-call.json
rm -f /tmp/luci-indexcache*; /etc/init.d/rpcd reload
```
Then log out of LuCI and back in, and hard-refresh the browser (the view JS is cached by LuCI version).

## Full reset
```sh
sh uninstall.sh && sh install.sh
```
