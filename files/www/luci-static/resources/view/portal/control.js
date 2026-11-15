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

function fmtBytes(n) {
	n = Math.round(n);
	if (isNaN(n)) return '?';
	if (n > 1073741824) return (n / 1073741824).toFixed(2) + ' ГБ';
	if (n > 1048576) return (n / 1048576).toFixed(1) + ' МБ';
	if (n > 1024) return (n / 1024).toFixed(1) + ' КБ';
	return n + ' Б';
}

function fmtUptime(sec) {
	sec = parseInt(sec, 10) || 0;
	if (sec <= 0) return '';
	var d = Math.floor(sec / 86400),
	    h = Math.floor((sec % 86400) / 3600),
	    m = Math.floor((sec % 3600) / 60);
	if (d > 0) return d + 'д ' + h + 'ч';
	if (h > 0) return h + 'ч ' + m + 'м';
	return m + 'м';
}

var CARD = 'flex:1; min-width:180px; margin:4px; padding:10px 14px; border:1px solid rgba(128,128,128,0.35); border-radius:8px; background:rgba(128,128,128,0.08)';
var LABEL = 'font-size:11px; color:#888; text-transform:uppercase; letter-spacing:0.4px; margin-bottom:4px';
var BIG = 'font-size:17px; font-weight:bold; font-family:monospace; word-break:break-all';
var SUB = 'font-size:12px; color:#aaa; margin-top:2px';

/* rows of the ping table: [label, kind, json-key] */
var PING_ROWS = [
	[ 'Яндекс (ya.ru)', 'напрямую (RU)', 'ya' ],
	[ 'Mail.ru', 'напрямую (RU)', 'mail' ],
	[ 'Госуслуги', 'напрямую (RU)', 'gosuslugi' ],
	[ '1.1.1.1', 'интернет WAN', 'wan' ],
	[ 'Google (gstatic)', 'через туннель', 'tun_gstatic' ],
	[ 'YouTube', 'через туннель', 'tun_youtube' ]
];

/* second line of the "Движок" card — one builder for both render and live update */
function engineSub(st) {
	if (!st) return '';
	var s = [];
	if (st.running && st.uptime > 0) s.push('непрерывно: ' + fmtUptime(st.uptime));
	s.push('автозапуск: ' + (st.autostart ? 'вкл' : 'выкл'));
	if (st.paused) s.push('watchdog на паузе');
	return s.join(' \u00b7 ');
}

return view.extend({
	load: function() {
		return Promise.all([
			fs.exec(HELPER, [ 'status' ]),
			fs.exec(HELPER, [ 'fastgraph' ]),
			fs.exec(HELPER, [ 'statslive' ]),
			fs.exec(HELPER, [ 'exitip' ])
		]);
	},

	msg: function(text, cls) {
		var m = document.getElementById('portal-msg');
		if (!m) return;
		m.style.display = 'block';
		m.className = 'alert-message ' + (cls || '');
		dom.content(m, text);
	},

	setCell: function(id, val) {
		var el = document.getElementById(id);
		if (el) el.textContent = String(val);
	},

	/* an RPC rejection must be visible: otherwise the "..." message stays forever */
	fail: function(e) {
		this.msg('Ошибка: ' + (e && e.message ? e.message : e), 'danger');
	},

	/* ---------- status cards ---------- */

	updateStatus: function(st) {
		if (!st) return;
		var dot = document.getElementById('run-dot');
		if (dot) {
			dot.textContent = '\u25CF';
			dot.style.color = st.running ? '#2fae4f' : '#d9534f';
		}
		this.setCell('run-text', st.running ? ('работает, PID ' + st.pid) : 'ОСТАНОВЛЕН');
		this.setCell('run-up', engineSub(st));
		this.setCell('exit-country', st.country ? ('выход: ' + (st.country === 'AM' ? 'Америка' : 'Европа')) : '');
		this.setCell('relay-val', st.relay || '?');
		this.setCell('relay-country', 'страна туннеля: ' + (st.country || '?'));
		this.setCell('pool-val', st.pool + ' релеев');
		this.setCell('pool-sub', 'фильтр напрямую: ' + st.bypass_count + ' доменов');

		var sb = document.getElementById('btn-start');
		if (sb) sb.disabled = !!st.running;
		var tb = document.getElementById('btn-stop');
		if (tb) tb.disabled = !st.running;
		var ab = document.getElementById('btn-auto');
		if (ab) ab.textContent = 'Автозапуск: ' + (st.autostart ? 'вкл' : 'выкл');

		/* stop: do not show a stale exit IP from the previous session */
		if (!st.running) {
			this.setCell('exit-ip', '\u2014');
			this.setCell('speed-rx', '\u2014');
			this.setCell('speed-tx', '\u2014');
		}

		this._lastStatus = st;
	},

	pollStatus: function() {
		var self = this;
		return fs.exec(HELPER, [ 'status' ]).then(function(res) {
			var st = parseJSON(res.stdout || '');
			if (st) self.updateStatus(st);
		});
	},

	/* ---------- live traffic speed ---------- */

	refreshLive: function() {
		var self = this;
		return fs.exec(HELPER, [ 'statslive' ]).then(function(res) {
			var st = parseJSON(res.stdout || '{}');
			if (!st) return;
			var el = document.getElementById('stats-live');
			if (el) {
				if (!st.tun && self._lastStatus && !self._lastStatus.running)
					el.textContent = 'Движок остановлен — трафик через VPN не идёт, LAN ходит напрямую.';
				else {
					var tun = st.tun ? '' : ' (tun не поднят!)';
					el.textContent = 'Всего через туннель: \u2193 ' + fmtBytes(st.tot_rx) + ' / \u2191 ' + fmtBytes(st.tot_tx) + tun;
				}
			}
		});
	},

	/* ---------- graph ---------- */

	parseLines: function(out) {
		var rows = [];
		(out || '').split('\n').forEach(function(line) {
			var p = line.trim().split(/\s+/);
			if (p.length >= 4) {
				var t = parseInt(p[0], 10), dur = parseInt(p[1], 10),
				    drx = parseInt(p[2], 10), dtx = parseInt(p[3], 10);
				if (!isNaN(t) && dur > 0 && !isNaN(drx) && !isNaN(dtx))
					rows.push({ t: t, rx: drx / dur / 1024, tx: dtx / dur / 1024 });
			}
		});
		return rows;
	},

	draw: function(canvas, rows) {
		if (!canvas) return;
		var ctx = canvas.getContext('2d');
		var W = canvas.width, H = canvas.height;
		var now = new Date().getTime() / 1000;
		var span = 300; /* 5 minute window */
		rows = rows.filter(function(r) { return r.t >= now - span; });
		if (rows.length < 2) {
			ctx.clearRect(0, 0, W, H);
			ctx.fillStyle = '#888'; ctx.font = '11px sans-serif'; ctx.textAlign = 'center';
			ctx.fillText('набираю данные (5-секундные сэмплы)...', W / 2, H / 2);
			return;
		}
		var padL = 46, padR = 8, padT = 10, padB = 20;
		ctx.clearRect(0, 0, W, H);

		var pts = rows;
		var max = 1;
		pts.forEach(function(p) { if (p.rx > max) max = p.rx; if (p.tx > max) max = p.tx; });
		var niceMax = max * 1.15;

		ctx.strokeStyle = 'rgba(128,128,128,0.3)'; ctx.fillStyle = '#888'; ctx.font = '10px sans-serif'; ctx.lineWidth = 1;
		for (var i = 0; i <= 4; i++) {
			var y = padT + (H - padT - padB) * i / 4;
			ctx.beginPath(); ctx.moveTo(padL, y); ctx.lineTo(W - padR, y); ctx.stroke();
			ctx.textAlign = 'right';
			ctx.fillText((niceMax * (1 - i / 4)).toFixed(0) + ' KiB/s', padL - 4, y + 3);
		}

		/* fixed 5-min window ending at now — graph scrolls left */
		var x1 = now, x0 = now - span;
		var X = function(t) { return padL + (W - padL - padR) * (t - x0) / (x1 - x0); };
		var Y = function(v) { return H - padB - (H - padT - padB) * v / niceMax; };

		var line = function(key, color) {
			ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.beginPath();
			pts.forEach(function(p, i) {
				var x = X(p.t), y = Y(Math.min(p[key], niceMax));
				if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
			});
			ctx.stroke();
		};
		line('rx', '#2b7de9');
		line('tx', '#2fae4f');

		ctx.fillStyle = '#888'; ctx.textAlign = 'center';
		for (i = 0; i <= 5; i++) {
			var tt = x0 + span * i / 5;
			var d = new Date(tt * 1000);
			var hh = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ':' + ('0' + d.getSeconds()).slice(-2);
			var lx = X(tt);
			if (i === 0) { ctx.textAlign = 'left'; lx = X(tt) - 8; }
			if (i === 5) { ctx.textAlign = 'right'; lx = X(tt) + 8; }
			ctx.fillText(hh, lx, H - 6);
			ctx.textAlign = 'center';
		}

		ctx.textAlign = 'left'; ctx.font = '11px sans-serif';
		ctx.fillStyle = '#2b7de9'; ctx.fillText('\u25A0 приём (из туннеля)', padL + 60, padT + 9);
		ctx.fillStyle = '#2fae4f'; ctx.fillText('\u25A0 отдача (в туннель)', padL + 200, padT + 9);
	},

	refreshGraph: function() {
		var self = this;
		return fs.exec(HELPER, [ 'fastgraph' ]).then(function(res) {
			var rows = self.parseLines(res.stdout);
			self.draw(document.getElementById('stats-canvas'), rows);
			self.updateSpeed(rows);
		});
	},

	/* average of the last ~30 s (6 samples) — instant 5 s values are too jumpy */
	updateSpeed: function(rows) {
		if (!rows || !rows.length) return;
		if (this._lastStatus && !this._lastStatus.running) return;
		var n = Math.min(6, rows.length), srx = 0, stx = 0, i;
		for (i = rows.length - n; i < rows.length; i++) { srx += rows[i].rx; stx += rows[i].tx; }
		srx /= n; stx /= n;
		this.setCell('speed-rx', fmtBytes(srx * 1024) + '/с');
		this.setCell('speed-tx', fmtBytes(stx * 1024) + '/с');
	},

	/* ---------- devices ---------- */

	refreshDevices: function() {
		var self = this;
		return fs.exec(HELPER, [ 'devices' ]).then(function(res) {
			var tbl = document.getElementById('dev-table');
			if (!tbl) return;
			var rows = [];
			(res.stdout || '').split('\n').forEach(function(line) {
				var p = line.trim().split(/\s+/);
				if (p.length >= 4) rows.push(p);
			});
			rows.sort(function(a, b) { return (parseInt(b[2], 10) + parseInt(b[3], 10)) - (parseInt(a[2], 10) + parseInt(a[3], 10)); });
			var body = [ E('tr', {}, [
				E('th', {}, [ 'Устройство' ]),
				E('th', {}, [ 'IP' ]),
				E('th', {}, [ '\u2193 получено' ]),
				E('th', {}, [ '\u2191 отправлено' ])
			]) ];
			rows.forEach(function(r) {
				body.push(E('tr', {}, [
					E('td', {}, [ r[1] !== '-' ? r[1] : 'неизвестно' ]),
					E('td', {}, [ r[0] ]),
					E('td', {}, [ fmtBytes(parseInt(r[2], 10)) ]),
					E('td', {}, [ fmtBytes(parseInt(r[3], 10)) ])
				]));
			});
			if (!rows.length) body.push(E('tr', {}, [ E('td', { 'colspan': 4 }, [ 'нет данных (счётчики только что созданы)' ]) ]));
			while (tbl.firstChild) tbl.removeChild(tbl.firstChild);
			body.forEach(function(tr) { tbl.appendChild(tr); });
		});
	},

	/* ---------- pings ---------- */

	refreshPings: function() {
		var self = this;
		var upd = document.getElementById('ping-upd');
		if (upd) upd.textContent = 'измеряю...';
		return fs.exec(HELPER, [ 'pings' ]).then(function(res) {
			var p = parseJSON(res.stdout || '');
			if (!p) {
				if (upd) upd.textContent = 'ошибка измерения';
				return;
			}
			var tb = document.getElementById('ping-tbody');
			if (!tb) return;
			while (tb.firstChild) tb.removeChild(tb.firstChild);

			PING_ROWS.forEach(function(r) {
				var v = p[r[2]];
				var ms = v && v.ok ? (v.ms >= 1000 ? (v.ms / 1000).toFixed(1) + ' с' : Math.round(v.ms) + ' мс') : null;
				var cell = ms
					? E('td', { 'style': 'color:#2fae4f; font-weight:bold' }, [ '\u2713 ' + ms ])
					: E('td', { 'style': 'color:#d9534f; font-weight:bold' }, [ '\u2717 нет ответа' ]);
				tb.appendChild(E('tr', {}, [
					E('td', {}, [ r[0] ]),
					E('td', { 'style': 'color:#888' }, [ r[1] ]),
					cell
				]));
			});

			var eip = document.getElementById('exit-ip');
			if (eip) {
				// a failed probe must not wipe a good value, but "измеряю..." forever
				// looks like a hang: fall back to a dash after the first attempt
				if (p.exit_ip) eip.textContent = p.exit_ip;
				else if (/измеряю/.test(eip.textContent)) eip.textContent = '—';
			}

			if (upd) upd.textContent = 'измерено в ' + new Date().toLocaleTimeString();
		});
	},

	/* ---------- control buttons ---------- */

	handleTest: function(ev) {
		var self = this;
		self.msg('проверяю туннель (до 25 с)...');
		return fs.exec(HELPER, [ 'test' ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.exit_ip) {
				self.setCell('exit-ip', r.exit_ip);
				self.msg('Туннель работает. Выходной IP: ' + r.exit_ip, 'success');
			} else
				self.msg('Туннель НЕ работает. Нажмите «Watchdog» или «Перезапустить».', 'warning');
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
				self.msg('Движок не поднялся! Смотрите лог.', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	handleWatch: function(ev) {
		var self = this;
		self.msg('watchdog запущен: подберёт живой релей и перезапустит движок...');
		return fs.exec(HELPER, [ 'watch' ]).then(function() {
			self.msg('Watchdog работает в фоне (проверьте статус через минуту).');
		}).catch(L.bind(self.fail, self));
	},

	handleStart: function(ev) {
		var self = this;
		self.msg('запускаю движок...');
		return fs.exec(HELPER, [ 'start' ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.started)
				self.msg('Движок запущен, PID ' + r.pid + '. Авто-режим снова активен.', 'success');
			else
				self.msg('Движок не поднялся! Смотрите лог.', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	handleStop: function(ev) {
		var self = this;
		self.msg('останавливаю движок (watchdog будет на паузе)...');
		return fs.exec(HELPER, [ 'stop' ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && r.stopped)
				self.msg('Движок остановлен. Авто-восстановление на паузе, пока не нажмёте «Запустить».', 'warning');
			else
				self.msg('Не удалось остановить движок (PID ' + (r && r.pid) + ').', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	handleAuto: function(ev) {
		var self = this;
		var st = self._lastStatus || {};
		var want = st.autostart ? 'off' : 'on';
		return fs.exec(HELPER, [ 'setautostart', want ]).then(function(res) {
			var r = parseJSON(res.stdout || '');
			if (r && typeof r.enabled !== 'undefined')
				self.msg(want === 'on' ? 'Автозапуск включён: после перезагрузки роутера VPN поднимется сам.' : 'Автозапуск выключен: после перезагрузки VPN сам не стартует.', 'success');
			else
				self.msg('Не удалось изменить автозапуск.', 'danger');
			return self.pollStatus();
		}).catch(L.bind(self.fail, self));
	},

	/* ---------- render ---------- */

	render: function(data) {
		var self = this;
		var st = parseJSON((data[0] && data[0].stdout) || '');
		if (st) this._lastStatus = st;
		var ip0 = parseJSON((data[3] && data[3].stdout) || '') || {};

		var cards = E('div', { 'style': 'display:flex; flex-wrap:wrap; margin:4px -4px' }, [
			E('div', { 'style': CARD }, [
				E('div', { 'style': LABEL }, [ 'Движок' ]),
				E('div', { 'style': 'font-size:17px; font-weight:bold' }, [
					E('span', { 'id': 'run-dot', 'style': 'color:#2fae4f' }, [ '\u25CF' ]),
					' ',
					E('span', { 'id': 'run-text' }, [ st ? (st.running ? 'работает, PID ' + st.pid : 'ОСТАНОВЛЕН') : '?' ])
				]),
				E('div', { 'id': 'run-up', 'style': SUB }, [ engineSub(st) ])
			]),
			E('div', { 'style': CARD }, [
				E('div', { 'style': LABEL }, [ 'IP выхода (exit)' ]),
				E('div', { 'id': 'exit-ip', 'style': BIG }, [ ip0.exit_ip || 'измеряю...' ]),
				E('div', { 'id': 'exit-country', 'style': SUB }, [ st ? ('выход: ' + (st.country === 'AM' ? 'Америка' : 'Европа')) : '' ])
			]),
			E('div', { 'style': CARD }, [
				E('div', { 'style': LABEL }, [ 'Релей' ]),
				E('div', { 'id': 'relay-val', 'style': BIG + ';word-break:break-all' }, [ st ? st.relay : '...' ]),
				E('div', { 'id': 'relay-country', 'style': SUB }, [ st ? ('страна туннеля: ' + st.country) : '' ])
			]),
			E('div', { 'style': CARD }, [
				E('div', { 'style': LABEL }, [ 'Скорость (30 с)' ]),
				E('div', { 'style': 'font-size:17px; font-weight:bold' }, [
					'\u2193 ',
					E('span', { 'id': 'speed-rx' }, [ '—' ])
				]),
				E('div', { 'style': SUB }, [ '\u2191 ', E('span', { 'id': 'speed-tx' }, [ '—' ]) ])
			]),
			E('div', { 'style': CARD }, [
				E('div', { 'style': LABEL }, [ 'Пул и фильтр' ]),
				E('div', { 'id': 'pool-val', 'style': BIG }, [ st ? (st.pool + ' релеев') : '...' ]),
				E('div', { 'id': 'pool-sub', 'style': SUB }, [ st ? ('фильтр напрямую: ' + st.bypass_count + ' доменов') : '' ])
			])
		]);

		var pingTbl = E('table', { 'class': 'table', 'style': 'max-width:560px' }, [
			E('thead', {}, [ E('tr', {}, [ E('th', {}, [ 'Ресурс' ]), E('th', {}, [ 'Путь' ]), E('th', {}, [ 'Отклик' ]) ]) ]),
			E('tbody', { 'id': 'ping-tbody' }, [ E('tr', {}, [ E('td', { 'colspan': 3 }, [ 'измеряю...' ]) ]) ])
		]);

		var body = E('div', {}, [
			/* main engine controls — at the top, always visible */
			E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:8px; margin:0 0 12px' }, [
				E('button', { 'id': 'btn-start', 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'handleStart') }, [ 'Запустить' ]),
				' ',
				E('button', { 'id': 'btn-stop', 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(self, 'handleStop') }, [ 'Остановить' ]),
				' ',
				E('button', { 'id': 'btn-auto', 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.createHandlerFn(self, 'handleAuto') }, [ 'Автозапуск: ' + (st && st.autostart ? 'вкл' : 'выкл') ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(self, 'handleRestart') }, [ 'Перезапустить' ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-positive', 'click': ui.createHandlerFn(self, 'handleTest') }, [ 'Проверить туннель' ]),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(self, 'handleWatch') }, [ 'Watchdog' ])
			]),

			cards,

			E('h3', { 'style': 'margin-top:16px' }, [ 'Пинги и доступность ресурсов' ]),
			pingTbl,
			E('p', { 'style': 'font-size:11px; color:#888' }, [
				E('span', { 'id': 'ping-upd' }, [ '...' ]), ' — ',
				E('a', { 'href': '#', 'click': ui.createHandlerFn(self, 'refreshPings') }, [ 'измерить снова' ])
			]),

			E('h3', { 'style': 'margin-top:16px' }, [ 'Трафик через туннель (portal-tun)' ]),
			E('p', { 'id': 'stats-live', 'style': 'font-size:13px; font-weight:bold' }, [ '...' ]),
			E('canvas', { 'id': 'stats-canvas', 'width': '1100', 'height': '240',
				'style': 'max-width:100%; border:1px solid rgba(128,128,128,0.35); background:rgba(128,128,128,0.06); border-radius:4px' }, [ ]),

			E('h3', { 'style': 'margin-top:16px' }, [ 'Устройства' ]),
			E('table', { 'id': 'dev-table', 'class': 'table' }, [ ]),
			E('p', { 'style': 'font-size:11px; color:#888' },
				[ 'График и цифры скорости: счётчики portal-tun, сэмплы каждые 5 с, окно 5 минут (скатывается влево). Трафик устройств — с момента старта счётчиков (сбрасывается при перезагрузке).' ]),

			E('p', { 'style': 'font-size:12px; color:#666' }, [
				'Настройка релея, страны и логи движка — во вкладке «Настройки». ',
				'Фильтрация трафика (что идёт напрямую, мимо VPN) — во вкладке «Маршрутизация».'
			]),
			E('div', { 'id': 'portal-msg', 'class': 'alert-message', 'style': 'display:none' }, [ '' ])
		]);

		poll.add(L.bind(self.pollStatus, self), 10);
		poll.add(L.bind(self.refreshLive, self), 10);
		poll.add(L.bind(self.refreshGraph, self), 5);
		poll.add(L.bind(self.refreshDevices, self), 60);
		poll.add(L.bind(self.refreshPings, self), 120);

		requestAnimationFrame(function() {
			// buttons' disabled state depends on the status: apply it before the
			// first 10 s poll, otherwise "Запустить" looks clickable while running
			if (st) self.updateStatus(st);
			var initRows = self.parseLines((data[1] && data[1].stdout) || '');
			self.draw(document.getElementById('stats-canvas'), initRows);
			self.updateSpeed(initRows);
			self.refreshLive();
			self.refreshDevices();
			self.refreshPings();
		});

		return body;
	},

	/* these views have no CBI map: drop LuCI's useless Save/Reset footer */
	addFooter: function() { return E([]); },

	handleSaveApply: null
});
