#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BASE_CONFIG="$ROOT_DIR/defconfig/mt7981-ax3000.config"
PROFILE_CONFIG="$ROOT_DIR/configs/nx30pro-nmbm.config"
SING_BOX_PATCH="$ROOT_DIR/patches/passwall_packages/0001-sing-box-go-1.23-compat.patch"
XRAY_PATCH="$ROOT_DIR/patches/passwall_packages/0002-xray-go-1.23-compat.patch"

cd "$ROOT_DIR"

if [ ! -f "$BASE_CONFIG" ]; then
	echo "missing base config: $BASE_CONFIG" >&2
	exit 1
fi

if [ ! -f "$PROFILE_CONFIG" ]; then
	echo "missing profile config: $PROFILE_CONFIG" >&2
	exit 1
fi

if [ ! -f "$SING_BOX_PATCH" ]; then
	echo "missing sing-box compatibility patch: $SING_BOX_PATCH" >&2
	exit 1
fi

if [ ! -f "$XRAY_PATCH" ]; then
	echo "missing Xray compatibility patch: $XRAY_PATCH" >&2
	exit 1
fi

# ImmortalWrt 24.10 ships Go 1.23.x. The current PassWall feed moved
# sing-box to a Go 1.25.5-only release, so keep the compatible package pinned.
SING_BOX_MAKEFILE="$ROOT_DIR/feeds/passwall_packages/sing-box/Makefile"
if [ ! -f "$SING_BOX_MAKEFILE" ]; then
	echo "missing PassWall sing-box package: $SING_BOX_MAKEFILE" >&2
	exit 1
fi

case "$(sed -n 's/^PKG_VERSION:=//p' "$SING_BOX_MAKEFILE" | head -n 1)" in
	1.14.2)
		git -C "$ROOT_DIR/feeds/passwall_packages" apply "$SING_BOX_PATCH"
		;;
	1.12.23)
		;;
	*)
		echo "unexpected sing-box version in PassWall feed" >&2
		sed -n 's/^PKG_VERSION:=/found: /p' "$SING_BOX_MAKEFILE" >&2
		exit 1
		;;
esac

XRAY_MAKEFILE="$ROOT_DIR/feeds/passwall_packages/xray-core/Makefile"
if [ ! -f "$XRAY_MAKEFILE" ]; then
	echo "missing PassWall Xray package: $XRAY_MAKEFILE" >&2
	exit 1
fi

case "$(sed -n 's/^PKG_VERSION:=//p' "$XRAY_MAKEFILE" | head -n 1)" in
	26.9.30)
		git -C "$ROOT_DIR/feeds/passwall_packages" apply "$XRAY_PATCH"
		;;
	25.2.21)
		;;
	*)
		echo "unexpected Xray version in PassWall feed" >&2
		sed -n 's/^PKG_VERSION:=/found: /p' "$XRAY_MAKEFILE" >&2
		exit 1
		;;
esac

cp "$BASE_CONFIG" .config

# The upstream profile is multi-device. Replace its device selections with the
# exact NMBM profile so other MT7981 images cannot be selected accidentally.
sed -i \
	-e '/^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_/d' \
	-e '/^CONFIG_TARGET_PROFILE=/d' \
	-e '/^CONFIG_TARGET_DEVICE_PACKAGES_mediatek_filogic_DEVICE_/d' \
	.config

set_config() {
	key="$1"
	value="$2"
	sed -i \
		-e "/^${key}=.*/d" \
		-e "/^# ${key} is not set$/d" \
		.config
	if [ "$value" = "n" ]; then
		printf '# %s is not set\n' "$key" >> .config
	else
		printf '%s=%s\n' "$key" "$value" >> .config
	fi
}

# Apply the tracked profile fragment after the broad upstream defaults.
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		''|\#*) continue ;;
		CONFIG_*=*)
			key="${line%%=*}"
			value="${line#*=}"
			set_config "$key" "$value"
			;;
	esac
done < "$PROFILE_CONFIG"

# Apply disabled entries from the fragment as well.
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		'# CONFIG_'*' is not set')
			key="${line#\# }"
			key="${key% is not set}"
			set_config "$key" n
			;;
	esac
done < "$PROFILE_CONFIG"

make defconfig

for package in \
	luci-app-ttyd luci-i18n-ttyd-zh-cn ttyd \
	mwan3 luci-app-mwan3 \
	vlmcsd luci-app-vlmcsd \
	wrtbwmon luci-app-wrtbwmon \
	kmod-fs-btrfs block-mount blockdev automount blkid fdisk usbutils \
	kmod-usb2 kmod-usb3 kmod-usb-net-rndis
do
	if grep -Eq "^CONFIG_PACKAGE_${package}=[ym]$" .config; then
		echo "forbidden package selected after defconfig: $package" >&2
		exit 1
	fi
done

echo "Final target and PassWall configuration:"
grep -E '^(CONFIG_TARGET_PROFILE|CONFIG_TARGET_DEVICE_mediatek|CONFIG_PACKAGE_(luci-app-passwall|sing-box|xray-core|v2ray-geoip|v2ray-geosite))' .config || true

grep -q '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_h3c_magic-nx30-pro-nmbm=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y$' .config

echo "NX30PRO NMBM configuration prepared"
