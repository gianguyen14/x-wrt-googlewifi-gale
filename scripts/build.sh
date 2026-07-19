#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/xwrt-gale-build"
SRC="${ROOT}/x-wrt"
JOBS="${JOBS:-2}"

# v1.1.0: Recovery fix + NATCAP + WireGuard + Tailscale
GALE_VERSION="1.1.0"

XWRT_COMMIT="5b7e1e72a7cf2b164fa8f8f87b3ad74d39b3007c"
PKG_COMMIT="91d208ea48170415a7207251a9897a298172b872"
LUCI_COMMIT="fdb3cd943258c4d57c0b8cfcac9c16cb4c33afa4"
ROUTING_COMMIT="8c2385009d29a6d4e3ecc8cc38e8c5c0d71c691f"
TELEPHONY_COMMIT="4d8d33a023b24c52cd9443b9dc201fbdfe9c6aef"
VIDEO_COMMIT="a951381b6c58b9b1eb087f09c9a20cff4ffe8063"
X_COMMIT="befbdccba1990dc24c4557ee1e431a92f8b21aec"

sudo apt-get update
sudo apt-get install -y \
  build-essential clang flex bison g++ gawk gcc-multilib gettext git \
  libncurses-dev libssl-dev libelf-dev python3 python3-setuptools \
  python3-pyelftools rsync swig unzip zlib1g-dev libzstd-dev \
  file wget curl time patch diffutils ca-certificates ccache

mkdir -p "${ROOT}"
rm -rf "${SRC}"

git clone https://github.com/x-wrt/x-wrt.git "${SRC}"
cd "${SRC}"
git checkout "${XWRT_COMMIT}"

./scripts/feeds update -a

git -C feeds/packages checkout "${PKG_COMMIT}"
git -C feeds/luci checkout "${LUCI_COMMIT}"
git -C feeds/routing checkout "${ROUTING_COMMIT}"
git -C feeds/telephony checkout "${TELEPHONY_COMMIT}"
git -C feeds/video checkout "${VIDEO_COMMIT}"
git -C feeds/x checkout "${X_COMMIT}"

./scripts/feeds install -a

# Google WiFi Gale recovery-loop fix:
# Never run X-WRT's generic ext4 repartition routine on this board.
PREINIT="${SRC}/feeds/x/base-config-setting/files/disk_ready.preinit"
if [[ ! -f "${PREINIT}" ]]; then
  echo "Không tìm thấy ${PREINIT}" >&2
  exit 1
fi

python3 - "${PREINIT}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

marker = '\tcase "$(board_name)" in\n'
guard = (
    '\t# Google WiFi Gale: partition 1 is the ChromeOS kernel.\n'
    '\t# Never run the generic X-WRT ext4 auto-partition routine on this board.\n'
    '\tcase "$(board_name)" in\n'
    '\tgoogle,wifi)\n'
    '\t\treturn\n'
    '\t\t;;\n'
)

if "Google WiFi Gale: partition 1 is the ChromeOS kernel." not in text:
    if marker not in text:
        raise SystemExit("Không tìm thấy vị trí cần vá trong disk_ready.preinit")
    text = text.replace(marker, guard, 1)
    path.write_text(text, encoding="utf-8")
PY

cat > .config <<EOF
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_chromium=y
CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y

CONFIG_CCACHE=y
CONFIG_BUILD_LOG=y

CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="X-WRT Gale"
CONFIG_VERSION_NUMBER="${GALE_VERSION}"
CONFIG_VERSION_PRODUCT="Google WiFi Gale"
CONFIG_VERSION_MANUFACTURER="gianguyen14"
CONFIG_VERSION_HOME_URL="https://github.com/gianguyen14/x-wrt-googlewifi-gale"
CONFIG_VERSION_SUPPORT_URL="https://github.com/gianguyen14/x-wrt-googlewifi-gale/issues"

# LuCI
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl-openssl=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-mod-dashboard=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-wizard=y

# X-WRT base
CONFIG_PACKAGE_base-config-setting=y
# CONFIG_PACKAGE_base-config-setting-ext4fs is not set
CONFIG_PACKAGE_luci-app-xwan=y
CONFIG_PACKAGE_luci-app-macvlan=y
CONFIG_PACKAGE_kmod-macvlan=y
CONFIG_PACKAGE_kmod-ipvlan=y

# NATCAP / One-click VPN
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_VCONFIG=y
CONFIG_BUSYBOX_CONFIG_CKSUM=y
CONFIG_BUSYBOX_CONFIG_BASE64=y
CONFIG_BUSYBOX_CONFIG_TIMEOUT=y
CONFIG_BUSYBOX_CONFIG_NOHUP=y
CONFIG_BUSYBOX_CONFIG_DIFF=y
CONFIG_PACKAGE_kmod-natcap=y
CONFIG_PACKAGE_natcapd=y
CONFIG_PACKAGE_luci-app-natcap=y
CONFIG_PACKAGE_openvpn-openssl=y
CONFIG_PACKAGE_luci-app-openvpn=y

# WireGuard
CONFIG_PACKAGE_luci-proto-wireguard=y
CONFIG_PACKAGE_wireguard-tools=y

# Tailscale
CONFIG_PACKAGE_tailscale=y
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_ca-bundle=y

# Wi-Fi
# CONFIG_PACKAGE_wpad-basic-mbedtls is not set
CONFIG_PACKAGE_wpad-mbedtls=y
CONFIG_PACKAGE_hostapd-utils=y
CONFIG_PACKAGE_iw=y
CONFIG_PACKAGE_iwinfo=y
CONFIG_PACKAGE_dawn=y
CONFIG_PACKAGE_luci-app-dawn=y
CONFIG_PACKAGE_usteer=y
CONFIG_PACKAGE_luci-app-usteer=y

# Network services
CONFIG_PACKAGE_luci-app-sqm=y
CONFIG_PACKAGE_sqm-scripts=y
CONFIG_PACKAGE_luci-app-ddns=y
CONFIG_PACKAGE_ddns-scripts-services=y
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_miniupnpd-nftables=y
CONFIG_PACKAGE_luci-app-adblock=y
CONFIG_PACKAGE_adblock=y
CONFIG_PACKAGE_luci-app-nlbwmon=y
CONFIG_PACKAGE_nlbwmon=y

# Storage
CONFIG_PACKAGE_block-mount=y
CONFIG_PACKAGE_kmod-fs-ext4=y
CONFIG_PACKAGE_kmod-fs-f2fs=y
CONFIG_PACKAGE_kmod-fs-vfat=y
CONFIG_PACKAGE_kmod-usb-storage=y
CONFIG_PACKAGE_kmod-usb-storage-uas=y
CONFIG_PACKAGE_luci-app-samba4=y
CONFIG_PACKAGE_samba4-server=y
CONFIG_PACKAGE_wsdd2=y

# Utilities
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_ttyd=y
CONFIG_PACKAGE_luci-app-wol=y
CONFIG_PACKAGE_etherwake=y
CONFIG_PACKAGE_irqbalance=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_jsonfilter=y
CONFIG_PACKAGE_fdisk=y
CONFIG_PACKAGE_gdisk=y
CONFIG_PACKAGE_sgdisk=y
CONFIG_PACKAGE_partx-utils=y
CONFIG_PACKAGE_e2fsprogs=y
CONFIG_PACKAGE_resize2fs=y
CONFIG_PACKAGE_blkid=y
CONFIG_PACKAGE_blockdev=y
CONFIG_PACKAGE_lsblk=y
EOF

make defconfig

required_configs=(
  "CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y"
  "CONFIG_PACKAGE_kmod-natcap=y"
  "CONFIG_PACKAGE_natcapd=y"
  "CONFIG_PACKAGE_luci-app-natcap=y"
  "CONFIG_PACKAGE_openvpn-openssl=y"
  "CONFIG_PACKAGE_luci-proto-wireguard=y"
  "CONFIG_PACKAGE_wireguard-tools=y"
  "CONFIG_PACKAGE_tailscale=y"
  "CONFIG_PACKAGE_kmod-tun=y"
)

for cfg in "${required_configs[@]}"; do
  if ! grep -qxF "${cfg}" .config; then
    echo "LỖI: thiếu cấu hình sau make defconfig: ${cfg}" >&2
    exit 1
  fi
done

if grep -q '^CONFIG_PACKAGE_base-config-setting-ext4fs=y' .config; then
  echo "LỖI: base-config-setting-ext4fs bị bật lại." >&2
  exit 1
fi

make download -j"${JOBS}"
make -j"${JOBS}" V=s 2>&1 | tee build-gale.log

OUT="${SRC}/bin/targets/ipq40xx/chromium"
MANIFEST="$(find "${OUT}" -maxdepth 1 -name '*.manifest' | head -n1 || true)"

[[ -n "${MANIFEST}" ]] || {
  echo "LỖI: không tìm thấy manifest firmware." >&2
  exit 1
}

required_packages=(
  "kmod-natcap"
  "natcapd"
  "luci-app-natcap"
  "openvpn-openssl"
  "wireguard-tools"
  "tailscale"
  "kmod-tun"
)

for pkg in "${required_packages[@]}"; do
  grep -qE "^${pkg}( |$)" "${MANIFEST}" || {
    echo "LỖI: manifest thiếu package ${pkg}" >&2
    exit 1
  }
done

if grep -q '^base-config-setting-ext4fs ' "${MANIFEST}"; then
  echo "LỖI: manifest vẫn chứa base-config-setting-ext4fs." >&2
  exit 1
fi

if find build_dir -type f -path '*/root-*/lib/preinit/79_disk_ready' \
  -print -quit | grep -q .; then
  echo "LỖI: rootfs vẫn chứa hook /lib/preinit/79_disk_ready." >&2
  exit 1
fi

cd "${OUT}"
sha256sum *google_wifi*factory.bin *google_wifi*sysupgrade.bin \
  | tee SHA256SUMS-GALE-XWRT

echo "Build X-WRT Gale ${GALE_VERSION} thành công."
echo "Firmware nằm tại ${OUT}"
