'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require poll';

// SPDX-License-Identifier: MIT
// https://github.com/amartinawi/openwrt-whatsapp-calls-vpn

var ENGINE = '/etc/wa-call/wa-call.sh';
var MISS_LOG = '/tmp/wa-call/misses.log';
var SELFTEST = '/tmp/wa-call/selftest.json';
var CALLS = '/tmp/wa-call/calls.json';
var HISTORY = '/etc/wa-call/history.jsonl';
var HISTORY_SHOWN = 50;

var COLOR = { ok: '#2e7d32', bad: '#c62828', idle: '#9e9e9e', vpn: '#1565c0', wan: '#ef6c00' };

/* ---------- data ---------- */

function readJSON(path, fallback) {
	return fs.read(path).then(function(t) {
		try { return JSON.parse((t || '').trim()); } catch (e) { return fallback; }
	}).catch(function() { return fallback; });
}

function getStatus() {
	return fs.exec(ENGINE, ['status', '--json']).then(function(res) {
		try { return JSON.parse((res.stdout || '').trim()); } catch (e) { return null; }
	}).catch(function() { return null; });
}

function getHistory() {
	return fs.read(HISTORY).then(function(t) {
		return (t || '').split('\n').filter(function(l) { return l.trim(); }).map(function(l) {
			try { return JSON.parse(l); } catch (e) { return null; }
		}).filter(function(r) { return r; }).reverse();
	}).catch(function() { return []; });
}

function getMisses() {
	return fs.read(MISS_LOG).catch(function() { return ''; });
}

function loadAll() {
	return Promise.all([ getStatus(), readJSON(SELFTEST, null), readJSON(CALLS, []), getHistory(), getMisses() ]);
}

/* ---------- formatting ---------- */

function badge(color, text) {
	return E('span', {
		'class': 'label',
		'style': 'color:#fff;padding:2px 8px;border-radius:4px;white-space:nowrap;background:' + color
	}, text);
}

function fmtBytes(n) {
	n = +n || 0;
	if (n < 1024) return n + ' B';
	if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
	return (n / 1048576).toFixed(1) + ' MB';
}

function fmtDuration(s) {
	s = Math.max(0, Math.round(+s || 0));
	var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60;
	var mm = (h ? String(m).padStart(2, '0') : String(m)), ss = String(sec).padStart(2, '0');
	return (h ? h + ':' : '') + mm + ':' + ss;
}

function fmtTime(ts) {
	if (!ts) return '-';
	var d = new Date(ts * 1000), now = new Date();
	var time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
	return d.toDateString() === now.toDateString() ? time : d.toLocaleDateString() + ' ' + time;
}

function deviceCell(r) {
	return r.name ? E('span', {}, [ r.name, E('br'), E('small', {}, r.ip) ]) : E('span', {}, r.ip);
}

function routeBadge(via) {
	return via === 'vpn' ? badge(COLOR.vpn, _('VPN')) : badge(COLOR.wan, _('WAN'));
}

function statusBadge(st) {
	if (st === 'connected') return badge(COLOR.ok, _('Connected'));
	if (st === 'no reply') return badge(COLOR.bad, _('No reply (blocked)'));
	return badge(COLOR.idle, _('Setup only'));
}

function kvTable(rows) {
	return E('table', { 'class': 'table' }, rows.map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:33%' }, E('strong', {}, r[0])),
			E('td', { 'class': 'td left' }, r[1])
		]);
	}));
}

function gridTable(headers, rows, emptyText) {
	var t = E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' }, headers.map(function(h) { return E('th', { 'class': 'th' }, h); }))
	]);
	if (!rows.length)
		t.appendChild(E('tr', { 'class': 'tr placeholder' }, E('td', { 'class': 'td', 'colspan': headers.length }, E('em', {}, emptyText))));
	rows.forEach(function(r) {
		t.appendChild(E('tr', { 'class': 'tr' }, r.map(function(c) { return E('td', { 'class': 'td' }, c); })));
	});
	return t;
}

/* ---------- sections ---------- */

function renderStatus(st) {
	if (!st)
		return E('em', {}, _('Status unavailable - is the wa-call service installed?'));
	var state = !st.enabled ? badge(COLOR.idle, _('Disabled'))
		: st.active ? badge(COLOR.ok, _('Active - calls via VPN'))
		: badge(COLOR.idle, _('Idle - VPN down, calls via WAN'));
	return kvTable([
		[_('State'), state],
		[_('VPN tunnel'), E('span', {}, [ st.vpn_if + ' ', st.vpn_up ? badge(COLOR.ok, _('up')) : badge(COLOR.idle, _('down')) ])],
		[_('Mode'), st.catch_all ? _('Catch-all: all LAN UDP to the call port') : _('Meta (AS32934) destinations only')],
		[_('Meta prefixes loaded'), st.prefixes + (st.list_age_days < 9999
			? ' (' + _('list age') + ': ' + st.list_age_days + ' ' + _('days') + ')' : ' (' + _('bundled list') + ')')],
		[_('Active calls'), String(st.active_calls || 0) + ' (' + st.call_flows + ' ' + _('flows via VPN') + ')'],
		[_('Possible missed relays'), String(st.misses)]
	]);
}

function probeText(p, kind) {
	if (!p) return '-';
	if (p.down) return badge(COLOR.idle, _('VPN down'));
	if (p.ok) return E('span', {}, [ badge(COLOR.ok, kind === 'control' ? _('OK') : _('Reachable')),
		' ' + p.rtt + ' ms' + (p.relay ? ' (' + p.relay + ')' : p.target ? ' (' + p.target + ')' : '') ]);
	if (kind === 'wan') return E('span', {}, [ badge(COLOR.wan, _('Blocked')), ' ' + _('no reply from %d relays').format((p.tried || []).length) ]);
	return E('span', {}, [ badge(COLOR.bad, _('Failed')), ' ' + (p.target || (p.tried || []).join(', ')) ]);
}

function renderSelftest(r) {
	if (!r || !r.verdict)
		return E('em', {}, _('No self-test run yet. Click "Run self-test now".'));
	var good = (r.verdict.code === 'blocked_vpn_ok' || r.verdict.code === 'not_blocked');
	return kvTable([
		[_('Result'), E('span', {}, [ badge(good ? COLOR.ok : COLOR.bad, good ? _('OK') : _('Problem')), ' ', r.verdict.text ])],
		[_('Checked'), fmtTime(r.time)],
		[_('WAN control (non-Meta STUN)'), probeText(r.control, 'control')],
		[_('WhatsApp relays via WAN') + ' (' + (r.wan_if || '-') + ')', probeText(r.wan, 'wan')],
		[_('WhatsApp relays via VPN') + ' (' + (r.vpn_if || '-') + ')', probeText(r.vpn, 'vpn')]
	]);
}

function renderActive(calls) {
	var now = Date.now() / 1000;
	return gridTable(
		[ _('Device'), _('Started'), _('Duration'), _('Data ↑ / ↓'), _('Route'), _('Relays') ],
		(calls || []).map(function(c) {
			return [ deviceCell(c), fmtTime(c.start), fmtDuration(now - c.start),
				fmtBytes(c.up_bytes) + ' / ' + fmtBytes(c.down_bytes), routeBadge(c.via), (c.relays || []).join(', ') ];
		}),
		_('No active calls.'));
}

function renderHistory(hist) {
	return gridTable(
		[ _('Time'), _('Device'), _('Duration'), _('Status'), _('Route'), _('Data ↑ / ↓') ],
		(hist || []).slice(0, HISTORY_SHOWN).map(function(c) {
			return [ fmtTime(c.start), deviceCell(c), fmtDuration(c.duration), statusBadge(c.status),
				routeBadge(c.via), fmtBytes(c.up_bytes) + ' / ' + fmtBytes(c.down_bytes) ];
		}),
		_('No calls recorded yet.'));
}

function replace(id, node) {
	var el = document.getElementById(id);
	if (el) { el.innerHTML = ''; el.appendChild(node); }
}

function runAction(args, okMsg) {
	return fs.exec(ENGINE, args).then(function(res) {
		if (res.code === 0)
			ui.addNotification(null, E('p', okMsg), 'info');
		else
			ui.addNotification(null, E('p', _('Command failed: ') + (res.stderr || res.stdout || res.code)), 'danger');
		return res;
	}).catch(function(e) {
		ui.addNotification(null, E('p', _('Command failed: ') + e.message), 'danger');
	});
}

function validDevice(section_id, value) {
	if (value == null || value === '' || /^[A-Za-z0-9._-]{1,15}$/.test(value))
		return true;
	return _('Invalid device name');
}

function button(cls, label, fn) {
	return E('button', { 'class': 'cbi-button ' + cls, 'click': ui.createHandlerFn(null, fn) }, label);
}

/* ---------- view ---------- */

return view.extend({
	load: loadAll,

	render: function(data) {
		var m, s, o;

		poll.add(function() {
			return loadAll().then(function(d) {
				replace('wa-call-status', renderStatus(d[0]));
				replace('wa-call-selftest', renderSelftest(d[1]));
				replace('wa-call-active', renderActive(d[2]));
				replace('wa-call-history', renderHistory(d[3]));
				var mb = document.getElementById('wa-call-misses');
				if (mb) mb.textContent = (d[4] || '').trim() || _('No missed relays recorded.');
			});
		}, 5);

		m = new form.Map('wa_call');
		s = m.section(form.NamedSection, 'main', 'wa_call', _('Settings'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'vpn_if', _('VPN device'),
			_('Network device of the VPN tunnel used for calls (e.g. wgclient1, wg0).'));
		o.validate = validDevice;
		o.placeholder = 'wgclient1';
		o.rmempty = false;

		o = s.option(form.DynamicList, 'lan_if', _('LAN bridges'),
			_('Clients on these bridges are covered (e.g. br-lan).'));
		o.validate = validDevice;
		o.placeholder = 'br-lan';

		o = s.option(form.Flag, 'catch_all', _('Catch-all mode'),
			_('Send ALL LAN UDP traffic to the call port through the VPN, not only to Meta addresses. ' +
			  'Use if calls fail and "missed relays" appear below.'));
		o.rmempty = false;

		o = s.option(form.Value, 'port', _('Call port (UDP)'));
		o.datatype = 'port';
		o.placeholder = '3478';

		o = s.option(form.Value, 'refresh_days', _('Refresh Meta list every (days)'), _('0 = never'));
		o.datatype = 'uinteger';
		o.placeholder = '7';

		o = s.option(form.Value, 'selftest_interval', _('Self-test every (minutes)'), _('0 = only when run manually'));
		o.datatype = 'uinteger';
		o.placeholder = '30';

		o = s.option(form.Flag, 'history', _('Record call history'),
			_('Store finished calls in /etc/wa-call/history.jsonl (device, time, duration, data).'));
		o.rmempty = false;
		o.default = '1';

		o = s.option(form.Value, 'history_max', _('History size (calls)'));
		o.datatype = 'range(10,5000)';
		o.placeholder = '200';
		o.depends('history', '1');

		o = s.option(form.Flag, 'miss_check', _('Detect missed relays'),
			_('Log call attempts that went via WAN and got no reply.'));
		o.rmempty = false;

		return m.render().then(function(formEl) {
			return E([], [
				E('h2', {}, _('WhatsApp Calls via VPN')),
				E('div', { 'class': 'cbi-map-descr' },
					_('Routes only WhatsApp call audio/video (UDP to Meta call relays) through the VPN tunnel. ' +
					  'Chat and all other traffic stay on the normal WAN. The feature follows the tunnel automatically: ' +
					  'when the tunnel is down, calls fall back to WAN.')),

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Status')),
					E('div', { 'id': 'wa-call-status' }, renderStatus(data[0])),
					E('div', { 'class': 'right' }, [
						button('cbi-button-action', _('Update Meta list now'), function() {
							return runAction(['update-list'], _('Meta prefix list updated.'));
						}), ' ',
						button('cbi-button-apply', _('Re-apply rules'), function() {
							return runAction(['apply'], _('Rules re-applied.'));
						})
					])
				]),

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Call-path self-test')),
					E('p', {}, _('Sends STUN probes to WhatsApp call relays directly over the WAN and through the VPN, ' +
					             'plus a control probe to a non-Meta STUN server, to show whether the ISP blocks calls ' +
					             'and whether the VPN path works.')),
					E('div', { 'id': 'wa-call-selftest' }, renderSelftest(data[1])),
					E('div', { 'class': 'right' }, [
						button('cbi-button-action', _('Run self-test now'), function() {
							return fs.exec(ENGINE, ['selftest']).then(function(res) {
								var r = null;
								try { r = JSON.parse((res.stdout || '').trim()); } catch (e) {}
								if (!r) ui.addNotification(null, E('p', _('Self-test failed: ') + (res.stderr || res.stdout || res.code)), 'danger');
								else replace('wa-call-selftest', renderSelftest(r));
							});
						})
					])
				]),

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Active calls')),
					E('div', { 'id': 'wa-call-active' }, renderActive(data[2]))
				]),

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Call history')),
					E('p', {}, _('Last %d calls. "Connected" = audio flowed; "Setup only" = rang but no media; ' +
					             '"No reply" = relays unreachable (blocked).').format(HISTORY_SHOWN)),
					E('div', { 'id': 'wa-call-history' }, renderHistory(data[3])),
					E('div', { 'class': 'right' }, [
						button('cbi-button-reset', _('Clear history'), function() {
							return fs.write(HISTORY, '').then(function() { replace('wa-call-history', renderHistory([])); });
						})
					])
				]),

				formEl,

				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Possible missed relays')),
					E('p', {}, _('Call-port traffic that went via WAN without any reply while a call was active. ' +
					             'Repeated Meta entries mean WhatsApp is using relays outside the list - enable catch-all mode.')),
					E('pre', { 'id': 'wa-call-misses', 'style': 'max-height:12em;overflow:auto;white-space:pre-wrap' },
						(data[4] || '').trim() || _('No missed relays recorded.')),
					E('div', { 'class': 'right' }, [
						button('cbi-button-reset', _('Clear log'), function() {
							return fs.write(MISS_LOG, '').then(function() {
								document.getElementById('wa-call-misses').textContent = _('No missed relays recorded.');
							});
						})
					])
				])
			]);
		});
	}
});
