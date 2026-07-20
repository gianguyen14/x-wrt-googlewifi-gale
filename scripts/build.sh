#!/usr/bin/env bash
set -Eeuo pipefail

export TERM="${TERM:-xterm-256color}"

ROOT="${HOME}/xwrt-gale-build"
SRC="${ROOT}/x-wrt"
RELEASE_DIR="${ROOT}/release"
LOG_DIR="${ROOT}/logs"
JOBS="${JOBS:-2}"
GALE_VERSION="3.0.0-ab2"
AB_KERNEL_MIB="32"
AB_ROOTFS_MIB="192"

# Pinned revisions: same tested X-WRT/feed set as the previous v2.0.4 build.
XWRT_COMMIT="5b7e1e72a7cf2b164fa8f8f87b3ad74d39b3007c"
PKG_COMMIT="91d208ea48170415a7207251a9897a298172b872"
LUCI_COMMIT="fdb3cd943258c4d57c0b8cfcac9c16cb4c33afa4"
ROUTING_COMMIT="8c2385009d29a6d4e3ecc8cc38e8c5c0d71c691f"
TELEPHONY_COMMIT="4d8d33a023b24c52cd9443b9dc201fbdfe9c6aef"
VIDEO_COMMIT="a951381b6c58b9b1eb087f09c9a20cff4ffe8063"
X_COMMIT="befbdccba1990dc24c4557ee1e431a92f8b21aec"

ULTIMATE_PACKAGES=(
  luci luci-ssl-openssl luci-compat luci-mod-dashboard luci-theme-argon
  luci-app-wizard base-config-setting luci-app-xwan

  kmod-natcap natcapd luci-app-natcap
  openvpn-openssl luci-app-openvpn
  luci-proto-wireguard wireguard-tools
  tailscale zerotier kmod-tun

  wpad-mbedtls hostapd-utils iw iwinfo
  firewall4 nftables-json ip-full conntrack
  sqm-scripts luci-app-sqm kmod-sched-cake kmod-sched-core kmod-ifb
  luci-app-ddns ddns-scripts-services

  adguardhome
  mwan3 luci-app-mwan3
  pbr luci-app-pbr
  banip luci-app-banip
  dawn luci-app-dawn usteer luci-app-usteer
  mesh11sd luci-app-mesh11sd
  luci-app-upnp miniupnpd-nftables

  luci-app-nlbwmon nlbwmon
  luci-app-samba4 samba4-server wsdd2
  snmpd tcpdump iperf3 mtr iftop softflowd
  vnstat2 luci-app-vnstat2

  frr frr-bgp frr-ospfd frr-ospf6d frr-ripd frr-ripngd frr-bfdd luci-app-frr
  strongswan strongswan-charon strongswan-swanctl
  xl2tpd gre kmod-gre kmod-gre6 vxlan kmod-vxlan
  kmod-bonding luci-proto-bonding lldpd
  opennds luci-app-opennds freeradius3
  mosquitto-ssl mosquitto-client-ssl
  chrony microsocks tinyproxy

  curl ca-bundle ca-certificates jsonfilter jq
  bash nano htop irqbalance
  block-mount kmod-fs-ext4 kmod-fs-f2fs kmod-fs-vfat mkf2fs
  zram-swap kmod-zram swap-utils
  kmod-usb-storage kmod-usb-storage-uas
  fdisk gdisk sgdisk partx-utils e2fsprogs resize2fs blkid blockdev lsblk
  luci-app-ttyd ttyd luci-app-wol etherwake
)

REQUIRED_PACKAGES=(
  kmod-natcap natcapd luci-app-natcap
  openvpn-openssl wireguard-tools
  zram-swap kmod-zram
  sgdisk partx-utils mkf2fs block-mount
)

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

die() {
  echo "LỖI: $*" >&2
  exit 1
}

install_host_deps() {
  log "Cài build dependencies"
  sudo apt-get update
  sudo apt-get install -y \
    build-essential clang flex bison g++ gawk gcc-multilib gettext git \
    libncurses-dev libssl-dev libelf-dev python3 python3-setuptools \
    python3-pyelftools rsync swig unzip zlib1g-dev libzstd-dev \
    file wget curl time patch diffutils ca-certificates ccache gdisk
}

prepare_source() {
  log "Clone X-WRT và pin feeds"
  rm -rf "${ROOT}"
  mkdir -p "${ROOT}" "${RELEASE_DIR}" "${LOG_DIR}"

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
}

patch_recovery_loop() {
  log "Chặn disk_ready.preinit sửa GPT trên Google WiFi"
  local preinit="${SRC}/feeds/x/base-config-setting/files/disk_ready.preinit"
  [[ -f "${preinit}" ]] || die "Không tìm thấy ${preinit}"

  python3 - "${preinit}" <<'PY_RECOVERY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = '\tcase "$(board_name)" in\n'
guard = (
    '\t# Google WiFi Gale A/B: never resize or rewrite the GPT here.\n'
    '\tcase "$(board_name)" in\n'
    '\tgoogle,wifi)\n'
    '\t\treturn\n'
    '\t\t;;\n'
)
if "Google WiFi Gale A/B" not in t:
    if marker not in t:
        raise SystemExit("Không tìm thấy vị trí vá disk_ready.preinit")
    t = t.replace(marker, guard, 1)
p.write_text(t, encoding="utf-8")
PY_RECOVERY
}

patch_ab_image_layout() {
  log "Tạo factory image A/B cho Depthcharge"
  local mk="${SRC}/target/linux/ipq40xx/image/chromium.mk"
  [[ -f "${mk}" ]] || die "Không tìm thấy ${mk}"

  cat > "${mk}" <<EOF_CHROMIUM_MK
DTS_DIR := \$(DTS_DIR)/qcom

GALE_AB_KERNEL_PARTSIZE := ${AB_KERNEL_MIB}
GALE_AB_ROOTFS_PARTSIZE := ${AB_ROOTFS_MIB}

# Factory image contains both bootable slots. A shared rootfs_data partition is
# created on first boot in the remaining physical eMMC space.
define Build/cros-gpt-ab
\tcp \$@ \$@.tmp 2>/dev/null || true
\tptgen -o \$@.tmp -g \\
\t\t-T cros_kernel -N KERN-A -p \$(GALE_AB_KERNEL_PARTSIZE)m \\
\t\t-N ROOT-A -p \$(GALE_AB_ROOTFS_PARTSIZE)m \\
\t\t-T cros_kernel -N KERN-B -p \$(GALE_AB_KERNEL_PARTSIZE)m \\
\t\t-N ROOT-B -p \$(GALE_AB_ROOTFS_PARTSIZE)m
\tcat \$@.tmp >> \$@
\trm -f \$@.tmp
endef

define Build/append-gale-kernel-slot
\tdd if=\$(IMAGE_KERNEL) bs=\$(GALE_AB_KERNEL_PARTSIZE)M conv=sync >> \$@
endef

define Build/append-gale-rootfs-slot
\tdd if=\$(IMAGE_ROOTFS) bs=\$(GALE_AB_ROOTFS_PARTSIZE)M conv=sync >> \$@
endef

# ChromeOS GPT attributes:
# bits 48..51 = priority, bits 52..55 = tries, bit 56 = successful.
# KERN-A: P=15,T=0,S=1. KERN-B: P=14,T=0,S=1.
define Build/gale-ab-gpt-attrs
\tsgdisk \\
\t\t--attributes=1:set:48 --attributes=1:set:49 \\
\t\t--attributes=1:set:50 --attributes=1:set:51 \\
\t\t--attributes=1:set:56 \\
\t\t--attributes=3:set:49 --attributes=3:set:50 \\
\t\t--attributes=3:set:51 --attributes=3:set:56 \\
\t\t\$@
endef

# Depthcharge substitutes %U with the selected kernel PARTUUID. PARTNROFF=1
# chooses the rootfs immediately after that kernel. The fstools option enables
# discovery of a shared GPT partition named rootfs_data.
define Build/cros-vboot
\t\$(STAGING_DIR_HOST)/bin/cros-vbutil \\
\t\t-k \$@ \\
\t\t-c "root=PARTUUID=%U/PARTNROFF=1 rootwait fstools_partname_fallback_scan=1" \\
\t\t-o \$@.new
\t@mv \$@.new \$@
endef

define Device/google_wifi
\tDEVICE_VENDOR := Google
\tDEVICE_MODEL := WiFi (Gale) Ultimate A/B
\tSOC := qcom-ipq4019
\tDEVICE_DTS := qcom-ipq4019-wifi
\tKERNEL_SUFFIX := -fit-zImage.itb.vboot
\tKERNEL = kernel-bin | fit none \$\$(KDIR)/image-\$\$(DEVICE_DTS).dtb | cros-vboot
\tKERNEL_NAME := zImage
\tIMAGES += factory.bin
\tIMAGE/factory.bin := cros-gpt-ab | append-gale-kernel-slot | append-gale-rootfs-slot | append-gale-kernel-slot | append-gale-rootfs-slot | gale-ab-gpt-attrs
\tDEVICE_PACKAGES := partx-utils gdisk sgdisk mkf2fs block-mount \\
\t\tkmod-fs-ext4 kmod-fs-f2fs kmod-google-firmware kmod-ramoops
endef
TARGET_DEVICES += google_wifi
EOF_CHROMIUM_MK

  # The here-document uses visible \t markers for readability. Convert them
  # to real Makefile TAB characters; otherwise Device variables such as SOC are
  # not assignments and DEVICE_DTS degrades to "-wifi".
  python3 - "${mk}" <<'PY_MAKE_TABS'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8").replace("\\t", "\t")
p.write_text(t, encoding="utf-8")
PY_MAKE_TABS

  if grep -qF '\t' "${mk}"; then
    die "chromium.mk vẫn còn ký hiệu \\t thay vì TAB thật"
  fi
  grep -q $'^\tDEVICE_DTS := qcom-ipq4019-wifi$' "${mk}" || \
    die "DEVICE_DTS Google WiFi chưa được cố định"
}

write_upgrade_helper() {
  local helper="${SRC}/target/linux/ipq40xx/base-files/lib/upgrade/gale-ab.sh"
  mkdir -p "$(dirname "${helper}")"

  cat > "${helper}" <<'EOF_GALE_AB_UPGRADE'
#!/bin/sh

GALE_AB_DISK="/dev/mmcblk0"

gale_ab_part_by_label() {
        local label="$1" uevent
        for uevent in /sys/class/block/mmcblk0p*/uevent; do
                [ -r "$uevent" ] || continue
                unset DEVNAME PARTNAME
                . "$uevent"
                [ "${PARTNAME:-}" = "$label" ] || continue
                printf '/dev/%s\n' "$DEVNAME"
                return 0
        done
        return 1
}

gale_ab_index() {
        printf '%s\n' "${1##*p}"
}

gale_ab_active_kernel() {
        local spec uuid label dev partuuid
        spec="$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline | head -n1)"
        uuid="${spec%%/*}"
        [ -n "$uuid" ] || return 1

        for label in KERN-A KERN-B; do
                dev="$(gale_ab_part_by_label "$label")" || continue
                partuuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)"
                [ "$partuuid" = "$uuid" ] || continue
                printf '%s\n' "$dev"
                return 0
        done
        return 1
}

gale_ab_attr_clear() {
        local part="$1" bit
        set --
        for bit in 48 49 50 51 52 53 54 55 56; do
                set -- "$@" "--attributes=${part}:clear:${bit}"
        done
        sgdisk "$@" "$GALE_AB_DISK" >/dev/null
}

# Arguments: partition-index priority tries successful
gale_ab_attr_set() {
        local part="$1" priority="$2" tries="$3" successful="$4" i bit
        gale_ab_attr_clear "$part" || return 1
        set --
        i=0
        while [ "$i" -lt 4 ]; do
                if [ $((priority & (1 << i))) -ne 0 ]; then
                        bit=$((48 + i))
                        set -- "$@" "--attributes=${part}:set:${bit}"
                fi
                if [ $((tries & (1 << i))) -ne 0 ]; then
                        bit=$((52 + i))
                        set -- "$@" "--attributes=${part}:set:${bit}"
                fi
                i=$((i + 1))
        done
        [ "$successful" = 1 ] && set -- "$@" "--attributes=${part}:set:56"
        [ "$#" -eq 0 ] || sgdisk "$@" "$GALE_AB_DISK" >/dev/null
}

gale_ab_layout_ok() {
        local label
        [ -b "$GALE_AB_DISK" ] || return 1
        for label in KERN-A ROOT-A KERN-B ROOT-B; do
                gale_ab_part_by_label "$label" >/dev/null || return 1
        done
}

gale_ab_check_layout() {
        if ! gale_ab_layout_ok; then
                cat >&2 <<'EOF_LAYOUT_ERROR'
Firmware này dùng bố cục A/B mới của Google WiFi Gale.
Thiết bị hiện chưa có KERN-A/ROOT-A/KERN-B/ROOT-B.
Không được sysupgrade trực tiếp từ bố cục kernel/rootfs một slot.
Hãy cài factory.bin A/B qua USB recovery; thao tác đó xóa eMMC.
EOF_LAYOUT_ERROR
                return 1
        fi
}

gale_ab_tar_size() {
        tar Oxf "$1" "$2" | wc -c
}

gale_ab_tar_hash() {
        tar Oxf "$1" "$2" | sha256sum | awk '{print $1}'
}

gale_ab_device_hash() {
        local dev="$1" bytes="$2"
        dd if="$dev" bs=1M 2>/dev/null | head -c "$bytes" | sha256sum | awk '{print $1}'
}

gale_ab_verify() {
        local image="$1" entry="$2" dev="$3"
        local bytes capacity src_hash dst_hash

        bytes="$(gale_ab_tar_size "$image" "$entry")" || return 1
        capacity="$(blockdev --getsize64 "$dev")" || return 1
        [ "$bytes" -gt 0 ] && [ "$bytes" -le "$capacity" ] || {
                echo "$entry vượt dung lượng $dev" >&2
                return 1
        }

        src_hash="$(gale_ab_tar_hash "$image" "$entry")" || return 1
        dst_hash="$(gale_ab_device_hash "$dev" "$bytes")" || return 1
        [ "$src_hash" = "$dst_hash" ] || {
                echo "SHA-256 không khớp trên $dev" >&2
                echo "source=$src_hash" >&2
                echo "device=$dst_hash" >&2
                return 1
        }
}

gale_ab_do_upgrade() {
        local image="$1" board_dir kernel_entry root_entry
        local active_kernel active_index active_label
        local target_kernel target_root target_index target_label
        local kernel_size root_size kernel_capacity root_capacity

        gale_ab_check_layout || return 1

        board_dir="$(tar tf "$image" | grep -m1 '^sysupgrade-.*/$')"
        board_dir="${board_dir%/}"
        [ -n "$board_dir" ] || return 1
        kernel_entry="${board_dir}/kernel"
        root_entry="${board_dir}/root"
        tar tf "$image" "$kernel_entry" >/dev/null 2>&1 || return 1
        tar tf "$image" "$root_entry" >/dev/null 2>&1 || return 1

        active_kernel="$(gale_ab_active_kernel)" || {
                echo "Không xác định được slot đang chạy." >&2
                return 1
        }
        active_index="$(gale_ab_index "$active_kernel")"

        case "$active_index" in
                1)
                        active_label=A
                        target_label=B
                        target_kernel="$(gale_ab_part_by_label KERN-B)"
                        target_root="$(gale_ab_part_by_label ROOT-B)"
                        ;;
                3)
                        active_label=B
                        target_label=A
                        target_kernel="$(gale_ab_part_by_label KERN-A)"
                        target_root="$(gale_ab_part_by_label ROOT-A)"
                        ;;
                *)
                        echo "Kernel hiện tại không thuộc slot A/B." >&2
                        return 1
                        ;;
        esac
        target_index="$(gale_ab_index "$target_kernel")"

        kernel_size="$(gale_ab_tar_size "$image" "$kernel_entry")"
        root_size="$(gale_ab_tar_size "$image" "$root_entry")"
        kernel_capacity="$(blockdev --getsize64 "$target_kernel")"
        root_capacity="$(blockdev --getsize64 "$target_root")"
        [ "$kernel_size" -le "$kernel_capacity" ] || return 1
        [ "$root_size" -le "$root_capacity" ] || return 1

        if [ -n "${UPGRADE_BACKUP:-}" ] && [ -f "$UPGRADE_BACKUP" ] && [ -d /overlay ]; then
                mkdir -p /overlay/gale-ab/config-backups
                cp "$UPGRADE_BACKUP" \
                        "/overlay/gale-ab/config-backups/pre-upgrade-${active_label}-$(date +%s).tgz" || true
        fi

        echo "Ghi firmware vào slot không hoạt động ${target_label}"

        # Invalidate target first. A power failure before the final GPT switch
        # leaves the active slot untouched and bootable.
        gale_ab_attr_set "$target_index" 0 0 0 || return 1
        sync

        dd if=/dev/zero of="$target_kernel" bs=512 count=8 conv=fsync 2>/dev/null || return 1
        dd if=/dev/zero of="$target_root" bs=1M count=$((root_capacity / 1048576)) conv=fsync 2>/dev/null || return 1

        tar Oxf "$image" "$root_entry" | \
                dd of="$target_root" bs=1M conv=fsync 2>/dev/null || return 1
        sync
        tar Oxf "$image" "$kernel_entry" | \
                dd of="$target_kernel" bs=1M conv=fsync 2>/dev/null || return 1
        sync

        gale_ab_verify "$image" "$root_entry" "$target_root" || return 1
        gale_ab_verify "$image" "$kernel_entry" "$target_kernel" || return 1

        # Keep the old slot as a confirmed fallback. Try the new slot 3 times.
        gale_ab_attr_set "$active_index" 14 0 1 || return 1
        gale_ab_attr_set "$target_index" 15 3 0 || return 1
        sync

        echo "Slot ${target_label} đã ghi và xác minh; Depthcharge sẽ thử boot tối đa 3 lần."
}
EOF_GALE_AB_UPGRADE

  chmod +x "${helper}"
}

patch_platform_upgrade() {
  log "Thay sysupgrade một slot bằng sysupgrade A/B"
  local platform="${SRC}/target/linux/ipq40xx/base-files/lib/upgrade/platform.sh"
  [[ -f "${platform}" ]] || die "Không tìm thấy ${platform}"

  write_upgrade_helper

  python3 - "${platform}" <<'PY_PLATFORM'
from pathlib import Path
import sys

p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")

if '. /lib/upgrade/gale-ab.sh' not in t:
    marker = "RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'\n"
    if marker not in t:
        raise SystemExit("Không tìm thấy RAMFS_COPY_DATA")
    replacement = (
        "RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock "
        "/lib/upgrade/gale-ab.sh'\n\n"
        ". /lib/upgrade/gale-ab.sh\n"
    )
    t = t.replace(marker, replacement, 1)

t = t.replace(
    "RAMFS_COPY_BIN='fw_printenv fw_setenv'",
    "RAMFS_COPY_BIN='fw_printenv fw_setenv sgdisk blkid blockdev partx sha256sum'",
)

old_upgrade = (
    '\tgoogle,wifi)\n'
    '\t\texport_bootdevice\n'
    '\t\texport_partdevice CI_ROOTDEV 0\n'
    '\t\tCI_KERNPART="kernel"\n'
    '\t\tCI_ROOTPART="rootfs"\n'
    '\t\temmc_do_upgrade "$1"\n'
    '\t\t;;'
)
new_upgrade = (
    '\tgoogle,wifi)\n'
    '\t\tgale_ab_do_upgrade "$1"\n'
    '\t\t;;'
)
if old_upgrade not in t:
    raise SystemExit("Không tìm thấy nhánh google,wifi cũ")
t = t.replace(old_upgrade, new_upgrade, 1)

# Reject a sysupgrade image if the installed disk still uses the old single-slot layout.
start = t.find('platform_check_image()')
case_marker = '\tcase "$(board_name)" in\n'
pos = t.find(case_marker, start)
if start < 0 or pos < 0:
    raise SystemExit("Không tìm thấy platform_check_image")
check = (
    '\tgoogle,wifi)\n'
    '\t\tgale_ab_check_layout\n'
    '\t\treturn $?\n'
    '\t\t;;\n'
)
section_end = t.find('platform_do_upgrade()', start)
if check not in t[start:section_end]:
    pos += len(case_marker)
    t = t[:pos] + check + t[pos:]

# Config lives on shared rootfs_data; do not inject backup into one slot.
old_copy = (
    '\tglinet,gl-b2200|\\\n'
    '\tgoogle,wifi|\\\n'
    '\tlinksys,whw03)\n'
    '\t\temmc_copy_config\n'
    '\t\t;;'
)
new_copy = (
    '\tgoogle,wifi)\n'
    '\t\treturn 0\n'
    '\t\t;;\n'
    '\tglinet,gl-b2200|\\\n'
    '\tlinksys,whw03)\n'
    '\t\temmc_copy_config\n'
    '\t\t;;'
)
if old_copy not in t:
    raise SystemExit("Không tìm thấy platform_copy_config cũ")
t = t.replace(old_copy, new_copy, 1)

p.write_text(t, encoding="utf-8")
PY_PLATFORM
}

write_runtime_overlay() {
  log "Thêm dịch vụ A/B, health commit, LED, ZRAM và swap"
  rm -rf "${SRC}/files"
  mkdir -p \
    "${SRC}/files/etc/config" \
    "${SRC}/files/etc/gale" \
    "${SRC}/files/etc/init.d" \
    "${SRC}/files/etc/uci-defaults" \
    "${SRC}/files/etc/sysctl.d" \
    "${SRC}/files/usr/sbin"

  cat > "${SRC}/files/etc/gale/edition" <<EOF_EDITION
version=${GALE_VERSION}
edition=ultimate-ab
model=Google WiFi Gale
layout=KERN-A,ROOT-A,KERN-B,ROOT-B,rootfs_data
EOF_EDITION

  cat > "${SRC}/files/usr/sbin/gale-ab-lib" <<'EOF_AB_LIB'
#!/bin/sh
GALE_AB_DISK="/dev/mmcblk0"

gale_ab_part_by_label() {
        local label="$1" uevent
        for uevent in /sys/class/block/mmcblk0p*/uevent; do
                [ -r "$uevent" ] || continue
                unset DEVNAME PARTNAME
                . "$uevent"
                [ "${PARTNAME:-}" = "$label" ] || continue
                printf '/dev/%s\n' "$DEVNAME"
                return 0
        done
        return 1
}

gale_ab_index() { printf '%s\n' "${1##*p}"; }

gale_ab_active_kernel() {
        local spec uuid label dev partuuid
        spec="$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline | head -n1)"
        uuid="${spec%%/*}"
        [ -n "$uuid" ] || return 1
        for label in KERN-A KERN-B; do
                dev="$(gale_ab_part_by_label "$label")" || continue
                partuuid="$(blkid -s PARTUUID -o value "$dev" 2>/dev/null)"
                [ "$partuuid" = "$uuid" ] || continue
                printf '%s\n' "$dev"
                return 0
        done
        return 1
}

gale_ab_attr_clear() {
        local part="$1" bit
        set --
        for bit in 48 49 50 51 52 53 54 55 56; do
                set -- "$@" "--attributes=${part}:clear:${bit}"
        done
        sgdisk "$@" "$GALE_AB_DISK" >/dev/null
}

gale_ab_attr_set() {
        local part="$1" priority="$2" tries="$3" successful="$4" i bit
        gale_ab_attr_clear "$part" || return 1
        set --
        i=0
        while [ "$i" -lt 4 ]; do
                if [ $((priority & (1 << i))) -ne 0 ]; then
                        bit=$((48 + i)); set -- "$@" "--attributes=${part}:set:${bit}"
                fi
                if [ $((tries & (1 << i))) -ne 0 ]; then
                        bit=$((52 + i)); set -- "$@" "--attributes=${part}:set:${bit}"
                fi
                i=$((i + 1))
        done
        [ "$successful" = 1 ] && set -- "$@" "--attributes=${part}:set:56"
        [ "$#" -eq 0 ] || sgdisk "$@" "$GALE_AB_DISK" >/dev/null
}
EOF_AB_LIB

  cat > "${SRC}/files/usr/sbin/gale-ab" <<'EOF_AB_TOOL'
#!/bin/sh
set -eu
. /usr/sbin/gale-ab-lib

active="$(gale_ab_active_kernel 2>/dev/null || true)"
active_index="${active##*p}"

case "${1:-status}" in
        status)
                echo "Active kernel: ${active:-unknown}"
                cat /proc/cmdline
                echo
                sgdisk -p "$GALE_AB_DISK"
                echo
                echo '=== KERN-A ==='; sgdisk -i 1 "$GALE_AB_DISK"
                echo '=== KERN-B ==='; sgdisk -i 3 "$GALE_AB_DISK"
                ;;
        boot-a)
                [ "$active_index" != 1 ] || exit 0
                gale_ab_attr_set 3 14 0 1
                gale_ab_attr_set 1 15 3 0
                sync
                ;;
        boot-b)
                [ "$active_index" != 3 ] || exit 0
                gale_ab_attr_set 1 14 0 1
                gale_ab_attr_set 3 15 3 0
                sync
                ;;
        mark-good)
                case "$active_index" in
                        1) gale_ab_attr_set 1 15 0 1 ;;
                        3) gale_ab_attr_set 3 15 0 1 ;;
                        *) exit 1 ;;
                esac
                sync
                ;;
        rollback)
                case "$active_index" in
                        1) gale_ab_attr_set 1 14 0 1; gale_ab_attr_set 3 15 3 0 ;;
                        3) gale_ab_attr_set 3 14 0 1; gale_ab_attr_set 1 15 3 0 ;;
                        *) exit 1 ;;
                esac
                sync
                ;;
        *)
                echo "Usage: gale-ab {status|boot-a|boot-b|mark-good|rollback}" >&2
                exit 1
                ;;
esac
EOF_AB_TOOL

  cat > "${SRC}/files/usr/sbin/gale-ab-provision-worker" <<'EOF_PROVISION'
#!/bin/sh
set -eu
. /usr/sbin/gale-ab-lib

data_dev="$(gale_ab_part_by_label rootfs_data 2>/dev/null || true)"

for label in KERN-A ROOT-A KERN-B ROOT-B; do
        gale_ab_part_by_label "$label" >/dev/null || exit 1
done

if [ -z "$data_dev" ]; then
        logger -t gale-ab "Creating shared rootfs_data in remaining eMMC space"
        sgdisk -e "$GALE_AB_DISK" >/dev/null
        sgdisk -n 5:0:0 -t 5:8300 -c 5:rootfs_data "$GALE_AB_DISK" >/dev/null
        partx -u "$GALE_AB_DISK" 2>/dev/null || true
        blockdev --rereadpt "$GALE_AB_DISK" 2>/dev/null || true
        partx -a -n 5 "$GALE_AB_DISK" 2>/dev/null || true

        n=0
        while [ ! -b /dev/mmcblk0p5 ] && [ "$n" -lt 20 ]; do
                sleep 1
                n=$((n + 1))
        done

        if [ ! -b /dev/mmcblk0p5 ]; then
                logger -t gale-ab "Partition table updated; rebooting before format"
                reboot
                exit 0
        fi
        data_dev=/dev/mmcblk0p5
fi

# If fstools already formatted and mounted it during this boot, only add marker.
if mount | grep -q "^${data_dev} on /overlay "; then
        touch /overlay/.gale-ab-shared-overlay
        exit 0
fi

fs_type="$(blkid -s TYPE -o value "$data_dev" 2>/dev/null || true)"
if [ "$fs_type" != f2fs ]; then
        mkfs.f2fs -f -l rootfs_data "$data_dev" >/dev/null
fi

mkdir -p /mnt/gale-new-overlay
mount -t f2fs -o rw,noatime "$data_dev" /mnt/gale-new-overlay

if [ ! -f /mnt/gale-new-overlay/.gale-ab-shared-overlay ]; then
        # Preserve any first-boot configuration before moving to the shared overlay.
        tar -C /overlay -cpf - . | tar -C /mnt/gale-new-overlay -xpf -
        touch /mnt/gale-new-overlay/.gale-ab-shared-overlay
fi
sync
umount /mnt/gale-new-overlay
logger -t gale-ab "Shared rootfs_data ready; rebooting"
reboot
EOF_PROVISION

  cat > "${SRC}/files/etc/init.d/gale-ab-provision" <<'EOF_PROVISION_INIT'
#!/bin/sh /etc/rc.common
START=96
USE_PROCD=1

start_service() {
        [ "$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name')" = "google,wifi" ] || return 0
        procd_open_instance
        procd_set_param command /usr/sbin/gale-ab-provision-worker
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}
EOF_PROVISION_INIT

  cat > "${SRC}/files/usr/sbin/gale-ab-commit-worker" <<'EOF_COMMIT'
#!/bin/sh
set -eu
. /usr/sbin/gale-ab-lib

active="$(gale_ab_active_kernel)" || exit 1
index="$(gale_ab_index "$active")"

# Wait up to three minutes for core services and the overlay.
n=0
while [ "$n" -lt 36 ]; do
        if ubus call system board >/dev/null 2>&1 &&
           ubus call network.interface dump >/dev/null 2>&1 &&
           pidof netifd >/dev/null 2>&1 &&
           pidof rpcd >/dev/null 2>&1 &&
           grep -qs ' /overlay ' /proc/mounts &&
           [ -f /overlay/.gale-ab-shared-overlay ]; then
                sleep 20
                gale_ab_attr_set "$index" 15 0 1
                sync
                logger -t gale-ab "Marked kernel slot p${index} successful"
                exit 0
        fi
        sleep 5
        n=$((n + 1))
done

# Keep S=0 so Depthcharge can consume another try and eventually rollback.
logger -t gale-ab -p daemon.err "Boot health check failed; rebooting for retry/rollback"
sync
reboot
EOF_COMMIT

  cat > "${SRC}/files/etc/init.d/gale-ab-commit" <<'EOF_COMMIT_INIT'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

start_service() {
        [ "$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name')" = "google,wifi" ] || return 0
        procd_open_instance
        procd_set_param command /usr/sbin/gale-ab-commit-worker
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}
EOF_COMMIT_INIT

  cat > "${SRC}/files/etc/config/gale-memory" <<'EOF_MEMORY_CONFIG'
config memory 'main'
        option zram_size_mb '384'
        option zram_comp_algo 'lzo'
        option zram_priority '100'
        option swap_enabled '1'
        option swapfile '/overlay/swapfile'
        option swap_size_mb '512'
        option swap_priority '10'
EOF_MEMORY_CONFIG

  cat > "${SRC}/files/etc/sysctl.d/99-gale-memory.conf" <<'EOF_SYSCTL'
vm.swappiness=10
vm.page-cluster=0
vm.vfs_cache_pressure=100
EOF_SYSCTL

  cat > "${SRC}/files/etc/init.d/gale-swap" <<'EOF_SWAP'
#!/bin/sh /etc/rc.common
START=17
STOP=85

start() {
        local enabled file size priority
        enabled="$(uci -q get gale-memory.main.swap_enabled)"
        [ "$enabled" = 1 ] || return 0
        file="$(uci -q get gale-memory.main.swapfile)"
        size="$(uci -q get gale-memory.main.swap_size_mb)"
        priority="$(uci -q get gale-memory.main.swap_priority)"
        [ -n "$file" ] || file=/overlay/swapfile
        [ -n "$size" ] || size=512
        [ -n "$priority" ] || priority=10
        grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null && return 0
        [ -f "$file" ] || {
                dd if=/dev/zero of="$file" bs=1M count="$size" conv=fsync || return 1
                chmod 600 "$file"
                mkswap "$file" >/dev/null || return 1
        }
        swapon -p "$priority" "$file"
}

stop() {
        local file
        file="$(uci -q get gale-memory.main.swapfile)"
        [ -n "$file" ] || file=/overlay/swapfile
        grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null && swapoff "$file" || true
}
EOF_SWAP

  cat > "${SRC}/files/etc/uci-defaults/97-gale-ab" <<'EOF_DEFAULTS'
#!/bin/sh
/etc/init.d/gale-ab-provision enable 2>/dev/null || true
/etc/init.d/gale-ab-commit enable 2>/dev/null || true
/etc/init.d/gale-swap enable 2>/dev/null || true
/etc/init.d/zram enable 2>/dev/null || true

uci -q set system.@system[0].zram_size_mb='384'
uci -q set system.@system[0].zram_comp_algo='lzo'
uci -q set system.@system[0].zram_priority='100'

# downloads.openwrt.org does not host the private X-WRT x feed.
for f in /etc/apk/repositories.d/*.list /etc/apk/repositories; do
        [ -f "$f" ] || continue
        sed -i '\#/x/packages\.adb$#d' "$f"
done

# Blue means the running system is healthy. Early boot/failsafe/upgrade LEDs
# are still controlled by OpenWrt diag.sh and DTS aliases.
uci -q delete system.gale_led_blue
uci set system.gale_led_blue='led'
uci set system.gale_led_blue.name='Gale running'
uci set system.gale_led_blue.sysfs='LED0_Blue'
uci set system.gale_led_blue.trigger='default-on'
uci set system.gale_led_blue.default='1'

uci -q delete system.gale_led_green
uci set system.gale_led_green='led'
uci set system.gale_led_green.name='Gale green off'
uci set system.gale_led_green.sysfs='LED0_Green'
uci set system.gale_led_green.trigger='none'
uci set system.gale_led_green.default='0'

uci -q delete system.gale_led_red
uci set system.gale_led_red='led'
uci set system.gale_led_red.name='Gale red off'
uci set system.gale_led_red.sysfs='LED0_Red'
uci set system.gale_led_red.trigger='none'
uci set system.gale_led_red.default='0'

uci commit system
exit 0
EOF_DEFAULTS

  cat > "${SRC}/files/usr/sbin/gale-health" <<'EOF_HEALTH'
#!/bin/sh
ubus call system board 2>/dev/null
free
cat /proc/swaps 2>/dev/null
df -h
/usr/sbin/gale-ab status 2>/dev/null
EOF_HEALTH

  chmod +x "${SRC}/files/usr/sbin/"*
  chmod +x "${SRC}/files/etc/init.d/gale-ab-provision"
  chmod +x "${SRC}/files/etc/init.d/gale-ab-commit"
  chmod +x "${SRC}/files/etc/init.d/gale-swap"
  chmod +x "${SRC}/files/etc/uci-defaults/97-gale-ab"
}

append_packages() {
  local pkg
  for pkg in "$@"; do
    printf 'CONFIG_PACKAGE_%s=y\n' "${pkg}" >> .config
  done
}

write_config() {
  log "Tạo cấu hình Ultimate A/B"
  cd "${SRC}"

  cat > .config <<EOF_CONFIG
CONFIG_HAVE_DOT_CONFIG=y
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_chromium=y
CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y
CONFIG_TARGET_KERNEL_PARTSIZE=${AB_KERNEL_MIB}
CONFIG_TARGET_ROOTFS_PARTSIZE=${AB_ROOTFS_MIB}

CONFIG_CCACHE=y
CONFIG_BUILD_LOG=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="X-WRT Gale"
CONFIG_VERSION_NUMBER="${GALE_VERSION}"
CONFIG_VERSION_PRODUCT="Google WiFi Gale Ultimate A/B"

CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_CKSUM=y
CONFIG_BUSYBOX_CONFIG_SHA256SUM=y
CONFIG_BUSYBOX_CONFIG_BASE64=y
CONFIG_BUSYBOX_CONFIG_TIMEOUT=y
CONFIG_BUSYBOX_CONFIG_NOHUP=y
CONFIG_BUSYBOX_CONFIG_DIFF=y
CONFIG_BUSYBOX_CONFIG_MKSWAP=y
CONFIG_BUSYBOX_CONFIG_SWAPOFF=y
CONFIG_BUSYBOX_CONFIG_SWAPON=y
CONFIG_BUSYBOX_CONFIG_FEATURE_SWAPON_PRI=y
CONFIG_BUSYBOX_CONFIG_FEATURE_SWAPON_DISCARD=y

# CONFIG_PACKAGE_base-config-setting-ext4fs is not set
# CONFIG_PACKAGE_wpad-basic-mbedtls is not set
EOF_CONFIG

  append_packages "${ULTIMATE_PACKAGES[@]}"
  make defconfig
}

verify_config() {
  local pkg
  grep -qx 'CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y' .config || \
    die "Sai target Google WiFi"

  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    grep -qx "CONFIG_PACKAGE_${pkg}=y" .config || \
      die "Thiếu package bắt buộc: ${pkg}"
  done

  ! grep -q '^CONFIG_PACKAGE_base-config-setting-ext4fs=y' .config || \
    die "base-config-setting-ext4fs bị bật lại"
}

build_ultimate() {
  local out="${SRC}/bin/targets/ipq40xx/chromium"
  local factory sysupgrade file base

  cd "${SRC}"
  write_runtime_overlay
  write_config
  verify_config

  # X-WRT may open menuconfig when .config is absent; clean only after creating it.
  make clean
  grep -qx 'CONFIG_HAVE_DOT_CONFIG=y' .config || die ".config bị mất sau make clean"

  cp .config "${LOG_DIR}/config-ultimate-ab"
  make download -j"${JOBS}"
  make -j"${JOBS}" V=s 2>&1 | tee "${LOG_DIR}/build-ultimate-ab.log"

  factory="$(find "${out}" -maxdepth 1 -type f -name '*google_wifi*factory.bin' | head -n1)"
  sysupgrade="$(find "${out}" -maxdepth 1 -type f -name '*google_wifi*sysupgrade.bin' | head -n1)"
  [[ -f "${factory}" ]] || die "Không tìm thấy factory.bin"
  [[ -f "${sysupgrade}" ]] || die "Không tìm thấy sysupgrade.bin"

  log "Xác minh GPT factory A/B"
  sgdisk -v "${factory}"
  for index in 1 2 3 4; do
    sgdisk -i "${index}" "${factory}"
  done > "${LOG_DIR}/factory-gpt.txt"

  grep -q "Partition name: 'KERN-A'" "${LOG_DIR}/factory-gpt.txt" || die "Thiếu KERN-A"
  grep -q "Partition name: 'ROOT-A'" "${LOG_DIR}/factory-gpt.txt" || die "Thiếu ROOT-A"
  grep -q "Partition name: 'KERN-B'" "${LOG_DIR}/factory-gpt.txt" || die "Thiếu KERN-B"
  grep -q "Partition name: 'ROOT-B'" "${LOG_DIR}/factory-gpt.txt" || die "Thiếu ROOT-B"

  tar tf "${sysupgrade}" | grep -q '/kernel$' || die "Sysupgrade thiếu kernel"
  tar tf "${sysupgrade}" | grep -q '/root$' || die "Sysupgrade thiếu root"

  for file in \
    "${factory}" \
    "${sysupgrade}" \
    "${out}"/*.manifest \
    "${out}"/config.build \
    "${out}"/config.buildinfo \
    "${out}"/feeds.buildinfo \
    "${out}"/version.buildinfo \
    "${out}"/profiles.json; do
    [[ -f "${file}" ]] || continue
    base="$(basename "${file}")"
    cp -av "${file}" "${RELEASE_DIR}/xwrt-gale-v${GALE_VERSION}-ultimate-ab-${base}"
  done

  cp -av "${LOG_DIR}/factory-gpt.txt" "${RELEASE_DIR}/FACTORY-GPT-A-B.txt"
  cp -av "${LOG_DIR}/config-ultimate-ab" "${RELEASE_DIR}/config-ultimate-ab"

  (
    cd "${RELEASE_DIR}"
    sha256sum *factory.bin *sysupgrade.bin > SHA256SUMS-GALE-XWRT
    cp SHA256SUMS-GALE-XWRT SHA256SUMS-GALE-AB
  )

  # Publish only renamed A/B artifacts into the workflow target directory.
  rm -f "${out}"/openwrt-*google_wifi*factory.bin \
        "${out}"/openwrt-*google_wifi*sysupgrade.bin \
        "${out}"/openwrt-*google_wifi*.manifest
  cp -av "${RELEASE_DIR}/." "${out}/"
}

main() {
  install_host_deps
  prepare_source
  patch_recovery_loop
  patch_ab_image_layout
  patch_platform_upgrade
  build_ultimate

  log "Hoàn tất X-WRT Gale Ultimate A/B ${GALE_VERSION}"
  log "Output: ${SRC}/bin/targets/ipq40xx/chromium"
  log "factory.bin A/B dùng cho cài mới và sẽ xóa toàn bộ eMMC."
  log "sysupgrade.bin chỉ dùng sau khi máy đã có KERN-A/ROOT-A/KERN-B/ROOT-B."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
