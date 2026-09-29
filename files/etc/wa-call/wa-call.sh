#!/bin/sh
# SPDX-License-Identifier: MIT
# https://github.com/amartinawi/openwrt-whatsapp-calls-vpn
# wa-call.sh - route WhatsApp call media (UDP 3478 to Meta relays) via a VPN interface.
# Additive only: own ipset, own iptables chains, own fwmark bit, own routing table.
# Commands: apply | down | stop | status [--json] | update-list | check-miss | daemon

. /lib/functions.sh

MARK=0x01000000
TABLE=2001
PRIO=5200
SET=wa_meta
CH_MANGLE=WA_CALL
CH_FWD=WA_CALL_FWD
CH_NAT=WA_CALL_NAT
DIR=/etc/wa-call
RUN=/tmp/wa-call
LIST="$DIR/meta-ipv4.txt"
LIST_DEFAULT="$DIR/meta-ipv4.default"
MISS_LOG="$RUN/misses.log"
LOCK="$RUN/lock"
PRIVATE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 127.0.0.0/8"

log() { logger -t wa-call "$*"; }
ipt() { iptables -w "$@"; }

load_config() {
	config_load wa_call
	config_get_bool ENABLED main enabled 0
	config_get VPN_IF main vpn_if wgclient1
	config_get LAN_IFS main lan_if br-lan
	config_get PORT main port 3478
	config_get_bool CATCH_ALL main catch_all 0
	config_get REFRESH_DAYS main refresh_days 7
	config_get PREFIX_URL main prefix_url ''
	config_get_bool MISS_CHECK main miss_check 1
	config_get MISS_IGNORE_SPORT main miss_ignore_sport '41641'
}

vpn_is_up() { ip link show "$VPN_IF" 2>/dev/null | grep -q ',UP'; }
rules_active() { ip rule | grep -q "^$PRIO:"; }
active_list() { [ -s "$LIST" ] && echo "$LIST" || echo "$LIST_DEFAULT"; }

load_set() {
	local file="$(active_list)" net
	ipset create "$SET" hash:net -exist
	ipset create "${SET}_new" hash:net -exist
	ipset flush "${SET}_new"
	grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$file" | while read -r net _; do
		ipset add "${SET}_new" "$net" -exist
	done
	ipset swap "${SET}_new" "$SET"
	ipset destroy "${SET}_new"
}

ensure_chain() { ipt -t "$1" -N "$2" 2>/dev/null; ipt -t "$1" -F "$2"; }

hook() {
	local t="$1" p="$2" c="$3"; shift 3
	ipt -t "$t" -C "$p" "$@" -j "$c" 2>/dev/null || ipt -t "$t" -I "$p" 1 "$@" -j "$c"
}

unhook() {
	local t="$1" p="$2" c="$3"; shift 3
	while ipt -t "$t" -D "$p" "$@" -j "$c" 2>/dev/null; do :; done
}

# Remove every PREROUTING hook regardless of the current lan_if config
unhook_mangle_all() {
	local lan
	while ipt -t mangle -S PREROUTING 2>/dev/null | grep -q -- "-j $CH_MANGLE"; do
		lan="$(ipt -t mangle -S PREROUTING | grep -- "-j $CH_MANGLE" | head -n1 | sed -n 's/.*-i \([^ ]*\).*/\1/p')"
		if [ -n "$lan" ]; then
			unhook mangle PREROUTING "$CH_MANGLE" -i "$lan"
		else
			unhook mangle PREROUTING "$CH_MANGLE"
		fi
	done
}

rules_up() {
	local lan net was_active=0
	rules_active && was_active=1
	load_set
	unhook_mangle_all

	ensure_chain mangle "$CH_MANGLE"
	ipt -t mangle -A "$CH_MANGLE" -j CONNMARK --restore-mark --nfmask "$MARK" --ctmask "$MARK"
	ipt -t mangle -A "$CH_MANGLE" -m mark --mark "$MARK/$MARK" -j RETURN
	ipt -t mangle -A "$CH_MANGLE" ! -p udp -j RETURN
	ipt -t mangle -A "$CH_MANGLE" -p udp ! --dport "$PORT" -j RETURN
	for net in $PRIVATE_NETS; do
		ipt -t mangle -A "$CH_MANGLE" -d "$net" -j RETURN
	done
	if [ "$CATCH_ALL" = 1 ]; then
		ipt -t mangle -A "$CH_MANGLE" -m conntrack --ctstate NEW -j MARK --set-xmark "$MARK/$MARK"
	else
		ipt -t mangle -A "$CH_MANGLE" -m set --match-set "$SET" dst \
			-m conntrack --ctstate NEW -j MARK --set-xmark "$MARK/$MARK"
	fi
	ipt -t mangle -A "$CH_MANGLE" -m mark --mark "$MARK/$MARK" \
		-j CONNMARK --save-mark --nfmask "$MARK" --ctmask "$MARK"

	ensure_chain filter "$CH_FWD"
	ensure_chain nat "$CH_NAT"
	ipt -t nat -A "$CH_NAT" -o "$VPN_IF" -m mark --mark "$MARK/$MARK" -j MASQUERADE

	for lan in $LAN_IFS; do
		hook mangle PREROUTING "$CH_MANGLE" -i "$lan"
		ipt -A "$CH_FWD" -i "$lan" -o "$VPN_IF" -m mark --mark "$MARK/$MARK" -j ACCEPT
	done
	hook filter FORWARD "$CH_FWD"
	hook nat POSTROUTING "$CH_NAT"

	ip route replace default dev "$VPN_IF" table "$TABLE"
	rules_active || ip rule add pref "$PRIO" fwmark "$MARK/$MARK" lookup "$TABLE"

	# Push call flows that are stuck on WAN to reconnect through the VPN
	conntrack -D -p udp --dport "$PORT" -m 0x0/"$MARK" >/dev/null 2>&1
	[ "$was_active" = 1 ] || log "active: UDP $PORT $( [ "$CATCH_ALL" = 1 ] && echo 'to any public IP' || echo "to Meta ($(ipset list $SET | grep -cE '^[0-9]') prefixes)") via $VPN_IF"
}

rules_down() {
	local was_active=0
	rules_active && was_active=1
	ip rule del pref "$PRIO" 2>/dev/null
	ip route flush table "$TABLE" 2>/dev/null
	unhook_mangle_all
	unhook filter FORWARD "$CH_FWD"
	unhook nat POSTROUTING "$CH_NAT"
	ipt -t mangle -F "$CH_MANGLE" 2>/dev/null; ipt -t mangle -X "$CH_MANGLE" 2>/dev/null
	ipt -F "$CH_FWD" 2>/dev/null; ipt -X "$CH_FWD" 2>/dev/null
	ipt -t nat -F "$CH_NAT" 2>/dev/null; ipt -t nat -X "$CH_NAT" 2>/dev/null
	# Flows NATed to the VPN address are dead once the VPN is gone; let them reconnect via WAN
	conntrack -D -m "$MARK/$MARK" >/dev/null 2>&1
	[ "$was_active" = 1 ] && log "idle: calls use WAN"
	return 0
}

# Decide from current state: enabled + VPN up => rules up, otherwise down
apply() {
	if [ "$ENABLED" = 1 ] && vpn_is_up; then
		rules_up
	else
		rules_down
	fi
}

update_list() {
	local tmp="$RUN/list.new" json="$RUN/ripe.json" count
	[ -n "$PREFIX_URL" ] || { log "update-list: no prefix_url"; return 1; }
	curl -fsS -m 30 -o "$json" "$PREFIX_URL" || { log "update-list: download failed, keeping current list"; return 1; }
	{
		echo "# Meta Platforms AS32934 IPv4 prefixes, fetched $(date -u +%Y-%m-%dT%H:%MZ)"
		jsonfilter -i "$json" -e '@.data.prefixes[*].prefix' | grep -vF ':' | sort -u
	} > "$tmp"
	rm -f "$json"
	count="$(grep -cE '^[0-9]' "$tmp")"
	if [ "${count:-0}" -lt 20 ]; then
		log "update-list: only ${count:-0} prefixes received, keeping current list"
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$LIST"
	log "update-list: $count prefixes"
	rules_active && load_set
	return 0
}

list_age_days() {
	local f="$(active_list)" now mtime
	[ "$f" = "$LIST" ] || { echo 9999; return; }
	now="$(date +%s)"; mtime="$(date -r "$f" +%s)"
	echo $(( (now - mtime) / 86400 ))
}

# Log LAN->WAN UDP flows to the call port that never got a reply, from devices that are
# in a WhatsApp call via VPN at that moment (=> WhatsApp tried a relay outside the Meta list)
check_miss() {
	[ "$MISS_CHECK" = 1 ] && rules_active || return 0
	# Devices with a call in progress right now (at least one call flow via VPN)
	local in_call
	in_call=" $(conntrack -L -m "$MARK/$MARK" 2>/dev/null | sed -n 's/^[^=]*src=\([0-9.]*\) .*/\1/p' | sort -u | tr '\n' ' ') "
	[ "$in_call" = "  " ] && return 0
	conntrack -L -p udp --dport "$PORT" -m 0x0/"$MARK" 2>/dev/null | grep 'UNREPLIED' | \
	while read -r line; do
		src="$(echo "$line" | sed -n 's/^[^=]*src=\([0-9.]*\) .*/\1/p')"
		dst="$(echo "$line" | sed -n 's/^[^=]*src=[0-9.]* dst=\([0-9.]*\).*/\1/p')"
		sport="$(echo "$line" | sed -n 's/^[^=]*src=[0-9.]* dst=[0-9.]* sport=\([0-9]*\) .*/\1/p')"
		case " $MISS_IGNORE_SPORT " in *" $sport "*) continue ;; esac
		case "$in_call" in *" $src "*) ;; *) continue ;; esac
		case "$src" in 192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;; *) continue ;; esac
		case "$dst" in 192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.*) continue ;; esac
		grep -q " $dst " "$MISS_LOG" 2>/dev/null && continue
		echo "$(date +%Y-%m-%dT%H:%M:%S) $dst from=$src" >> "$MISS_LOG"
		log "possible missed relay: $dst (from $src) went via WAN without reply"
	done
	[ -f "$MISS_LOG" ] && tail -n 100 "$MISS_LOG" > "$MISS_LOG.tmp" && mv "$MISS_LOG.tmp" "$MISS_LOG"
	return 0
}

daemon() {
	local n=0
	while true; do
		sleep 60
		load_config
		( flock -n 9 || exit 0; check_miss ) 9>"$LOCK"
		n=$((n + 1))
		# every hour: refresh the list if it is older than refresh_days
		if [ $((n % 60)) -eq 1 ] && [ "${REFRESH_DAYS:-0}" -gt 0 ] && \
		   [ "$(list_age_days)" -ge "$REFRESH_DAYS" ]; then
			( flock 9; update_list ) 9>"$LOCK"
		fi
	done
}

status() {
	local up=0 active=0 flows prefixes misses
	vpn_is_up && up=1
	rules_active && active=1
	flows="$(conntrack -L -m "$MARK/$MARK" 2>/dev/null | grep -c '^udp')"
	prefixes="$(ipset list $SET 2>/dev/null | grep -cE '^[0-9]')"
	misses="$(grep -c . "$MISS_LOG" 2>/dev/null)"
	if [ "$1" = "--json" ]; then
		printf '{"enabled":%s,"vpn_if":"%s","vpn_up":%s,"active":%s,"catch_all":%s,"prefixes":%s,"call_flows":%s,"list_age_days":%s,"misses":%s}\n' \
			"$ENABLED" "$VPN_IF" "$up" "$active" "$CATCH_ALL" "${prefixes:-0}" "${flows:-0}" "$(list_age_days)" "${misses:-0}"
		return
	fi
	echo "enabled:        $ENABLED"
	echo "vpn ($VPN_IF):  $([ $up = 1 ] && echo up || echo down)"
	echo "state:          $([ $active = 1 ] && echo 'ACTIVE - calls via VPN' || echo 'idle - calls via WAN')"
	echo "mode:           $([ "$CATCH_ALL" = 1 ] && echo "catch-all UDP $PORT" || echo "Meta prefixes, UDP $PORT")"
	echo "prefixes:       ${prefixes:-0} (list age $(list_age_days) days, $(active_list))"
	echo "call flows now: ${flows:-0}"
	echo "missed relays:  ${misses:-0} (see $MISS_LOG)"
	[ "$active" = 1 ] && { echo "--- counters"; ipt -t mangle -L "$CH_MANGLE" -v -n | sed -n '3,$p'; }
}

mkdir -p "$RUN"
load_config

case "$1" in
	apply)       ( flock 9; apply ) 9>"$LOCK" ;;
	down|stop)   ( flock 9; rules_down; [ "$1" = stop ] && ipset destroy "$SET" 2>/dev/null; true ) 9>"$LOCK" ;;
	status)      status "$2" ;;
	update-list) ( flock 9; update_list ) 9>"$LOCK" ;;
	check-miss)  ( flock 9; check_miss ) 9>"$LOCK" ;;
	daemon)      daemon ;;
	*) echo "usage: $0 apply|down|stop|status [--json]|update-list|check-miss|daemon"; exit 1 ;;
esac
