# Changelog

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
