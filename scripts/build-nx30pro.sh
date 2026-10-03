#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
BASE_CONFIG="$ROOT_DIR/defconfig/mt7981-ax3000.config"
PROFILE_CONFIG="$ROOT_DIR/configs/nx30pro-nmbm.config"

cd "$ROOT_DIR"

if [ ! -f "$BASE_CONFIG" ]; then
	echo "missing base config: $BASE_CONFIG" >&2
	exit 1
fi

if [ ! -f "$PROFILE_CONFIG" ]; then
	echo "missing profile config: $PROFILE_CONFIG" >&2
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

echo "Final target and PassWall configuration:"
grep -E '^(CONFIG_TARGET_PROFILE|CONFIG_TARGET_DEVICE_mediatek|CONFIG_PACKAGE_(luci-app-passwall|sing-box|xray-core|v2ray-geoip|v2ray-geosite))' .config || true

grep -q '^CONFIG_TARGET_PROFILE="DEVICE_h3c_magic-nx30-pro-nmbm"$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_SingBox=y$' .config
grep -q '^CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y$' .config

echo "NX30PRO NMBM configuration prepared"
