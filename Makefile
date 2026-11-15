#
# Portal VPN for OpenWrt — transparent Opera VPN for LAN clients
#
# This file is part of the OpenWrt build system: drop the repository into
# package/portal-vpn (or add it as a feed) and run `make package/portal-vpn/compile`.
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-portal
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=jeysson89 <https://github.com/jeysson89>

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=Portal VPN — transparent Opera VPN for the LAN
  URL:=https://github.com/jeysson89/portal-vpn-openwrt
  DEPENDS:=+luci-base +sing-box-tiny +curl +ca-bundle +kmod-tun
endef

define Package/$(PKG_NAME)/description
  Transparent VPN for LAN clients through an Opera proxy and a sing-box TUN
  device. Hybrid routing: white list (direct), black list (always via proxy),
  per-device modes (bypass / full VPN / direct), LuCI tabs for status, routing
  and settings, plus a watchdog that recovers the tunnel automatically.
endef

define Package/$(PKG_NAME)/conffiles
/etc/portal/relay.conf
/etc/portal/country.conf
/etc/portal/filter-domains.txt
/etc/portal/filter-black.txt
/etc/portal/filter-ips.txt
/etc/portal/dev-full.txt
/etc/portal/dev-proxy.txt
/etc/portal/dev-direct.txt
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/portal $(1)/etc/init.d/portal
	$(INSTALL_BIN) ./files/etc/init.d/portalstats $(1)/etc/init.d/portalstats
	$(INSTALL_BIN) ./files/etc/init.d/portaltun $(1)/etc/init.d/portaltun

	$(INSTALL_DIR) $(1)/etc/portal
	$(INSTALL_BIN) ./files/etc/portal/portal-luci.sh $(1)/etc/portal/portal-luci.sh
	$(INSTALL_BIN) ./files/etc/portal/portal-watch.sh $(1)/etc/portal/portal-watch.sh
	$(INSTALL_BIN) ./files/etc/portal/tun-policy.sh $(1)/etc/portal/tun-policy.sh
	$(INSTALL_BIN) ./files/etc/portal/filter-gen.sh $(1)/etc/portal/filter-gen.sh
	$(INSTALL_BIN) ./files/etc/portal/speedsel.sh $(1)/etc/portal/speedsel.sh
	$(INSTALL_BIN) ./files/etc/portal/sweep.sh $(1)/etc/portal/sweep.sh
	$(INSTALL_BIN) ./files/etc/portal/poolboot.sh $(1)/etc/portal/poolboot.sh
	$(INSTALL_BIN) ./files/etc/portal/portal-stats.sh $(1)/etc/portal/portal-stats.sh
	$(INSTALL_BIN) ./files/etc/portal/fast-stats-loop.sh $(1)/etc/portal/fast-stats-loop.sh
	$(INSTALL_BIN) ./files/etc/portal/portaltun-start.sh $(1)/etc/portal/portaltun-start.sh
	$(INSTALL_BIN) ./files/etc/portal/opera-proxy $(1)/etc/portal/opera-proxy

	$(INSTALL_DATA) ./files/etc/portal/config-template.json $(1)/etc/portal/config-template.json
	$(INSTALL_DATA) ./files/etc/portal/filter-domains.txt $(1)/etc/portal/filter-domains.txt
	$(INSTALL_DATA) ./files/etc/portal/filter-black.txt $(1)/etc/portal/filter-black.txt
	$(INSTALL_DATA) ./files/etc/portal/filter-ips.txt $(1)/etc/portal/filter-ips.txt
	$(INSTALL_DATA) ./files/etc/portal/presets-white.txt $(1)/etc/portal/presets-white.txt
	$(INSTALL_DATA) ./files/etc/portal/presets-black.txt $(1)/etc/portal/presets-black.txt
	$(INSTALL_DATA) ./files/etc/portal/relay-seeds.txt $(1)/etc/portal/relay-seeds.txt
	$(INSTALL_DATA) ./files/etc/portal/relay.conf $(1)/etc/portal/relay.conf
	$(INSTALL_DATA) ./files/etc/portal/country.conf $(1)/etc/portal/country.conf
	$(INSTALL_DATA) ./files/etc/portal/dev-full.txt $(1)/etc/portal/dev-full.txt
	$(INSTALL_DATA) ./files/etc/portal/dev-proxy.txt $(1)/etc/portal/dev-proxy.txt
	$(INSTALL_DATA) ./files/etc/portal/dev-direct.txt $(1)/etc/portal/dev-direct.txt

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-portal.json \
		$(1)/usr/share/luci/menu.d/luci-app-portal.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-portal.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-portal.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/portal
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/portal/control.js \
		$(1)/www/luci-static/resources/view/portal/control.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/portal/routing.js \
		$(1)/www/luci-static/resources/view/portal/routing.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/portal/settings.js \
		$(1)/www/luci-static/resources/view/portal/settings.js
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -n "$${PKG_INSTALL_ROOT}" ] && exit 0

# --- sing-box: the upstream init script only starts when these options exist ---
if [ "$$(uci -q get sing-box.main.conffile)" != "/etc/sing-box/config.json" ]; then
	uci -q set sing-box.main=sing-box
	uci -q set sing-box.main.enabled='1'
	uci -q set sing-box.main.conffile='/etc/sing-box/config.json'
	uci -q set sing-box.main.workdir='/usr/share/sing-box'
	uci -q commit sing-box
fi

# --- DNS: dnsmasq must ask 8.8.8.8 (tun-policy forces it through the tunnel);
# ISP resolvers and AAAA would leak around the VPN ---
if [ "$$(uci -q get dhcp.@dnsmasq[0].noresolv)" != "1" ]; then
	uci -q set dhcp.@dnsmasq[0].noresolv='1'
	uci -q delete dhcp.@dnsmasq[0].server
	uci -q add_list dhcp.@dnsmasq[0].server='8.8.8.8'
	uci -q set dhcp.@dnsmasq[0].filter_aaaa='1'
	uci -q commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
fi

# --- leftovers of a manual (pre-package) install: numbered view files ---
rm -f /www/luci-static/resources/view/portal/control[0-9]*.js \
      /www/luci-static/resources/view/portal/settings[0-9]*.js \
      /www/luci-static/resources/view/portal/routing[0-9]*.js
rm -f /tmp/luci-indexcache*

# --- cron: watchdog every 5 min, per-device accounting every minute ---
mkdir -p /etc/crontabs
grep -q portal-watch.sh /etc/crontabs/root 2>/dev/null || \
	echo '*/5 * * * * /etc/portal/portal-watch.sh' >> /etc/crontabs/root
grep -q portal-stats.sh /etc/crontabs/root 2>/dev/null || \
	echo '* * * * * /etc/portal/portal-stats.sh' >> /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1

# --- generate the first sing-box config from the shipped lists ---
/etc/portal/filter-gen.sh >/dev/null 2>&1

# --- enable the chain (starts on boot; "Запустить" in LuCI starts it now) ---
for s in portal portalstats portaltun sing-box; do
	/etc/init.d/$$s enable >/dev/null 2>&1
done

exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -n "$${PKG_INSTALL_ROOT}" ] && exit 0

# the tunnel must not outlive the package: drop the policy and cron entries
[ -x /etc/portal/tun-policy.sh ] && /etc/portal/tun-policy.sh down >/dev/null 2>&1
sed -i '/portal-watch\.sh/d; /portal-stats\.sh/d' /etc/crontabs/root 2>/dev/null
/etc/init.d/cron restart >/dev/null 2>&1

for s in portal portalstats portaltun; do
	/etc/init.d/$$s stop >/dev/null 2>&1
	/etc/init.d/$$s disable >/dev/null 2>&1
done

exit 0
endef

$$(eval $$(call BuildPackage,$(PKG_NAME)))
