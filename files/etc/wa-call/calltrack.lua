#!/usr/bin/lua
-- SPDX-License-Identifier: MIT
-- https://github.com/amartinawi/openwrt-whatsapp-calls-vpn
--
-- Call tracker: polls conntrack for UDP call-port flows from LAN devices to Meta,
-- groups them into per-device call sessions and writes:
--   /tmp/wa-call/calls.json        active calls (rewritten every tick)
--   /etc/wa-call/history.jsonl     finished calls, one JSON object per line
-- Runs as a procd instance: lua calltrack.lua

local nixio = require "nixio"
local fs = require "nixio.fs"
local uci = require("uci").cursor()

local TICK = 5                 -- seconds between polls
local IDLE_END = 20            -- seconds without packets => call ended
local MARK = 0x01000000
local RUN = "/tmp/wa-call"
local ACTIVE_FILE = RUN .. "/calls.json"
local HISTORY_FILE = "/etc/wa-call/history.jsonl"
local LIST = "/etc/wa-call/meta-ipv4.txt"
local LIST_DEFAULT = "/etc/wa-call/meta-ipv4.default"

local ARRAY = {}             -- metatable marking tables that must encode as JSON arrays
local cfg = {}

-- ---------- helpers ----------
local function shell(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local out = h:read("*a") or ""
	h:close()
	return out
end

local function ip2n(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
end

local function load_config()
	uci:load("wa_call")
	local c = uci:get_all("wa_call", "main") or {}
	cfg.port = tonumber(c.port) or 3478
	cfg.history = c.history ~= "0"
	cfg.history_max = tonumber(c.history_max) or 200
	local lans = c.lan_if or "br-lan"
	if type(lans) == "string" then lans = { lans } end
	cfg.lan_nets = {}
	for _, dev in ipairs(lans) do
		for ip, len in shell("ip -4 -o addr show dev " .. dev):gmatch("inet (%d+%.%d+%.%d+%.%d+)/(%d+)") do
			local div = 2 ^ (32 - tonumber(len))
			cfg.lan_nets[#cfg.lan_nets + 1] = { math.floor(ip2n(ip) / div), div, ip }
		end
	end
	uci:unload("wa_call")
end

-- source must be a client inside a configured LAN subnet (not the router itself)
local function is_lan_client(ip)
	local n = ip2n(ip)
	if not n then return false end
	for _, net in ipairs(cfg.lan_nets or {}) do
		if math.floor(n / net[2]) == net[1] and ip ~= net[3] then return true end
	end
	return false
end

local function is_private(ip)
	return ip:match("^10%.") or ip:match("^192%.168%.") or ip:match("^172%.1[6-9]%.")
		or ip:match("^172%.2%d%.") or ip:match("^172%.3[01]%.") or ip:match("^100%.") or ip:match("^127%.")
end

local function json(v)
	local t = type(v)
	if t == "table" then
		if #v > 0 or getmetatable(v) == ARRAY then
			local out = {}
			for i, x in ipairs(v) do out[i] = json(x) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local out = {}
		for k, x in pairs(v) do out[#out + 1] = string.format("%q:%s", tostring(k), json(x)) end
		return "{" .. table.concat(out, ",") .. "}"
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(ch) return string.format("\\u%04x", ch:byte()) end) .. '"'
	elseif t == "number" then
		return string.format("%d", v)
	elseif t == "boolean" then
		return tostring(v)
	end
	return "null"
end

local function write_atomic(path, data)
	local f = io.open(path .. ".tmp", "w")
	if not f then return end
	f:write(data)
	f:close()
	os.rename(path .. ".tmp", path)
end

-- ---------- Meta prefix matching ----------
local meta = { nets = {}, mtime = -1, file = nil }
local function load_meta()
	local file = (fs.stat(LIST, "size") or 0) > 0 and LIST or LIST_DEFAULT
	local mtime = fs.stat(file, "mtime") or 0
	if file == meta.file and mtime == meta.mtime then return end
	local nets = {}
	for line in io.lines(file) do
		local ip, len = line:match("^(%d+%.%d+%.%d+%.%d+)/(%d+)")
		if ip then
			local div = 2 ^ (32 - tonumber(len))
			nets[#nets + 1] = { math.floor(ip2n(ip) / div), div }
		end
	end
	meta.nets, meta.mtime, meta.file, meta.cache = nets, mtime, file, {}
end

local function is_meta(ip)
	local hit = meta.cache[ip]
	if hit ~= nil then return hit end
	local n = ip2n(ip)
	hit = false
	if n then
		for _, net in ipairs(meta.nets) do
			if math.floor(n / net[2]) == net[1] then hit = true; break end
		end
	end
	meta.cache[ip] = hit
	return hit
end

-- ---------- device names ----------
local devices, devices_at = {}, 0
local function refresh_devices(now)
	if now - devices_at < 60 then return end
	devices_at = now
	local d = {}
	local f = io.open("/tmp/dhcp.leases")
	if f then
		for line in f:lines() do
			local _, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			if ip then d[ip] = { mac = mac, name = (name ~= "*" and name or nil) } end
		end
		f:close()
	end
	for line in shell("ip -4 neigh show"):gmatch("[^\n]+") do
		local ip, mac = line:match("^(%S+) .- lladdr (%S+)")
		if ip and not d[ip] then d[ip] = { mac = mac } end
	end
	devices = d
end

-- ---------- conntrack parsing ----------
-- returns list of { key, src, dst, marked, up_p, up_b, down_p, down_b }
local function read_flows()
	local flows = {}
	local out = shell("conntrack -L -p udp --orig-port-dst " .. cfg.port)
	for line in out:gmatch("[^\n]+") do
		local src, dst, sport = line:match("src=(%S+) dst=(%S+) sport=(%d+)")
		if src and is_lan_client(src) and not is_private(dst) then
			local p = {}
			for pk, by in line:gmatch("packets=(%d+) bytes=(%d+)") do p[#p + 1] = { tonumber(pk), tonumber(by) } end
			local mark = tonumber(line:match("mark=(%d+)") or "0") or 0
			local marked = math.floor(mark / MARK) % 2 == 1
			if marked or is_meta(dst) then
				flows[#flows + 1] = {
					key = src .. ":" .. sport .. ">" .. dst, src = src, dst = dst, marked = marked,
					up_p = p[1] and p[1][1] or 0, up_b = p[1] and p[1][2] or 0,
					down_p = p[2] and p[2][1] or 0, down_b = p[2] and p[2][2] or 0
				}
			end
		end
	end
	return flows
end

-- ---------- sessions ----------
local prev = {}       -- flow key -> { up_p, up_b, down_p, down_b }
local sessions = {}   -- src ip -> session

local function classify(s)
	local duration = s.last - s.start
	if s.down_p == 0 then return "no reply" end
	if s.down_p >= 50 and duration >= 5 then return "connected" end
	return "setup only"
end

local function relays_list(s)
	local r = setmetatable({}, ARRAY)
	for ip in pairs(s.relays) do r[#r + 1] = ip end
	table.sort(r)
	return r
end

local function session_record(ip, s, now)
	local dev = devices[ip] or {}
	return {
		ip = ip, mac = dev.mac or "", name = dev.name or "",
		start = s.start, ["end"] = s.last, duration = s.last - s.start,
		via = s.vpn and "vpn" or "wan", status = classify(s),
		up_bytes = s.up_b, down_bytes = s.down_b, up_packets = s.up_p, down_packets = s.down_p,
		relays = relays_list(s), active = now and (now - s.last < IDLE_END) or nil
	}
end

local function trim_history()
	local lines = {}
	for line in io.lines(HISTORY_FILE) do lines[#lines + 1] = line end
	if #lines <= cfg.history_max then return end
	local keep = {}
	for i = #lines - cfg.history_max + 1, #lines do keep[#keep + 1] = lines[i] end
	write_atomic(HISTORY_FILE, table.concat(keep, "\n") .. "\n")
end

local function finish(ip, s)
	if not cfg.history or s.up_p < 3 then return end
	local rec = session_record(ip, s)
	local f = io.open(HISTORY_FILE, "a")
	if f then f:write(json(rec), "\n"); f:close() end
	trim_history()
	os.execute(string.format("logger -t wa-call 'call ended: %s (%s) via %s, %s, %ds'",
		rec.name ~= "" and rec.name or ip, ip, rec.via, rec.status, rec.duration))
end

local function tick(now)
	load_meta()
	refresh_devices(now)
	local seen = {}
	for _, fl in ipairs(read_flows()) do
		seen[fl.key] = true
		local p = prev[fl.key] or { up_p = 0, up_b = 0, down_p = 0, down_b = 0 }
		local dup_p, dup_b = fl.up_p - p.up_p, fl.up_b - p.up_b
		local ddn_p, ddn_b = fl.down_p - p.down_p, fl.down_b - p.down_b
		if dup_p < 0 or ddn_p < 0 then dup_p, dup_b, ddn_p, ddn_b = fl.up_p, fl.up_b, fl.down_p, fl.down_b end
		prev[fl.key] = { up_p = fl.up_p, up_b = fl.up_b, down_p = fl.down_p, down_b = fl.down_b }
		if dup_p + ddn_p > 0 then
			local s = sessions[fl.src]
			if not s then
				s = { start = now - TICK, last = now, up_p = 0, up_b = 0, down_p = 0, down_b = 0, relays = {}, vpn = false }
				sessions[fl.src] = s
			end
			s.last = now
			s.up_p, s.up_b = s.up_p + dup_p, s.up_b + dup_b
			s.down_p, s.down_b = s.down_p + ddn_p, s.down_b + ddn_b
			if ddn_p > 0 then s.relays[fl.dst] = true end
			if fl.marked then s.vpn = true end
		end
	end
	for key in pairs(prev) do if not seen[key] then prev[key] = nil end end

	local active = {}
	for ip, s in pairs(sessions) do
		if now - s.last >= IDLE_END then
			finish(ip, s)
			sessions[ip] = nil
		elseif s.up_p >= 3 then
			active[#active + 1] = session_record(ip, s, now)
		end
	end
	write_atomic(ACTIVE_FILE, json(setmetatable(active, ARRAY)) .. "\n")
end

-- ---------- main loop ----------
fs.mkdirr(RUN)
load_config()
local reload_at = 0
-- first pass: learn current counters without opening sessions for old traffic
for _, fl in ipairs((function() load_meta(); return read_flows() end)()) do
	prev[fl.key] = { up_p = fl.up_p, up_b = fl.up_b, down_p = fl.down_p, down_b = fl.down_b }
end
while true do
	nixio.nanosleep(TICK)
	local now = os.time()
	if now - reload_at >= 60 then load_config(); reload_at = now end
	tick(now)
end
