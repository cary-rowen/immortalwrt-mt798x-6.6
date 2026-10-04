#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BASE_CONFIG="$ROOT_DIR/defconfig/mt7981-ax3000.config"
PROFILE_CONFIG="$ROOT_DIR/configs/nx30pro-nmbm.config"
SING_BOX_PATCH="$ROOT_DIR/patches/passwall_packages/0001-sing-box-go-1.23-compat.patch"
PASSWALL_LUCI_PATCH="$ROOT_DIR/patches/passwall_luci/0001-remove-unused-runtime-defaults.patch"

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

if [ ! -f "$PASSWALL_LUCI_PATCH" ]; then
	echo "missing PassWall LuCI patch: $PASSWALL_LUCI_PATCH" >&2
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

# Keep the default PassWall config aligned with the cores selected below.
# Accept an already-applied patch for local reruns, but fail on drift.
if git -C "$ROOT_DIR/feeds/passwall_luci" apply --check "$PASSWALL_LUCI_PATCH" >/dev/null 2>&1; then
	git -C "$ROOT_DIR/feeds/passwall_luci" apply "$PASSWALL_LUCI_PATCH"
elif git -C "$ROOT_DIR/feeds/passwall_luci" apply --reverse --check "$PASSWALL_LUCI_PATCH" >/dev/null 2>&1; then
	:
else
	echo "PassWall LuCI feed does not match the expected patch context" >&2
	exit 1
fi

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

FORBIDDEN_PACKAGES="
	luci-app-ttyd luci-i18n-ttyd-zh-cn ttyd \
	mwan3 luci-app-mwan3 \
	vlmcsd luci-app-vlmcsd \
	wrtbwmon luci-app-wrtbwmon \
	xray-core geoview xray-plugin unzip \
	v2ray-geoip v2ray-geosite \
	kmod-fs-btrfs block-mount blockdev automount blkid fdisk usbutils \
	kmod-usb2 kmod-usb3 kmod-usb-net-rndis
"

FORBIDDEN_OPTIONS="
	CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray \
	CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview \
	CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata
"

# Target and feed defaults can re-enable optional storage packages during
# defconfig. Reapply the explicit policy to the final configuration before
# validating and building it.
for package in $FORBIDDEN_PACKAGES
do
	set_config "CONFIG_PACKAGE_${package}" n
done

for option in $FORBIDDEN_OPTIONS
do
	set_config "$option" n
done

for package in $FORBIDDEN_PACKAGES
do
	if grep -Eq "^CONFIG_PACKAGE_${package}=[ym]$" .config; then
		echo "forbidden package selected after defconfig: $package" >&2
		exit 1
	fi
done

echo "Final target and PassWall configuration:"
grep -E '^(CONFIG_TARGET_PROFILE|CONFIG_TARGET_DEVICE_mediatek|CONFIG_PACKAGE_(luci-app-passwall|sing-box|xray-core|geoview|xray-plugin|v2ray-geoip|v2ray-geosite|dnsmasq-full))' .config || true

grep -q '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_h3c_magic-nx30-pro-nmbm=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y$' .config
grep -q '^# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray is not set$' .config
grep -q '^# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Geoview is not set$' .config
grep -q '^# CONFIG_PACKAGE_xray-core is not set$' .config
grep -q '^# CONFIG_PACKAGE_geoview is not set$' .config
grep -q '^# CONFIG_PACKAGE_xray-plugin is not set$' .config
grep -q '^# CONFIG_PACKAGE_unzip is not set$' .config
grep -q '^# CONFIG_PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata is not set$' .config
grep -q '^# CONFIG_PACKAGE_v2ray-geoip is not set$' .config
grep -q '^# CONFIG_PACKAGE_v2ray-geosite is not set$' .config
grep -q '^CONFIG_PACKAGE_sing-box=y$' .config
grep -q '^CONFIG_PACKAGE_dnsmasq-full=y$' .config

echo "NX30PRO NMBM configuration prepared"
