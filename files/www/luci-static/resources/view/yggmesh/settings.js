'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require ui';
'require dom';
'require poll';

// The YggMesh page: every user setting of the node (/etc/config/yggmesh) in
// one place. Saving applies them to the whole node through yggmesh-apply,
// which validates them again and rebuilds the network, Wi-Fi, firewall and
// DNS configuration.

const callGenerateKey = rpc.declare({
	object: 'luci.yggmesh',
	method: 'generateKey',
	expect: { private_key: '' }
});

const callKeyInfo = rpc.declare({
	object: 'luci.yggmesh',
	method: 'keyInfo',
	params: [ 'private_key' ]
});

const callStatus = rpc.declare({
	object: 'luci.yggmesh',
	method: 'status'
});

// The node address of the key in the form, filled by updateKeyInfo()
const keyInfoEl = E('span', {}, '…');

function validateExit(section_id, value) {
	if (value == null || value == '')
		return true;
	return /^[0-9a-f]{64}$/i.test(value) ? true : _('Expecting the public key of an exit: 64 hexadecimal digits');
}

function validatePrivateKey(section_id, value) {
	return /^[0-9a-f]{128}$/i.test(value) ? true : _('Expecting 128 hexadecimal digits');
}

function validateWifiKey(section_id, value) {
	return (value.length >= 8 && value.length <= 63) ? true : _('Expecting 8 to 63 characters');
}

function validateUrl(section_id, value) {
	if (value == null || value == '')
		return true;
	return /^https?:\/\/[^\s\/]+(\/\S*)?$/.test(value) ? true : _('Expecting an http:// or https:// URL');
}

function validateCheckInterval(section_id, value) {
	const n = +value;
	if (/^[0-9]+$/.test(value) && ((n >= 1 && n <= 59) || (n >= 60 && n <= 1380 && n % 60 == 0)))
		return true;
	return _('Expecting 1-59 minutes, or a multiple of 60 up to 1380');
}

// Shows the public key, the node address and the client subnet of the key in
// the form
function updateKeyInfo(key) {
	const el = keyInfoEl;

	if (validatePrivateKey(null, key || '') !== true) {
		dom.content(el, E('em', _('Enter a valid private key')));
		return;
	}

	return callKeyInfo(key).then(info => {
		if (!info || !info.address)
			dom.content(el, E('em', _('Invalid private key')));
		else
			dom.content(el, [
				_('Public key:'), ' ', E('strong', { 'style': 'word-break: break-all' }, info.public_key), E('br'),
				_('Node address:'), ' ', info.address, E('br'),
				_('Clients get addresses in:'), ' ', info.subnet, E('br'),
				_('Clearnet address at the exits:'), ' ', info.ipv4
			]);
	});
}

function renderStatus(st) {
	const modes = {
		off: _('off'),
		wan: _('directly through WAN'),
		wan_exit: _('WAN while it works, the exits otherwise'),
		exit: _('only through the exits')
	};
	let clearnet;

	if (!st.mode || !modes[st.mode])
		clearnet = '-';
	else if (st.mode == 'off' || st.mode == 'wan')
		clearnet = modes[st.mode];
	else if (!st.clearnet_running)
		clearnet = _('%s; no exits configured').format(modes[st.mode]);
	else if (st.mode == 'wan_exit' && st.wan)
		clearnet = _('%s; using WAN').format(modes[st.mode]);
	else if (st.exit)
		clearnet = _('%s; using exit %s… (%s, %s ms)').format(modes[st.mode],
			st.exit.substring(0, 16), st.exit_address, st.exit_rtt || '?');
	else
		clearnet = _('%s; no exit works, clients have no clearnet').format(modes[st.mode]);

	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, _('Node address')),
			E('td', { 'class': 'td left' }, st.address || _('Yggdrasil is not running'))
		]),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, _('Yggdrasil peers')),
			E('td', { 'class': 'td left' }, _('%d up of %d').format(st.peers_up || 0, st.peers || 0))
		]),
		E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left' }, _('Clearnet')),
			E('td', { 'class': 'td left' }, clearnet)
		])
	]);
}

return view.extend({
	load() {
		return Promise.all([
			uci.load('yggmesh'),
			L.resolveDefault(callStatus(), {})
		]);
	},

	render([ , status ]) {
		let m, s, o;

		// No title: the header and the status are rendered above the Map,
		// which re-renders its own content on every save
		m = new form.Map('yggmesh');

		// Wi-Fi
		s = m.section(form.NamedSection, 'wifi', 'wifi', _('Wi-Fi for clients'),
			_('The access point for phones and laptops, on every node.'));

		o = s.option(form.Value, 'ssid', _('Network name (SSID)'));
		o.datatype = 'maxlength(32)';
		o.rmempty = false;

		o = s.option(form.ListValue, 'encryption', _('Encryption'));
		o.value('none', _('None, open network'));
		o.value('sae-mixed', _('WPA2/WPA3 (recommended)'));
		o.value('sae', _('WPA3 only'));
		o.value('psk2', _('WPA2 only'));
		o.default = 'none';

		o = s.option(form.Value, 'key', _('Password'));
		o.password = true;
		o.retain = true;
		o.validate = validateWifiKey;
		o.depends('encryption', 'sae-mixed');
		o.depends('encryption', 'sae');
		o.depends('encryption', 'psk2');

		// Yggdrasil
		s = m.section(form.NamedSection, 'yggdrasil', 'yggdrasil', _('Yggdrasil'));

		o = s.option(form.Value, 'private_key', _('Private key'),
			_('Defines the node address. Keep it secret: never share it with anyone, whoever has it can act as this node. Never use the same key on two nodes. Exits know the node by its <b>public</b> key (shown below): give that one to the owners of the exits you use, never the private key. Changing the private key changes the public key too.'));
		o.password = true;
		o.rmempty = false;
		o.validate = validatePrivateKey;
		o.onchange = function(ev, section_id, value) {
			updateKeyInfo(value);
		};

		o = s.option(form.DummyValue, '_generate', ' ');
		o.cfgvalue = function(section_id) {
			return E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function() {
					return callGenerateKey().then(key => {
						const el = this.section.getUIElement(section_id, 'private_key');
						if (!key || !el)
							return;
						el.setValue(key);
						el.triggerValidation();
						return updateKeyInfo(key);
					});
				})
			}, [ _('Generate a new key') ]);
		};

		o = s.option(form.DummyValue, '_key_info', ' ');
		o.cfgvalue = () => keyInfoEl;

		o = s.option(form.DynamicList, 'dns', _('DNS resolvers'),
			_('IPv6 addresses of DNS resolvers reachable over Yggdrasil, used for .ygg and the other Yggdrasil domains.'));
		o.datatype = 'ip6addr';
		o.optional = true;

		// Public peers
		s = m.section(form.NamedSection, 'discovery', 'discovery', _('Public Yggdrasil peers'),
			_('A node with internet on WAN connects to the global Yggdrasil network through public peers it picks by itself.'));

		o = s.option(form.DynamicList, 'instance', _('yggpeers instances'),
			_('Base URLs of <a href="%s" target="_blank" rel="noreferrer">yggpeers</a> instances. A peer is used only if a majority of them report it up; the reported peers are ranked by ping and the fastest are used. Empty: no public peers.')
				.format('https://gitfield.org/fsky/yggpeers'));
		o.validate = validateUrl;
		o.optional = true;

		o = s.option(form.Value, 'count', _('Number of peers'),
			_('How many public peers the node should be connected to in total. Recommended: 2-3.'));
		o.datatype = 'range(1, 10)';
		o.rmempty = false;

		o = s.option(form.Value, 'check_interval', _('Check interval (minutes)'),
			_('How often to check that the current peers are alive. If fewer peers are alive than "Number of peers", a new list is requested from yggpeers and the dead ones are replaced.'));
		o.validate = validateCheckInterval;
		o.rmempty = false;

		o = s.option(form.Value, 'rerank_interval', _('Forced refresh interval (days)'),
			_('How often to request a new peers list from yggpeers, even if all current peers are alive and working well.'));
		o.datatype = 'range(1, 90)';
		o.rmempty = false;

		// Clearnet
		s = m.section(form.NamedSection, 'clearnet', 'clearnet', _('Clearnet (the Internet)'),
			_('What the IPv4 traffic of the clients uses. Their IPv6 traffic reaches Yggdrasil only.'));

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('<b>WAN</b>: directly through the WAN port of this node; nodes without WAN give no clearnet.') + '<br>' +
			_('<b>Exits</b>: only through the clearnet exits, never through WAN, so your IP is never used; if no exit works, clients have no clearnet.') + '<br>' +
			_('<b>WAN, then exits</b>: through WAN while it works, through the exits otherwise; sites see your IP while WAN works.') + '<br>' +
			_('<b>Off</b>: no clearnet, Yggdrasil only.'));
		o.value('wan', _('WAN'));
		o.value('exit', _('Exits'));
		o.value('wan_exit', _('WAN, then exits'));
		o.value('off', _('Off'));
		o.default = 'wan_exit';

		o = s.option(form.DynamicList, 'exit', _('Exits'),
			_('Public keys of <a href="%s" target="_blank" rel="noreferrer">clearnet exits</a>. The fastest working one is used. An exit serves only the nodes whose public keys its owner has added. Switching to another exit restarts Yggdrasil: the mesh links of this node drop for a few seconds.')
				.format('https://github.com/ed-asriyan/YggMesh-exit-node'));
		o.validate = validateExit;
		o.optional = true;
		o.retain = true;
		o.depends('mode', 'exit');
		o.depends('mode', 'wan_exit');

		return m.render().then(node => {
			const statusEl = E('div', { 'id': 'yggmesh-status' }, renderStatus(status));

			poll.add(() => L.resolveDefault(callStatus(), {}).then(st => {
				dom.content(statusEl, renderStatus(st));
			}), 10);

			updateKeyInfo(uci.get('yggmesh', 'yggdrasil', 'private_key'));

			return E('div', {}, [
				E('h2', _('YggMesh')),
				E('div', { 'class': 'cbi-map-descr' },
					_('All settings of this node. They are checked and applied to the whole node, and kept when the firmware is upgraded with "Keep settings".')),
				E('div', { 'class': 'alert-message warning' }, [
					E('p', _('Change the node settings here only: they are checked and applied safely. Changes to the network, Wi-Fi, firewall or DHCP on the other pages may break the node, at your own risk, and are overwritten by the next save here or the next firmware upgrade.'))
				]),
				E('div', { 'class': 'cbi-section' }, [
					E('h3', _('Status')),
					statusEl
				]),
				node
			]);
		});
	},

	// A Wi-Fi change disconnects the devices on that Wi-Fi: the automatic
	// rollback would undo it while they reconnect, so it is applied unchecked
	handleSaveApply(ev, mode) {
		return this.handleSave(ev).then(() => L.resolveDefault(uci.changes(), {})).then(changes => {
			const wifi = (changes.yggmesh || []).some(c => c[1] == 'wifi');

			if (!wifi)
				return ui.changes.apply(mode == '0');

			ui.showModal(_('Wi-Fi settings change'), [
				E('p', _('Devices connected over the YggMesh Wi-Fi, maybe this one, lose the connection and have to connect to the changed network. The change is applied without the automatic rollback, which would undo it while they reconnect.')),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]), ' ',
					E('button', {
						'class': 'btn cbi-button-action important',
						'click': () => {
							ui.hideModal();
							ui.changes.apply(false);
						}
					}, [ _('Apply') ])
				])
			]);
		});
	}
});
