#!/bin/sh
# SPDX-License-Identifier: MIT
# WhatsApp Calls via VPN - installer. Run on the router from the unpacked repo: sh install.sh
set -e
cd "$(dirname "$0")"

# Prerequisites
if [ -x /sbin/fw4 ] || [ -x /usr/sbin/fw4 ]; then
	echo "ERROR: fw4/nftables firewall detected - this version supports fw3/iptables only." >&2
	exit 1
fi
missing=""
for bin in iptables ipset conntrack curl jsonfilter flock logger; do
	command -v "$bin" >/dev/null 2>&1 || missing="$missing $bin"
done
if [ -n "$missing" ]; then
	echo "ERROR: missing required tools:$missing" >&2
	echo "Install them first, e.g.: opkg update && opkg install ipset kmod-ipt-ipset conntrack curl" >&2
	exit 1
fi
[ -f /etc/config/wa_call ] && KEEP_CFG=1 || KEEP_CFG=0
cp -a files/etc/wa-call /etc/
cp files/etc/init.d/wa-call /etc/init.d/wa-call
cp files/etc/hotplug.d/iface/99-wa-call /etc/hotplug.d/iface/99-wa-call
cp files/lib/upgrade/keep.d/wa-call /lib/upgrade/keep.d/wa-call
# LuCI app
mkdir -p /www/luci-static/resources/view /usr/share/luci/menu.d /usr/share/rpcd/acl.d
cp files/www/luci-static/resources/view/wa-call.js /www/luci-static/resources/view/wa-call.js
cp files/usr/share/luci/menu.d/luci-app-wa-call.json /usr/share/luci/menu.d/
cp files/usr/share/rpcd/acl.d/luci-app-wa-call.json /usr/share/rpcd/acl.d/
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
/etc/init.d/rpcd reload
[ "$KEEP_CFG" = 1 ] || cp files/etc/config/wa_call /etc/config/wa_call
# add options introduced in newer versions without touching existing values
if [ "$KEEP_CFG" = 1 ]; then
	for kv in selftest_interval=30 selftest_control=stun.cloudflare.com:3478 history=1 history_max=200 \
		watchdog=1 watchdog_handshake=180 watchdog_failures=2 watchdog_max_per_hour=3; do
		uci -q get "wa_call.main.${kv%%=*}" >/dev/null || uci set "wa_call.main.${kv%%=*}=${kv#*=}"
	done
	uci commit wa_call
fi
chmod +x /etc/wa-call/wa-call.sh /etc/wa-call/fw-include.sh /etc/init.d/wa-call
if ! uci -q get firewall.wa_call >/dev/null; then
	uci set firewall.wa_call=include
	uci set firewall.wa_call.type='script'
	uci set firewall.wa_call.path='/etc/wa-call/fw-include.sh'
	uci set firewall.wa_call.reload='1'
	uci commit firewall
fi
/etc/init.d/wa-call enable
/etc/init.d/wa-call restart
echo "installed"; /etc/wa-call/wa-call.sh status
