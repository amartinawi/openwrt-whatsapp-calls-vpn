# Changelog

## 1.1.0 (2026-09-30)
- **Call-path self-test** (`selftest.lua`): STUN probes to WhatsApp relays via WAN and via VPN plus a non-Meta WAN control
  probe, with a verdict (ISP blocking / VPN path working / VPN server failing / WAN down). Runs on demand (LuCI button,
  `wa-call.sh selftest`) and every `selftest_interval` minutes.
- **Call history and active calls** (`calltrack.lua`, procd instance `wa-call-tracker`): per-device call sessions from
  conntrack counters: start, duration, route (VPN/WAN), status (connected / setup only / no reply), data, relays.
  History is kept in `/etc/wa-call/history.jsonl` (`history`, `history_max`).
- LuCI: new Self-test, Active calls and Call history sections. Status shows the active-call count.
- New ip rule 5201 (`oif <vpn_if> lookup 2001`) so router-local probes bound to the VPN device are routed.
- Installer adds new options to an existing config without changing current values.

## 1.0.0 (2026-09-29)
First public release.

- Route WhatsApp call media (UDP 3478 to Meta AS32934) through a chosen VPN interface. Everything else stays on WAN.
- Private ipset, fwmark bit, routing table, and chains. No changes to existing firewall, VPN, or DPI config (besides one fw3 include).
- Fails open: rules follow the VPN interface up/down via hotplug.
- Re-applied automatically after firewall reloads (fw3 include).
- Weekly Meta prefix refresh from RIPEstat, with sanity check and atomic `ipset swap`.
- Missed-relay detector (only flags devices that are in a call, ignores Tailscale).
- Catch-all mode.
- LuCI page (Services → WhatsApp Calls via VPN) with live status, actions, and settings. rpcd ACL restricted to the page's own commands.
- sysupgrade keep list.
- Tested on GL.iNet GL-BE14000, firmware 4.9.2 (OpenWrt 21.02, fw3).
