#!/usr/bin/lua
-- SPDX-License-Identifier: MIT
-- https://github.com/amartinawi/openwrt-whatsapp-calls-vpn
--
-- Call-path self-test: sends STUN Binding Requests (RFC 5389) to WhatsApp relays
-- over the WAN and over the VPN, plus a non-Meta control probe over the WAN, and
-- prints a JSON verdict. Usage: lua selftest.lua [output_file]
--        lua selftest.lua --vpn-probe   (watchdog: VPN relay probe only; prints 'ok <rtt> <relay>' or 'fail', exit 0/1)

local nixio = require "nixio"
local uci = require("uci").cursor()

local TIMEOUT_MS = 1500
local MAX_TARGETS = 3        -- relays tried per path before giving up

local DEFAULT_TARGETS = {
	"57.144.149.57", "57.144.55.57", "57.144.43.57", "57.144.213.57",
	"57.144.69.57", "57.144.187.57", "57.144.125.57"
}

local function cfg(opt, default)
	local v = uci:get("wa_call", "main", opt)
	if v == nil or v == "" then return default end
	return v
end

local function shell(cmd)
	local h = io.popen(cmd .. " 2>/dev/null")
	if not h then return "" end
	local out = h:read("*a") or ""
	h:close()
	return out
end

local function now_ms()
	local s, us = nixio.gettimeofday()
	return s * 1000 + math.floor(us / 1000)
end

local function txid()
	local t = {}
	for i = 1, 12 do t[i] = string.char(math.random(0, 255)) end
	return table.concat(t)
end

-- One STUN Binding Request. Returns rtt_ms or nil, err
local function probe(ip, port, dev)
	local s = nixio.socket("inet", "dgram")
	if not s then return nil, "socket" end
	if dev and dev ~= "" then
		local ok = s:setsockopt("socket", "bindtodevice", dev)
		if not ok then s:close(); return nil, "bind " .. dev end
	end
	local id = txid()
	local req = "\0\1\0\0\33\18\164\66" .. id
	local t0 = now_ms()
	if not s:sendto(req, ip, port) then s:close(); return nil, "send" end
	local deadline = t0 + TIMEOUT_MS
	while true do
		local left = deadline - now_ms()
		if left <= 0 then break end
		local fds = { { fd = s, events = nixio.poll_flags("in") } }
		local n = nixio.poll(fds, left)
		if not n or n <= 0 then break end
		local data = s:recvfrom(1500)
		-- 0x0101 = Binding Success Response with our transaction id
		if data and #data >= 20 and data:byte(1) == 1 and data:byte(2) == 1 and data:sub(9, 20) == id then
			s:close()
			return now_ms() - t0
		end
	end
	s:close()
	return nil, "timeout"
end

-- Try up to MAX_TARGETS relays; first reply wins
local function probe_path(targets, port, dev)
	local tried = {}
	for i, ip in ipairs(targets) do
		if i > MAX_TARGETS then break end
		local rtt = probe(ip, port, dev)
		tried[#tried + 1] = ip
		if rtt then return { ok = true, rtt = rtt, relay = ip, tried = tried } end
	end
	return { ok = false, tried = tried }
end

local function resolve(host)
	local ai = nixio.getaddrinfo(host, "inet")
	return ai and ai[1] and ai[1].address
end

local function wan_device()
	return shell("ip -4 route show default table main | awk '{for(i=1;i<NF;i++) if($i==\"dev\"){print $(i+1); exit}}'"):gsub("%s+", "")
end

local function dev_up(dev)
	return dev ~= "" and shell("ip link show " .. dev .. " 2>/dev/null"):find(",UP") ~= nil
end

-- JSON encoding for the flat structures used here
local function json(v)
	local t = type(v)
	if t == "table" then
		if #v > 0 then
			local out = {}
			for i, x in ipairs(v) do out[i] = json(x) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local out = {}
		for k, x in pairs(v) do out[#out + 1] = string.format("%q:%s", tostring(k), json(x)) end
		return "{" .. table.concat(out, ",") .. "}"
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	end
	return "null"
end

math.randomseed((os.time() % 1000000) * 100 + nixio.getpid() % 100)

local port = tonumber(cfg("port", "3478"))
local vpn_if = cfg("vpn_if", "wgclient1")
local targets = uci:get("wa_call", "main", "selftest_target")
if type(targets) ~= "table" or #targets == 0 then targets = DEFAULT_TARGETS end
local control = cfg("selftest_control", "stun.cloudflare.com:3478")
local chost, cport = control:match("^([^:]+):?(%d*)$")
cport = tonumber(cport) or 3478

-- Fast VPN-only probe for the watchdog (the feature's rule 5201 routes the bound socket)
if arg[1] == "--vpn-probe" then
	if not dev_up(vpn_if) then print("fail vpn-down"); os.exit(1) end
	local r = probe_path(targets, port, vpn_if)
	if r.ok then print(string.format("ok %d %s", r.rtt, r.relay)); os.exit(0) end
	print("fail " .. table.concat(r.tried, ","))
	os.exit(1)
end

local wan_if = wan_device()
local result = { time = os.time(), vpn_if = vpn_if, wan_if = wan_if }

-- WAN control (non-Meta STUN on the same port)
local cip = chost and resolve(chost)
if cip then
	local rtt = probe(cip, cport, wan_if)
	result.control = { ok = rtt ~= nil, rtt = rtt, target = chost .. ":" .. cport }
else
	result.control = { ok = false, error = "dns", target = control }
end

-- WAN relay path
result.wan = probe_path(targets, port, wan_if)

-- VPN relay path
if dev_up(vpn_if) then
	-- a socket bound to the VPN device needs a route: add a temporary oif rule if the feature is idle
	local tmp_rule = shell("ip rule | grep -c '^5201:'"):gsub("%s+", "") == "0"
	if tmp_rule then
		os.execute("ip route replace default dev " .. vpn_if .. " table 2001 2>/dev/null")
		os.execute("ip rule add pref 5201 oif " .. vpn_if .. " lookup 2001 2>/dev/null")
	end
	result.vpn = probe_path(targets, port, vpn_if)
	if tmp_rule then
		os.execute("ip rule del pref 5201 2>/dev/null")
		if shell("ip rule | grep -c '^5200:'"):gsub("%s+", "") == "0" then
			os.execute("ip route flush table 2001 2>/dev/null")
		end
	end
else
	result.vpn = { ok = false, down = true }
end

-- Verdict
local v
if not result.control.ok and not result.wan.ok then
	v = { code = "wan_down", text = "WAN UDP not working (control probe failed) - check the internet connection" }
elseif result.wan.ok then
	v = { code = "not_blocked", text = "WhatsApp relays reachable directly - the ISP is not blocking calls right now" }
elseif result.vpn.down then
	v = { code = "blocked_vpn_down", text = "ISP blocks WhatsApp call relays and the VPN is down - calls will fail" }
elseif result.vpn.ok then
	v = { code = "blocked_vpn_ok", text = "ISP blocks WhatsApp call relays; VPN path works - calls go via VPN" }
else
	v = { code = "blocked_vpn_fail", text = "ISP blocks WhatsApp call relays and the VPN server cannot reach them - switch VPN server" }
end
result.verdict = v

local out = json(result)
print(out)
if arg[1] then
	local f = io.open(arg[1] .. ".tmp", "w")
	if f then f:write(out, "\n"); f:close(); os.rename(arg[1] .. ".tmp", arg[1]) end
end
os.exit(0)
