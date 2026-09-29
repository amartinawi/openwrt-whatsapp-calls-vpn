#!/bin/sh
# SPDX-License-Identifier: MIT
# Remove everything installed by install.sh
/etc/init.d/wa-call stop 2>/dev/null
/etc/init.d/wa-call disable 2>/dev/null
uci -q delete firewall.wa_call && uci commit firewall
rm -rf /etc/wa-call /tmp/wa-call
rm -f /etc/init.d/wa-call /etc/hotplug.d/iface/99-wa-call /lib/upgrade/keep.d/wa-call /etc/config/wa_call
rm -f /www/luci-static/resources/view/wa-call.js /usr/share/luci/menu.d/luci-app-wa-call.json /usr/share/rpcd/acl.d/luci-app-wa-call.json
rm -f /tmp/luci-indexcache* 2>/dev/null; /etc/init.d/rpcd reload
echo "uninstalled"
