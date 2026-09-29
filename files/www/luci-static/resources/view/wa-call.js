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

function getStatus() {
	return fs.exec(ENGINE, ['status', '--json']).then(function(res) {
		try { return JSON.parse((res.stdout || '').trim()); }
		catch (e) { return null; }
	}).catch(function() { return null; });
}

function getMisses() {
	return fs.read(MISS_LOG).catch(function() { return ''; });
}

function validDevice(section_id, value) {
	if (value == null || value === '' || /^[A-Za-z0-9._-]{1,15}$/.test(value))
		return true;
	return _('Invalid device name');
}

function badge(ok, yes, no) {
	return E('span', {
		'class': 'label',
		'style': 'color:#fff;padding:2px 8px;border-radius:4px;background:' + (ok ? '#2e7d32' : '#9e9e9e')
	}, ok ? yes : no);
}

function statusTable(st) {
	if (!st)
		return E('em', {}, _('Status unavailable - is the wa-call service installed?'));

	var state;
	if (!st.enabled)
		state = badge(false, '', _('Disabled'));
	else if (st.active)
		state = badge(true, _('Active - calls via VPN'), '');
	else
		state = badge(false, '', _('Idle - VPN down, calls via WAN'));

	var rows = [
		[_('State'), state],
		[_('VPN tunnel'), E('span', {}, [ st.vpn_if + ' ', badge(st.vpn_up, _('up'), _('down')) ])],
		[_('Mode'), st.catch_all ? _('Catch-all: all LAN UDP to the call port') : _('Meta (AS32934) destinations only')],
		[_('Meta prefixes loaded'), st.prefixes + (st.list_age_days < 9999 ? ' (' + _('list age') + ': ' + st.list_age_days + ' ' + _('days') + ')' : ' (' + _('bundled list') + ')')],
		[_('Call flows via VPN now'), String(st.call_flows)],
		[_('Possible missed relays'), String(st.misses)]
	];

	return E('table', { 'class': 'table' }, rows.map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'style': 'width:33%' }, E('strong', {}, r[0])),
			E('td', { 'class': 'td left' }, r[1])
		]);
	}));
}

function runAction(args, okMsg) {
	return fs.exec(ENGINE, args).then(function(res) {
		if (res.code === 0)
			ui.addNotification(null, E('p', okMsg), 'info');
		else
			ui.addNotification(null, E('p', _('Command failed: ') + (res.stderr || res.stdout || res.code)), 'danger');
	}).catch(function(e) {
		ui.addNotification(null, E('p', _('Command failed: ') + e.message), 'danger');
	});
}

return view.extend({
	load: function() {
		return Promise.all([ getStatus(), getMisses() ]);
	},

	render: function(data) {
		var m, s, o;

		var statusBox = E('div', { 'id': 'wa-call-status' }, statusTable(data[0]));
		var missBox = E('pre', {
			'id': 'wa-call-misses',
			'style': 'max-height:12em;overflow:auto;white-space:pre-wrap'
		}, (data[1] || '').trim() || _('No missed relays recorded.'));

		poll.add(function() {
			return Promise.all([ getStatus(), getMisses() ]).then(function(d) {
				var box = document.getElementById('wa-call-status');
				var mb = document.getElementById('wa-call-misses');
				if (box) { box.innerHTML = ''; box.appendChild(statusTable(d[0])); }
				if (mb) mb.textContent = (d[1] || '').trim() || _('No missed relays recorded.');
			});
		}, 5);

		m = new form.Map('wa_call');

		s = m.section(form.NamedSection, 'main', 'wa_call', _('Settings'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.Value, 'vpn_if', _('VPN device'),
			_('Network device of the GL VPN tunnel used for calls (e.g. wgclient1).'));
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
					statusBox,
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'click': ui.createHandlerFn(this, function() {
								return runAction(['update-list'], _('Meta prefix list updated.'));
							})
						}, _('Update Meta list now')),
						' ',
						E('button', {
							'class': 'cbi-button cbi-button-apply',
							'click': ui.createHandlerFn(this, function() {
								return runAction(['apply'], _('Rules re-applied.'));
							})
						}, _('Re-apply rules'))
					])
				]),
				formEl,
				E('div', { 'class': 'cbi-section' }, [
					E('h3', {}, _('Possible missed relays')),
					E('p', {}, _('Call-port traffic that went via WAN without any reply while the feature was active. ' +
					             'Repeated entries mean WhatsApp is using relays outside the Meta list - enable catch-all mode.')),
					missBox,
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'cbi-button cbi-button-reset',
							'click': ui.createHandlerFn(this, function() {
								return fs.write(MISS_LOG, '').then(function() {
									document.getElementById('wa-call-misses').textContent = _('No missed relays recorded.');
								});
							})
						}, _('Clear log'))
					])
				])
			]);
		});
	}
});
