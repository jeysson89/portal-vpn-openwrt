'use strict';
'require view';
'require fs';
'require poll';
'require ui';
'require dom';

var HELPER = '/etc/portal/portal-luci.sh';

function parseJSON(s) {
	try { return JSON.parse(s); } catch (e) { return null; }
}

function escapeRe(s) {
	return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/* header line of a preset block: "# --- Имя ---" */
function presetHeaderRe(name) {
	return new RegExp('^#\\s*---\\s*' + escapeRe(name) + '\\s*---\\s*$', 'i');
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec(HELPER, [ 'getwhite' ]),
			fs.exec(HELPER, [ 'getblack' ]),
			fs.exec(HELPER, [ 'devlist' ]),
			fs.exec(HELPER, [ 'presets' ]),
			fs.exec(HELPER, [ 'routing' ])
		]);
	},

	msg: function(text, cls) {
		var m = document.getElementById('route-msg');
		if (!m) return;
		m.style.display = 'block';
		m.className = 'alert-message ' + (cls || '');
		dom.content(m, text);
	},

	/* ---------- saving ---------- */

	saveList: function(action, taId) {
		var self = this;
		var ta = document.getElementById(taId);
		var v = ta ? ta.value : '';
		self.msg('сохраняю: генерация конфигов, рестарт sing-box (до 15 с)...');
		return fs.exec(HELPER, [ action, v ]).then(function(res) {
			var ok = (res.stdout || '').indexOf('OK:') >= 0;
			self.msg((res.stdout || 'ошибка').trim(), ok ? 'success' : 'danger');
			return self.refreshTech();
		});
	},

	handleSaveWhite: function(ev) { return this.saveList('setwhite', 'wl-text'); },
	handleSaveBlack: function(ev) { return this.saveList('setblack', 'bl-text'); },

	/* ---------- presets ---------- */

	handleAddPreset: function(ev) {
		var self = this;
		var btn = ev && (ev.currentTarget || ev.target);
		if (!btn || !btn.getAttribute || !btn.getAttribute('data-name')) return;
		var name = btn.getAttribute('data-name');
		var doms = parseJSON(btn.getAttribute('data-domains')) || [];
		var ta = document.getElementById(btn.getAttribute('data-target'));
		var sidId = btn.getAttribute('data-sid');
		if (!ta || !doms.length) return;
		var exist = {};
		ta.value.split('\n').forEach(function(l) {
			l = l.trim();
			if (l && l.charAt(0) !== '#') exist[l.replace(/^\*+\./, '').replace(/\.$/, '')] = 1;
		});
		var block = [];
		doms.forEach(function(d) {
			if (!exist[d]) { exist[d] = 1; block.push(d); }
		});
		if (!block.length) {
			self.togglePresetBtn(btn, 'remove', name, doms, ta.id, sidId);
			self.updatePresetStatus(sidId, name, doms.length, doms.length);
			return;
		}
		/* insert the missing domains into the preset's existing block, if any,
		   so repeated clicks never duplicate the "# --- Имя ---" header */
		var hdr = presetHeaderRe(name);
		var lines = ta.value.replace(/\s*$/, '').split('\n');
		var hi = -1, k;
		for (k = 0; k < lines.length; k++) {
			if (hdr.test(lines[k].trim())) { hi = k; break; }
		}
		if (hi >= 0) {
			var end = lines.length;
			for (k = hi + 1; k < lines.length; k++) {
				if (/^#\s*---.*---\s*$/.test(lines[k].trim())) { end = k; break; }
			}
			var ins = end;
			while (ins > hi + 1 && lines[ins - 1].trim() === '') ins--;
			lines.splice.apply(lines, [ ins, 0 ].concat(block));
			ta.value = lines.join('\n') + '\n';
		} else {
			ta.value = lines.join('\n') + '\n\n# --- ' + name + ' ---\n' + block.join('\n') + '\n';
		}
		self.updateCounters();
		self.togglePresetBtn(btn, 'remove', name, doms, ta.id, sidId);
		self.updatePresetStatus(sidId, name, doms.length, doms.length);
		self.msg('Добавлено ' + block.length + ' доменов. Нажмите «Сохранить и применить», чтобы вступить в силу.', 'success');
	},

	handleRemovePreset: function(ev) {
		var self = this;
		var btn = ev && (ev.currentTarget || ev.target);
		if (!btn || !btn.getAttribute || !btn.getAttribute('data-name')) return;
		var name = btn.getAttribute('data-name');
		var doms = parseJSON(btn.getAttribute('data-domains')) || [];
		var ta = document.getElementById(btn.getAttribute('data-target'));
		var sidId = btn.getAttribute('data-sid');
		if (!ta || !doms.length) return;
		var exist = {};
		ta.value.split('\n').forEach(function(l) {
			l = l.trim();
			if (l && l.charAt(0) !== '#') exist[l.replace(/^\*+\./, '').replace(/\.$/, '')] = 1;
		});
		var toRemove = {};
		var have = 0;
		doms.forEach(function(d) {
			if (exist[d]) { toRemove[d] = 1; have++; }
		});
		if (!have) return;
		var removed = have;
		/* drop the preset's block header only if ALL its domains are being removed */
		var dropHdr = have === doms.length;
		var hdr = presetHeaderRe(name);
		var out = [];
		ta.value.split('\n').forEach(function(l) {
			var t = l.trim().replace(/^\*+\./, '').replace(/\.$/, '');
			if (t.charAt(0) !== '#' && toRemove[t]) { have--; return; }
			if (dropHdr && hdr.test(l.trim())) return;
			out.push(l);
		});
		while (out.length && out[out.length - 1].trim() === '') out.pop();
		ta.value = out.join('\n') + '\n';
		self.updateCounters();
		self.togglePresetBtn(btn, 'add', name, doms, ta.id, sidId);
		self.updatePresetStatus(sidId, name, 0, doms.length);
		self.msg('Удалено доменов: ' + removed + '. Нажмите «Сохранить и применить», чтобы вступить в силу.', 'success');
	},

	makePresetBtn: function(kind, name, doms, taId, sidId, count) {
		var self = this;
		return E('button', {
			'class': 'btn cbi-button ' + (kind === 'add' ? 'cbi-button-add' : 'cbi-button-remove'),
			'style': 'margin-left:8px; font-size:11px; padding:1px 8px',
			'type': 'button',
			'data-kind': kind,
			'data-name': name,
			'data-domains': JSON.stringify(doms),
			'data-target': taId,
			'data-sid': sidId,
			'click': ui.createHandlerFn(self, kind === 'add' ? 'handleAddPreset' : 'handleRemovePreset')
		}, [ kind === 'add' ? ('+ добавить ' + count) : ('\u2212 убрать ' + count) ]);
	},

	swapPresetBtn: function(oldBtn, kind, name, doms, taId, sidId) {
		var nb = this.makePresetBtn(kind, name, doms, taId, sidId, doms.length);
		oldBtn.parentNode.replaceChild(nb, oldBtn);
		return nb;
	},

	/* after add/remove: swap the button to the opposite action, or just drop it
	   when the opposite button is already there (otherwise users get duplicates) */
	togglePresetBtn: function(btn, kind, name, doms, taId, sidId) {
		var row = btn.parentNode;
		if (row && row.querySelector && row.querySelector('button[data-kind="' + kind + '"]')) {
			if (row.removeChild) row.removeChild(btn);
			return null;
		}
		return this.swapPresetBtn(btn, kind, name, doms, taId, sidId);
	},

	updatePresetStatus: function(sidId, name, have, total) {
		var sid = document.getElementById(sidId);
		if (!sid) return;
		sid.textContent = have === total
			? (name + ' ✓ в списке (' + have + '/' + total + ')')
			: (name + ' (' + have + '/' + total + ' в списке, добавится ' + (total - have) + ')');
	},

	updateCounters: function() {
		var self = this;
		[ [ 'wl-text', 'wl-count' ], [ 'bl-text', 'bl-count' ] ].forEach(function(pair) {
			var ta = document.getElementById(pair[0]);
			var cnt = document.getElementById(pair[1]);
			if (!ta || !cnt) return;
			var n = 0;
			ta.value.split('\n').forEach(function(l) {
				l = l.trim();
				if (l && l.charAt(0) !== '#') n++;
			});
			cnt.textContent = 'в списке сейчас: ' + n + ' доменов (окно прокручивается — весь список внутри)';
		});
	},

	/* ---------- devices ---------- */
	handleDevApply: function(ev) {
		var self = this;
		var direct = [], full = [], bypass = [];
		var sels = document.querySelectorAll('select[data-devip]');
		sels.forEach(function(s) {
			var ip = s.getAttribute('data-devip');
			if (s.value === 'direct') direct.push(ip);
			else if (s.value === 'full') full.push(ip);
			else bypass.push(ip);
		});
		self.msg('применяю режимы устройств (tun-policy + конфиг, до 20 с)...');
		return fs.exec(HELPER, [ 'setdevs', direct.join(','), full.join(','), bypass.join(',') ]).then(function(res) {
			self.msg((res.stdout || '').trim() || 'применено', 'success');
			return self.refreshTech();
		});
	},

	/* ---------- tech section ---------- */

	handleApply: function(ev) {
		var self = this;
		self.msg('применяю tun-policy...');
		return fs.exec(HELPER, [ 'applypolicy' ]).then(function(res) {
			self.msg((res.stdout || '').trim(), 'success');
			return self.refreshTech();
		});
	},

	handleRestart: function(ev) {
		var self = this;
		self.msg('перезапуск sing-box (до 15 с)...');
		return fs.exec(HELPER, [ 'restartsb' ]).then(function(res) {
			self.msg((res.stdout || '').trim(), 'success');
			return self.refreshTech();
		});
	},

	handleTest: function(ev) {
		var self = this;
		self.msg('тест маршрутизации (до 30 с)...');
		return fs.exec(HELPER, [ 'routetest' ]).then(function(res) {
			self.msg((res.stdout || '').trim(), 'success');
		});
	},

	refreshTech: function() {
		return fs.exec(HELPER, [ 'routing' ]).then(function(res) {
			var pre = document.getElementById('route-pre');
			if (pre) dom.content(pre, document.createTextNode(res.stdout || ''));
		});
	},

	/* ---------- render ---------- */

	render: function(data) {
		var self = this;
		var whiteText = (data[0] && parseJSON(data[0].stdout || '') || {}).bypass || '';
		var blackText = (data[1] && parseJSON(data[1].stdout || '') || {}).bypass || '';
		var devTxt = (data[2] && data[2].stdout) || '';
		var presetTxt = (data[3] && data[3].stdout) || '';
		var techTxt = (data[4] && data[4].stdout) || 'нет данных от helper';

		/* parse presets */
		var pWhite = [], pBlack = [], scope = '';
		presetTxt.split('\n').forEach(function(l) {
			l = l.trim();
			if (l === '#white') { scope = 'white'; return; }
			if (l === '#black') { scope = 'black'; return; }
			if (l === 'PRESETS_END' || !l) return;
			var target = scope === 'white' ? pWhite : pBlack;
			if (l.charAt(0) === '#') target.push({ name: l.slice(1).trim(), domains: [] });
			else if (target.length) target[target.length - 1].domains.push(l);
		});

		/* parse devices */
		var leases = [], direct = {}, full = {}, proxy = {}, sec = '';
		devTxt.split('\n').forEach(function(l) {
			l = l.trim();
			if (l === '#lease') { sec = 'lease'; return; }
			if (l === '#direct') { sec = 'direct'; return; }
			if (l === '#full') { sec = 'full'; return; }
			if (l === '#proxy') { sec = 'proxy'; return; }
			if (l === 'DEVLIST_END' || !l) return;
			if (sec === 'lease') {
				var sp = l.indexOf(' ');
				if (sp > 0) leases.push({ ip: l.slice(0, sp), name: l.slice(sp + 1) });
			} else if (sec === 'direct') direct[l] = 1;
			else if (sec === 'full') full[l] = 1;
			else if (sec === 'proxy') proxy[l] = 1;
		});
		/* static entries from lists that have no lease */
		Object.keys(direct).concat(Object.keys(full)).concat(Object.keys(proxy)).forEach(function(ip) {
			var known = leases.some(function(d) { return d.ip === ip; });
			if (!known) leases.push({ ip: ip, name: '(статично)' });
		});

		/* preset rows — status "have/total" per preset + per-preset add button.
		   Zones/domains entered manually (ru, su, ...) are NOT part of presets. */
		var presetRow = function(list, taId, text) {
			var exist = {};
			text.split('\n').forEach(function(l) {
				l = l.trim();
				if (l && l.charAt(0) !== '#') exist[l.replace(/^\*+\./, '').replace(/\.$/, '')] = 1;
			});
			var box = E('div', { 'style': 'border:1px dashed #bbb; border-radius:4px; padding:8px; margin:6px 0; background:#fafafa' }, [
				E('div', { 'style': 'font-size:12px; font-weight:bold; margin-bottom:4px' }, [
					'Готовые наборы — доля доменов, уже имеющихся в списке выше. Свои домены (зоны ru и т.п.) к наборам не относятся. Кнопка добавляет только недостающие:'
				])
			]);
			list.forEach(function(p, i) {
				var have = 0;
				p.domains.forEach(function(d) { if (exist[d]) have++; });
				var missing = p.domains.length - have;
				var status = missing === 0
					? (p.name + ' ✓ в списке (' + have + '/' + p.domains.length + ')')
					: (p.name + ' (' + have + '/' + p.domains.length + ' в списке, добавится ' + missing + ')');
				var sidId = 'pst-' + taId + '-' + i;
				var row = E('div', { 'style': 'display:flex; align-items:center; margin:3px 0; font-size:12px' }, [
					E('span', { 'id': sidId }, [ status ])
				]);
				if (missing > 0)
					row.appendChild(self.makePresetBtn('add', p.name, p.domains, taId, sidId, missing));
				if (have > 0)
					row.appendChild(self.makePresetBtn('remove', p.name, p.domains, taId, sidId, have));
				box.appendChild(row);
			});
			return box;
		};

		/* device table */
		var devTable = E('table', { 'class': 'table', 'style': 'max-width:640px' }, [
			E('tr', {}, [
				E('th', {}, [ 'Устройство' ]),
				E('th', {}, [ 'IP' ]),
				E('th', { 'style': 'width:220px' }, [ 'Как ходит трафик' ])
			])
		]);
		leases.sort(function(a, b) { return a.ip > b.ip ? 1 : -1; });
		leases.forEach(function(d) {
			var mode = direct[d.ip] ? 'direct' : (full[d.ip] ? 'full' : 'bypass');
			devTable.appendChild(E('tr', {}, [
				E('td', {}, [ d.name ]),
				E('td', {}, [ d.ip ]),
				E('td', {}, [
					E('select', { 'data-devip': d.ip, 'class': 'cbi-input-select', 'style': 'width:100%' }, [
						E('option', { 'value': 'bypass', 'selected': mode === 'bypass' ? 'selected' : null }, [ 'обход (только ресурсы)' ]),
						E('option', { 'value': 'full', 'selected': mode === 'full' ? 'selected' : null }, [ 'полный (всё через VPN)' ]),
						E('option', { 'value': 'direct', 'selected': mode === 'direct' ? 'selected' : null }, [ 'сквозной (всё напрямую, мимо VPN)' ])
					])
				])
			]));
		});
		if (!leases.length)
			devTable.appendChild(E('tr', {}, [ E('td', { 'colspan': 3 }, [ 'нет устройств в DHCP-leases' ]) ]));

		var body = E('div', {}, [
			E('h3', {}, [ 'Маршрутизация: режимы трафика' ]),
			E('p', { 'style': 'font-size:12px' }, [
				'По умолчанию весь трафик локальной сети идёт через Opera VPN. ',
				'Белый список направляет указанные ресурсы напрямую (быстрее, без VPN), ',
				'чёрный список принуждает указанные ресурсы всегда идти через прокси, ',
				'даже если они попали в белый список. Для отдельного устройства можно выбрать режим целиком.'
			]),

			/* white list */
			E('h3', {}, [ 'Белый список — идёт напрямую (мимо VPN)' ]),
			E('p', { 'style': 'font-size:12px' }, [
				'Один домен на строку; домен закрывает все поддомены. Целую зону можно писать как ', E('code', {}, [ 'ru' ]), '. Строки с # — комментарии.'
			]),
			E('textarea', { 'id': 'wl-text', 'rows': 12, 'style': 'width:100%; font-family:monospace; font-size:12px' }, [ whiteText ]),
			E('div', { 'id': 'wl-count', 'style': 'font-size:11px; color:#888; margin:2px 0' }, [ '' ]),
			presetRow(pWhite, 'wl-text', whiteText),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'handleSaveWhite') }, [ 'Сохранить и применить' ])
			]),

			/* black list */
			E('h3', {}, [ 'Чёрный список — всегда через прокси' ]),
			E('p', { 'style': 'font-size:12px' }, [
				'Эти ресурсы идут через Opera VPN, даже если их зона есть в белом списке. ',
				'Полезно, когда большой прямой домен тянет заблокированный или замедленный ресурс: он не будет ходить напрямую. ',
				'Внимание: для устройств в режиме «напрямую» чёрный список не действует — их трафик вообще не проходит через роутер-фильтр.'
			]),
			E('textarea', { 'id': 'bl-text', 'rows': 8, 'style': 'width:100%; font-family:monospace; font-size:12px' }, [ blackText ]),
			E('div', { 'id': 'bl-count', 'style': 'font-size:11px; color:#888; margin:2px 0' }, [ '' ]),
			presetRow(pBlack, 'bl-text', blackText),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'handleSaveBlack') }, [ 'Сохранить и применить' ])
			]),

			/* devices */
			E('h3', {}, [ 'Устройства: режим трафика' ]),
			E('p', { 'style': 'font-size:12px' }, [
				'Для каждого устройства из DHCP выбирается режим: ',
				E('b', {}, [ 'Обход (только ресурсы)' ]), ' — трафик идёт через VPN, но ресурсы из белого списка — напрямую, из чёрного — всегда через прокси (как настроено выше); ',
				E('b', {}, [ 'Полный' ]), ' — весь трафик через VPN, оба списка игнорируются; ',
				E('b', {}, [ 'Сквозной' ]), ' — устройство полностью мимо VPN (без фильтрации, обхода замедлений и списков).'
			]),
			devTable,
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleDevApply') }, [ 'Применить режимы устройств' ])
			]),

			/* tech */
			E('details', {}, [
				E('summary', { 'style': 'font-size:13px; cursor:pointer; margin:10px 0' }, [ 'Техническое состояние маршрутизации' ]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleApply') }, [ 'Применить tun-policy' ]),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(self, 'handleRestart') }, [ 'Рестарт sing-box' ]),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'handleTest') }, [ 'Тест маршрутизации' ])
				]),
				E('pre', { 'id': 'route-pre', 'style': 'font-size:12px; white-space:pre-wrap; background:#f8f8f8; padding:8px; border:1px solid #ddd; border-radius:4px' }, [ techTxt ])
			]),

			E('div', { 'id': 'route-msg', 'class': 'alert-message', 'style': 'display:none' }, [ '' ])
		]);

		/* live domain counters under each textarea (count non-comment lines) */
		var bindCounter = function(taId) {
			var ta = body.querySelector('#' + taId);
			if (ta) ta.addEventListener('input', function() { self.updateCounters(); });
		};
		bindCounter('wl-text');
		bindCounter('bl-text');
		requestAnimationFrame(function() { self.updateCounters(); });

		poll.add(L.bind(self.refreshTech, self), 30);
		return body;
	},

	/* these views have no CBI map: drop LuCI's useless Save/Reset footer */
	addFooter: function() { return E([]); },

	handleSaveApply: null
});
