# Portal VPN for OpenWrt

Транспарентный VPN для клиентов LAN через прокси Opera: устройства ничего не
настраивают, весь их трафик уходит в `portal-tun` и дальше через `opera-proxy`
на выбранный релей. Белые списки (RU-банки, госуслуги) идут напрямую,
чёрные (Google/YouTube) — всегда через прокси, отдельные устройства можно
вывести из туннеля целиком.

```
клиент  ──► br-lan ──► ip rule iif br-lan table 100
                              │
                              ▼
                     default dev portal-tun  (172.19.0.1/30)
                              │
                        sing-box (tun, gvisor)
                         ├── domain_suffix из filter-domains.txt ──► direct-out
                         └── всё остальное ──► http 127.0.0.1:18080
                                                    │
                                              opera-proxy ──► релей ──► интернет
```

DNS клиентов идёт в dnsmasq роутера, а запросы к `8.8.8.8` принудительно
заворачиваются в таблицу 100 — то есть тоже через туннель (DoH внутри
sing-box). Трафик самого роутера (SSH, LuCI, обновления) остаётся в main.

## Возможности

- **Три вкладки LuCI**: «Статус» (движок, exit IP, пинги, график трафика,
  устройства), «Маршрутизация» (белый/чёрный списки, наборы доменов,
  режимы для устройств), «Настройки» (релей, страна, логи движка и sing-box).
- **Watchdog** (cron `*/5`): проверяет туннель через прокси, при деградации
  скорости выбирает релей по bandwidth, при обрыве обновляет пул релеев,
  перебирает живые, перезапускает движок и переприменяет политику маршрутизации.
- **Ручная пауза**: кнопка «Остановить» снимает правила и гасит sing-box, чтобы
  LAN не осталась в мёртвом туннеле; watchdog при этом не поднимает движок.
- **Автозапуск** переключает сразу четыре сервиса (`portal`, `portalstats`,
  `portaltun`, `sing-box`).
- **Учёт трафика** по устройствам (nft-счётчики) и график скорости.

## Требования

- OpenWrt **24.10** (opkg, `.ipk`) или **25.12** (apk, `.apk`).
- Готовые сборки — под `mediatek/filogic` (`aarch64_cortex-a53`), проверено на
  AX3000T-классе (256 МБ RAM). Для другой платформы соберите пакет сами (см. ниже).
- Зависимости: `sing-box-tiny`, `curl`, `ca-bundle`, `kmod-tun`, `luci-base`.
- Свободной RAM: ~110 МБ (opera-proxy + sing-box + LuCI).

## Установка

Скачайте файл из [Releases](../../releases) под свою версию OpenWrt и
скопируйте на роутер:

```sh
# OpenWrt 24.10 (.ipk)
scp luci-app-portal_0.1.0-1_aarch64_cortex-a53.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'opkg install /tmp/luci-app-portal_*.ipk'

# OpenWrt 25.12 (.apk)
scp luci-app-portal-0.1.0-r1.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 'apk add --allow-untrusted /tmp/luci-app-portal-*.apk'
```

Пакет не подписан: на 25.12 нужен `--allow-untrusted`, на 24.10 при
включённой проверке подписи — `opkg install --force-signature ...` либо
добавьте `option check_signature 0` на время установки.

Затем откройте **LuCI → Services → Portal VPN → Статус** и нажмите
**«Запустить»**. Автозапуск включается кнопкой в той же вкладке (по умолчанию
сервисы уже добавлены в `/etc/rc.d`, но движок стартует только после
«Запустить» или перезагрузки).

### Обновление

Файлы из `conffiles` (списки фильтров, `relay.conf`, `country.conf`,
`dev-*.txt`, `net.conf`) при обновлении **не перезаписываются**.

- **24.10 (opkg)** спросит, что делать с изменённым конфигом; при
  неинтерактивной установке сохранит ваш вариант и положит новый рядом как
  `*.opkg-new`.
- **25.12 (apk 3.x)** всегда сохраняет ваш файл, а версию из пакета кладёт
  рядом с суффиксом `*.apk-new` (например, `poolboot.sh.apk-new`,
  `relay.conf.apk-new`). Это нормально: посмотреть различия и принять новое
  значение можно вручную:

```sh
diff /etc/portal/relay.conf /etc/portal/relay.conf.apk-new
mv /etc/portal/relay.conf.apk-new /etc/portal/relay.conf   # принять новое
rm /etc/portal/*.apk-new                                   # или оставить своё
```

Скрипты без conffile-статуса (`portal-env.sh`, `tun-policy.sh`,
`portal-watch.sh`, `portal-luci.sh`) обновляются всегда.

### Что делает postinst

- включает `sing-box` в UCI (`/etc/sing-box/config.json`);
- переводит dnsmasq на `noresolv=1`, `server=8.8.8.8`, `filter_aaaa=1`
  (иначе DNS утекает к провайдеру мимо туннеля);
- добавляет cron: `*/5` — watchdog, `* * * * *` — учёт трафика;
- генерирует первый `/etc/sing-box/config.json` из списков;
- `enable` для `portal`, `portalstats`, `portaltun`, `sing-box`.

### Удаление

```sh
opkg remove luci-app-portal     # 24.10
apk del luci-app-portal         # 25.12
```

`prerm` снимает правила (`tun-policy.sh down`), чистит cron и останавливает
сервисы. Настройки dnsmasq и `sing-box` не откатываются — верните их вручную,
если роутер использовал другой DNS.

## Настройка

Все настройки — файлы в `/etc/portal` (UCI-конфига нет):

| Файл | Назначение |
|---|---|
| `relay.conf` | релей Opera (`http://IP:PORT`), одна строка |
| `country.conf` | код страны выхода: `AM` (Америка) / `EU` (Европа) |
| `filter-domains.txt` | белый список: домены и их поддомены идут **напрямую** |
| `filter-black.txt` | чёрный список: всегда **через прокси** (приоритет выше белого) |
| `filter-ips.txt` | IP-подсети напрямую (анти-ECH для Яндекса/VK/Mail.ru) |
| `dev-full.txt` | IP устройств: весь трафик через VPN |
| `dev-proxy.txt` | IP устройств: только чёрный список через VPN |
| `dev-direct.txt` | IP устройств: всегда напрямую |
| `presets-white.txt`, `presets-black.txt` | готовые наборы для вкладки «Маршрутизация» |
| `relay-seeds.txt` | стартовый список релеев для поиска |
| `config-template.json` | шаблон `/etc/sing-box/config.json` |
| `net.conf` | переопределение автоопределения сети (по умолчанию всё закомментировано) |

LAN/WAN определяются автоматически (`/etc/portal/portal-env.sh`): устройство LAN
из UCI `network.lan.device` (fallback — первый бридж с IPv4), его сеть и IPv6-
префиксы из ядра, WAN и шлюз — из default-маршрута main, DNS провайдера — из
`/tmp/resolv.conf.d/resolv.conf.auto`. Если схема нестандартная, задайте
`LAN_IF`, `LAN_NET`, `WAN_IF`, `WAN_GW`, `WAN_DNS` в `net.conf`.
Проверить, что определилось: `/etc/portal/portal-env.sh show`.

`relay.conf`, `country.conf`, списки и `dev-*.txt` объявлены как `conffiles` —
при обновлении пакета ваши правки сохраняются.

После правки списков нажмите «Сохранить и применить» в LuCI (это запускает
`filter-gen.sh`, проверку `sing-box check` и перезапуск sing-box с
переприменением политики) либо выполните вручную:

```sh
/etc/portal/filter-gen.sh && /etc/init.d/sing-box restart && /etc/portal/tun-policy.sh
```

`/etc/sing-box/config.json` генерируется — не редактируйте его вручную, правьте
`config-template.json` и списки.

## CLI

```sh
/etc/portal/portal-luci.sh status|start|stop|restart|test|exitip|pings
/etc/portal/portal-luci.sh routing|statslive|fastgraph|devices
/etc/portal/tun-policy.sh            # применить политику
/etc/portal/tun-policy.sh down       # снять политику (LAN напрямую)
/etc/portal/filter-gen.sh            # пересобрать конфиг sing-box
/etc/portal/portal-watch.sh          # прогнать watchdog вручную
logread -e portal-proxy ; logread -e portal-watch ; logread -e portal-tun
```

`portal-luci.sh` — единственный helper, разрешённый ACL LuCI
(`/usr/share/rpcd/acl.d/luci-app-portal.json`).

## Watchdog

`/etc/portal/portal-watch.sh` (cron `*/5`):

1. туннель жив → проверка скорости; если ответ дольше 12 с — `speedsel.sh`
   выбирает релей по bandwidth (не чаще раза в 30 минут);
2. туннель мёртв → до 3 попыток: `poolboot.sh` (свежий пул через DNS
   провайдера, работает при мёртвом туннеле) → `sweep.sh` (перебор живых
   релеев с bw-тестом) → перезапуск движка и проверка;
3. следит за цепочкой: `sing-box`, `portal-tun`, правила `iif br-lan`,
   `default dev portal-tun` в таблице 100, зона firewall.

Флаг `/etc/portal/engine-paused` (ставится кнопкой «Остановить») полностью
выключает watchdog — пока движок не запустят руками.

## Сборка

CI (`.github/workflows/build.yml`) собирает пакет в матрице:

| OpenWrt | формат | SDK |
|---|---|---|
| 24.10.4 | `.ipk` | `openwrt-sdk-24.10.4-mediatek-filogic_gcc-13.3.0_musl` |
| 25.12.5 | `.apk` | `openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl` |

Репозиторий — самодостаточный фид: в CI он копируется в
`$SDK_DIR/package/portal-vpn`, затем `make package/portal-vpn/compile`.
Артефакты и `SHA256SUMS` прикладываются к каждому запуску; по тегу `v*`
создаётся релиз.

Локально:

```sh
curl -LO https://downloads.openwrt.org/releases/24.10.4/targets/mediatek/filogic/openwrt-sdk-24.10.4-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar --zstd -xf openwrt-sdk-24.10.4-*.tar.zst
cp -r . openwrt-sdk-24.10.4-*/package/portal-vpn
cd openwrt-sdk-24.10.4-*/
make defconfig && make package/portal-vpn/compile V=s
ls bin/packages/*/base/luci-app-portal-*.ipk
```

`scripts/deploy.sh` копирует готовый пакет на роутер и ставит его:

```sh
./scripts/deploy.sh luci-app-portal_0.1.0-1_aarch64_cortex-a53.ipk root@192.168.1.1
```

## Ограничения и предостережения

- **Сеть определяется автоматически**, но `net.conf` пока не покрывает
  нестандартные схемы целиком: `tun-policy.sh` строит правила по LAN/WAN из
  `portal-env.sh`, а если LAN-адрес не определился (нет IPv4 на LAN), политика
  не применяется и пишет в лог `LAN interface not detected`.
- **Не запускайте вместе с другими VPN на table 100.** Например
  `cybportal` (xray/tproxy) пишет `local default dev lo table 100` и
  переводит dnsmasq на `127.0.0.1#5353` — правила и DNS конфликтуют.
- `filter-aaaa` + `noresolv` меняют DNS всего роутера: локальные имена
  (`.lan`) продолжают работать, но внешние резолверы провайдера отключаются.
- LuCI кеширует view по URL (`?v=<build>`), поэтому при ручной замене файлов
  во view нужен hard reload, а имена файлов в пакете стабильные
  (`control.js`, `routing.js`, `settings.js`) — после обновления пакета
  очищайте `/tmp/luci-indexcache*`.
- Пинг до релея часто заблокирован — доступность проверяйте только HTTP
  через прокси (кнопка «Проверить туннель»).
- `opera-proxy` — сторонний бинарник (7.6 МБ); пакет распространяет его как
  есть, без гарантий. `sing-box` берётся из официальных фидов OpenWrt.

## Лицензия

MIT — см. [LICENSE](LICENSE).
