#!/bin/sh
# Copy a built package to the router and install it.
#
#   ./scripts/deploy.sh luci-app-portal_0.1.1-r1_aarch64_cortex-a53.ipk [root@192.168.1.1]
#   ./scripts/deploy.sh luci-app-portal-0.1.1-r1.apk root@192.168.1.1
#
# The format is detected from the file extension (ipk -> opkg, apk -> apk add).
set -eu

pkg=${1:-}
target=${2:-root@192.168.1.1}

if [ -z "$pkg" ] || [ ! -f "$pkg" ]; then
	echo "usage: $0 <package.ipk|package.apk> [root@router]" >&2
	exit 1
fi

case "$pkg" in
	*.ipk) remote=/tmp/portal-install.ipk ;;
	*.apk) remote=/tmp/portal-install.apk ;;
	*) echo "unknown package format: $pkg" >&2; exit 1 ;;
esac

echo "==> copying $pkg to $target:$remote"
scp "$pkg" "$target:$remote"

echo "==> installing on $target"
case "$pkg" in
	*.ipk)
		ssh "$target" "opkg install --force-reinstall $remote || opkg install $remote"
		;;
	*.apk)
		ssh "$target" "apk add --allow-untrusted --force-overwrite $remote"
		;;
esac

echo "==> cleanup"
ssh "$target" "rm -f $remote"

echo "==> status"
ssh "$target" "/etc/portal/portal-luci.sh status || true"

echo
echo "Open LuCI -> Services -> Portal VPN and press \"Запустить\" (or run:"
echo "  ssh $target /etc/portal/portal-luci.sh start"
echo "and hard-reload the browser tab)."
