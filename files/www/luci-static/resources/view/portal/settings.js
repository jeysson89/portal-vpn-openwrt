'use strict';
'require view';
'require fs';
'require ui';
'require dom';
'require poll';

var HELPER = '/etc/portal/portal-luci.sh';

function parseJSON(s) {
	try { return JSON.parse(s); } catch (e) { return null; }
}

return view.extend({
	load: function() {
		return Promise.all([ fs.exec(HELPER, [ 'status' ]) ]);
	},

	msg: function(text, cls) {
		var m = document.getElementById('set-msg');
		if (!m) return;
		m.style.display = 'block';
		m.className = 'alert-message ' + (cls || '');
		dom.content(m, text);
	},

	/* an RPC rejection must be visible: otherwise the "..." message stays forever */
	fail: function(e) {
		this.msg('Ошибка: ' + (e && e.message ? e.message : e), 'danger');
	},

	pollStatus: function() {
		var self = this;
		return fs.exec(HELPER, [ 'status' ]).then(function(res) {
			var st = parseJSON(res.stdout || '');
			if (!st) return;
			var el = document.getElementById('s-relay-cur');
			if (el) el.textContent = st.relay || '?';
			el = document.getElementById('s-country-cur');
			if (el) el.textContent = st.country || '?';
			el = document.getElementById('s-run');
			if (el) el.textContent = st.running ? ('запущен, PID ' + st.pid) : 'остановлен';
		});
	},

	handleSaveRelay: function(ev) {
		var self = this;
		var inp = document.getElementById('s-relay-input');
		var v = inp ? inp.value.trim() : '';
		if (!/^(https?|socks5h?):\/\/[A-Za-z0-9.\-]+(:[0-9]+)/.test(v)) {
			self.msg('Неверный формат релея. Пример: http://1.2.3.4:39811 или socks5://1.2.3.4:1080', 'danger');
			return;
		}
		self.msg('сохраняю релей и перезапускаю движок...');
		return fs.exec(HELPER, [ 'setrelay', v ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.relay) {
				self.msg('Релей сохранён: ' + r.relay + '. Движок перезапущен.', 'success');
				return self.pollStatus();
			} else
				self.msg('Ошибка сохранения релея.', 'danger');
		}).catch(L.bind(self.fail, self));
	},

	handleSaveCountry: function(ev) {
		var self = this;
		var sel = document.getElementById('s-country-select');
		var v = sel ? sel.value : '';
		self.msg('сохраняю страну и перезапускаю движок...');
		return fs.exec(HELPER, [ 'setcountry', v ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.country)
				self.msg('Страна сохранена: ' + r.country + '. Движок перезапущен.', 'success');
			else
				self.msg('Ошибка сохранения страны.', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	handleRestart: function(ev) {
		var self = this;
		self.msg('перезапуск движка...');
		return fs.exec(HELPER, [ 'restart' ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.restarted && r.pid !== '0')
				self.msg('Перезапущено, PID ' + r.pid, 'success');
			else
				self.msg('Движок не поднялся! Откройте «Лог движка» ниже.', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	showLog: function(which) {
		var self = this;
		var pre = document.getElementById('set-log');
		if (pre && pre.getAttribute('data-which') === which && pre.style.display !== 'none') {
			pre.style.display = 'none';
			pre.setAttribute('data-which', '');
			return;
		}
		self.msg('читаю ' + (which === 'logssb' ? 'лог sing-box' : 'лог движка') + '...');
		return fs.exec(HELPER, [ which ]).then(function(res) {
			if (pre) {
				pre.style.display = 'block';
				pre.setAttribute('data-which', which);
				dom.content(pre, document.createTextNode(res.stdout || '(пусто)'));
			}
			self.msg(which === 'logssb' ? 'лог sing-box обновлён' : 'лог движка обновлён', 'success');
		}).catch(L.bind(self.fail, self));
	},

	handleLogEngine: function(ev) {
		return this.showLog('logs');
	},

	handleLogSingbox: function(ev) {
		return this.showLog('logssb');
	},

	render: function(data) {
		var self = this;
		var st = parseJSON((data[0] && data[0].stdout) || '');

		var body = E('div', {}, [
			E('h3', {}, [ 'Настройки движка Portal VPN' ]),
			E('p', { 'style': 'font-size:12px' }, [
				'Релей — промежуточный сервер, через который идёт туннель Opera. ',
				'Если туннель перестал работать (или медленный), впишите другой релей или нажмите «Перезапустить движок» — ',
				'авто-режим обычно чинит это сам (watchdog каждые 5 минут). ',
				'Страна определяет, через какой регион Opera выпускает трафик: AM (Америка) или EU (Европа).'
			]),

			E('table', { 'class': 'table', 'style': 'max-width:560px' }, [
				E('tr', {}, [ E('td', { 'style': 'width:40%' }, [ 'Состояние движка' ]), E('td', { 'id': 's-run' }, [ st ? (st.running ? 'запущен, PID ' + st.pid : 'остановлен') : '?' ]) ]),
				E('tr', {}, [ E('td', {}, [ 'Текущий релей' ]), E('td', { 'id': 's-relay-cur' }, [ st ? (st.relay || '') : '?' ]) ]),
				E('tr', {}, [ E('td', {}, [ 'Текущая страна' ]), E('td', { 'id': 's-country-cur' }, [ st ? (st.country || '') : '?' ])])
			]),

			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-title' }, [ 'Новый релей (HTTP/SOCKS5)' ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', { 'type': 'text', 'id': 's-relay-input', 'class': 'cbi-input-text', 'value': (st ? (st.relay || '') : ''), 'style': 'width:100%; max-width:560px', 'placeholder': 'http://1.2.3.4:39811' })
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-title' }, [ 'Страна туннеля' ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('select', { 'id': 's-country-select', 'class': 'cbi-input-select', 'style': 'width:auto' }, [
						E('option', { 'value': 'AM', 'selected': (st && st.country === 'AM') ? 'selected' : null }, [ 'AM (Америка)' ]),
						E('option', { 'value': 'EU', 'selected': (st && st.country === 'EU') ? 'selected' : null }, [ 'EU (Европа)' ])
					])
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleSaveRelay') }, [ 'Сохранить релей' ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleSaveCountry') }, [ 'Сохранить страну' ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(self, 'handleRestart') }, [ 'Перезапустить движок' ])
			]),

			E('div', { 'id': 'set-msg', 'class': 'alert-message', 'style': 'display:none' }, [ '' ]),

			E('h3', { 'style': 'margin-top:24px' }, [ 'Логи' ]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'margin:0 0 8px' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(self, 'handleLogEngine') }, [ 'Лог движка' ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(self, 'handleLogSingbox') }, [ 'Лог sing-box' ])
			]),
			E('pre', { 'id': 'set-log', 'style': 'display:none; font-size:11px; white-space:pre-wrap; max-height:320px; overflow:auto; background:rgba(128,128,128,0.1); padding:8px; border:1px solid rgba(128,128,128,0.35); border-radius:4px' }, [ '' ])
		]);

		poll.add(L.bind(self.pollStatus, self), 15);
		return body;
	},

	/* these views have no CBI map: drop LuCI's useless Save/Reset footer */
	addFooter: function() { return E([]); },

	handleSaveApply: null
});
