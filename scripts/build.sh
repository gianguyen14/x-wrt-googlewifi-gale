#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/xwrt-gale-build"
SRC="${ROOT}/x-wrt"
RELEASE_DIR="${ROOT}/release"
LOG_DIR="${ROOT}/logs"
JOBS="${JOBS:-2}"
GALE_VERSION="2.0.2"
PROFILES=(lite standard ultimate)

XWRT_COMMIT="5b7e1e72a7cf2b164fa8f8f87b3ad74d39b3007c"
PKG_COMMIT="91d208ea48170415a7207251a9897a298172b872"
LUCI_COMMIT="fdb3cd943258c4d57c0b8cfcac9c16cb4c33afa4"
ROUTING_COMMIT="8c2385009d29a6d4e3ecc8cc38e8c5c0d71c691f"
TELEPHONY_COMMIT="4d8d33a023b24c52cd9443b9dc201fbdfe9c6aef"
VIDEO_COMMIT="a951381b6c58b9b1eb087f09c9a20cff4ffe8063"
X_COMMIT="befbdccba1990dc24c4557ee1e431a92f8b21aec"

COMMON_PACKAGES=(
  luci luci-ssl-openssl luci-compat luci-mod-dashboard luci-theme-argon
  luci-app-wizard base-config-setting luci-app-xwan
  kmod-natcap natcapd luci-app-natcap
  openvpn-openssl luci-app-openvpn
  luci-proto-wireguard wireguard-tools
  wpad-mbedtls hostapd-utils iw iwinfo
  firewall4 nftables-json ip-full conntrack
  sqm-scripts luci-app-sqm kmod-sched-cake kmod-sched-core kmod-ifb
  luci-app-ddns ddns-scripts-services
  curl ca-bundle ca-certificates jsonfilter jq
  bash nano htop irqbalance
  block-mount kmod-fs-ext4 kmod-fs-f2fs kmod-fs-vfat
  zram-swap kmod-zram swap-utils
  kmod-usb-storage kmod-usb-storage-uas
  fdisk gdisk sgdisk partx-utils e2fsprogs resize2fs blkid blockdev lsblk
  luci-app-ttyd ttyd luci-app-wol etherwake
)

LITE_PACKAGES=(
  tailscale kmod-tun
  luci-app-nlbwmon nlbwmon
)

STANDARD_PACKAGES=(
  tailscale kmod-tun
  adguardhome
  mwan3 luci-app-mwan3
  pbr luci-app-pbr
  banip luci-app-banip
  zerotier
  dawn luci-app-dawn usteer luci-app-usteer
  luci-app-upnp miniupnpd-nftables
  luci-app-nlbwmon nlbwmon
  luci-app-samba4 samba4-server wsdd2
  snmpd tcpdump iperf3 mtr
  vnstat2 luci-app-vnstat2
)

ULTIMATE_PACKAGES=(
  "${STANDARD_PACKAGES[@]}"
  mesh11sd luci-app-mesh11sd
  softflowd iftop
  frr frr-bgp frr-ospfd frr-ospf6d frr-ripd frr-ripngd frr-bfdd luci-app-frr
  strongswan strongswan-charon strongswan-swanctl
  xl2tpd gre kmod-gre kmod-gre6 vxlan kmod-vxlan
  kmod-bonding luci-proto-bonding lldpd
  opennds luci-app-opennds freeradius3
  mosquitto-ssl mosquitto-client-ssl
  chrony microsocks tinyproxy
)

REQUIRED_PACKAGES=(
  kmod-natcap natcapd luci-app-natcap openvpn-openssl wireguard-tools
  zram-swap kmod-zram
)

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

install_host_deps() {
  sudo apt-get update
  sudo apt-get install -y \
    build-essential clang flex bison g++ gawk gcc-multilib gettext git \
    libncurses-dev libssl-dev libelf-dev python3 python3-setuptools \
    python3-pyelftools rsync swig unzip zlib1g-dev libzstd-dev \
    file wget curl time patch diffutils ca-certificates ccache
}

prepare_source() {
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
  local preinit="${SRC}/feeds/x/base-config-setting/files/disk_ready.preinit"
  [[ -f "${preinit}" ]] || { echo "Không tìm thấy ${preinit}" >&2; exit 1; }
  python3 - "${preinit}" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = '\tcase "$(board_name)" in\n'
guard = (
    '\t# Google WiFi Gale: protect ChromeOS kernel partition.\n'
    '\tcase "$(board_name)" in\n'
    '\tgoogle,wifi)\n'
    '\t\treturn\n'
    '\t\t;;\n'
)
if "protect ChromeOS kernel partition" not in t:
    if marker not in t:
        raise SystemExit("Không tìm thấy vị trí vá disk_ready.preinit")
    p.write_text(t.replace(marker, guard, 1), encoding="utf-8")
PY
}

write_overlay() {
  local profile="$1"
  local zram_size swap_enabled swap_cleaner_enabled
  case "${profile}" in
    lite)
      zram_size=256
      swap_enabled=0
      swap_cleaner_enabled=0
      ;;
    standard)
      zram_size=384
      swap_enabled=0
      swap_cleaner_enabled=0
      ;;
    ultimate)
      zram_size=384
      swap_enabled=1
      swap_cleaner_enabled=1
      ;;
    *)
      echo "Profile không hợp lệ: ${profile}" >&2
      exit 1
      ;;
  esac
  rm -rf "${SRC}/files"
  mkdir -p \
    "${SRC}/files/etc/gale" \
    "${SRC}/files/etc/config" \
    "${SRC}/files/etc/init.d" \
    "${SRC}/files/etc/uci-defaults" \
    "${SRC}/files/usr/sbin"
  cat > "${SRC}/files/etc/gale/edition" <<EOF
version=${GALE_VERSION}
edition=${profile}
model=Google WiFi Gale
EOF
  cat > "${SRC}/files/usr/sbin/gale-edition" <<'EOF'
#!/bin/sh
cat /etc/gale/edition
EOF
  cat > "${SRC}/files/usr/sbin/gale-health" <<'EOF'
#!/bin/sh
ubus call system board 2>/dev/null
free
echo "=== SWAP ==="
cat /proc/swaps 2>/dev/null
/etc/init.d/zram status 2>/dev/null || true
df -h
ubus call network.interface dump 2>/dev/null
iwinfo 2>/dev/null
EOF
  cat > "${SRC}/files/usr/sbin/gale-recovery-check" <<'EOF'
#!/bin/sh
set -eu
BOARD="$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name')"
[ "$BOARD" = "google,wifi" ] || { echo "Sai thiết bị: $BOARD"; exit 1; }
cat /proc/cmdline
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTLABEL,PARTUUID
sgdisk -p /dev/mmcblk0
echo "Chỉ kiểm tra, không thay đổi dữ liệu."
EOF
  cat > "${SRC}/files/usr/sbin/gale-log-analyzer" <<'EOF'
#!/bin/sh
LOG="$(logread 2>/dev/null)"
echo "$LOG" | grep -Eiq 'ath10k.*(crash|firmware|failed)' && echo "CRITICAL: lỗi ath10k"
echo "$LOG" | grep -Eiq '(wan|pppoe|dhcp).*(timeout|failed|down)' && echo "WARNING: lỗi WAN"
echo "$LOG" | grep -Eiq 'out of memory|oom-killer' && echo "CRITICAL: thiếu RAM"
df -P /overlay 2>/dev/null | awk 'NR==2 && int($5)>=85 {print "WARNING: overlay dùng " $5}'
EOF
  cat > "${SRC}/files/usr/sbin/gale-wifi-analyze" <<'EOF'
#!/bin/sh
iwinfo 2>/dev/null
echo "Analyze-only: không tự đổi channel hoặc công suất phát."
EOF

  cat > "${SRC}/files/etc/config/gale-memory" <<MEMCFG
config memory 'main'
        option zram_enabled '1'
        option zram_size_mb '${zram_size}'
        option zram_comp_algo 'lzo'
        option zram_priority '100'
        option swap_enabled '${swap_enabled}'
        option swapfile '/overlay/swapfile'
        option swap_size_mb '512'
        option swap_priority '10'
        option swap_cleaner_enabled '${swap_cleaner_enabled}'
        option swap_cleaner_interval '30'
        option swap_cleaner_reserve_mb '64'
        option swappiness '10'
        option page_cluster '0'
        option vfs_cache_pressure '100'
MEMCFG

  cat > "${SRC}/files/etc/uci-defaults/98-gale-memory" <<'MEMDEFAULTS'
#!/bin/sh

zram_enabled="$(uci -q get gale-memory.main.zram_enabled)"
zram_size="$(uci -q get gale-memory.main.zram_size_mb)"
zram_algo="$(uci -q get gale-memory.main.zram_comp_algo)"
zram_priority="$(uci -q get gale-memory.main.zram_priority)"

[ -n "$zram_size" ] || zram_size=256
[ -n "$zram_algo" ] || zram_algo=lzo
[ -n "$zram_priority" ] || zram_priority=100

uci -q set system.@system[0].zram_size_mb="$zram_size"
uci -q set system.@system[0].zram_comp_algo="$zram_algo"
uci -q set system.@system[0].zram_priority="$zram_priority"
uci -q commit system

swappiness="$(uci -q get gale-memory.main.swappiness)"
page_cluster="$(uci -q get gale-memory.main.page_cluster)"
vfs_cache_pressure="$(uci -q get gale-memory.main.vfs_cache_pressure)"
[ -n "$swappiness" ] || swappiness=10
[ -n "$page_cluster" ] || page_cluster=0
[ -n "$vfs_cache_pressure" ] || vfs_cache_pressure=100

mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-gale-memory.conf <<EOF
vm.swappiness=$swappiness
vm.page-cluster=$page_cluster
vm.vfs_cache_pressure=$vfs_cache_pressure
EOF
sysctl -p /etc/sysctl.d/99-gale-memory.conf >/dev/null 2>&1 || true

if [ "$zram_enabled" = "1" ]; then
        /etc/init.d/zram enable 2>/dev/null || true
else
        /etc/init.d/zram disable 2>/dev/null || true
fi

/etc/init.d/gale-swap enable 2>/dev/null || true

if [ "$(uci -q get gale-memory.main.swap_cleaner_enabled)" = "1" ]; then
        /etc/init.d/gale-swap-cleaner enable 2>/dev/null || true
else
        /etc/init.d/gale-swap-cleaner disable 2>/dev/null || true
fi

exit 0
MEMDEFAULTS

  cat > "${SRC}/files/etc/init.d/gale-swap" <<'SWAPINIT'
#!/bin/sh /etc/rc.common

START=16
STOP=85

cfg() {
        uci -q get "gale-memory.main.$1"
}

swap_file() {
        local file
        file="$(cfg swapfile)"
        [ -n "$file" ] || file="/overlay/swapfile"
        printf '%s\n' "$file"
}

start() {
        local enabled file size priority dir available_kb required_kb

        enabled="$(cfg swap_enabled)"
        [ "$enabled" = "1" ] || return 0

        file="$(swap_file)"
        size="$(cfg swap_size_mb)"
        priority="$(cfg swap_priority)"
        [ -n "$size" ] || size=512
        [ -n "$priority" ] || priority=10

        case "$file" in
                /overlay/*|/mnt/*) ;;
                *)
                        logger -t gale-swap -p daemon.err \
                                "Từ chối swapfile ngoài /overlay hoặc /mnt: $file"
                        return 1
                        ;;
        esac

        grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null && return 0

        dir="$(dirname "$file")"
        mkdir -p "$dir"

        if [ ! -f "$file" ]; then
                available_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')"
                required_kb=$((size * 1024 + 65536))

                if [ -z "$available_kb" ] || [ "$available_kb" -lt "$required_kb" ]; then
                        logger -t gale-swap -p daemon.err \
                                "Không đủ dung lượng để tạo swapfile ${size} MiB tại $dir"
                        return 1
                fi

                logger -t gale-swap \
                        "Đang tạo swapfile ${size} MiB tại $file"
                rm -f "$file"
                dd if=/dev/zero of="$file" bs=1M count="$size" ||
                        { rm -f "$file"; return 1; }
                chmod 600 "$file"
                sync
                busybox mkswap "$file" >/dev/null ||
                        { rm -f "$file"; return 1; }
        fi

        chmod 600 "$file"
        busybox swapon -p "$priority" "$file" || {
                logger -t gale-swap -p daemon.err \
                        "Không thể bật swapfile $file; filesystem có thể không hỗ trợ swapfile"
                return 1
        }

        logger -t gale-swap \
                "Đã bật $file với priority $priority"
}

stop() {
        local file
        file="$(swap_file)"
        if grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null; then
                busybox swapoff "$file"
                logger -t gale-swap "Đã tắt $file"
        fi
}
SWAPINIT

  cat > "${SRC}/files/etc/init.d/gale-swap-cleaner" <<'CLEANERINIT'
#!/bin/sh /etc/rc.common

START=97
STOP=10
USE_PROCD=1

cfg() {
        uci -q get "gale-memory.main.$1"
}

start_service() {
        local enabled interval

        enabled="$(cfg swap_cleaner_enabled)"
        [ "$enabled" = "1" ] || return 0

        interval="$(cfg swap_cleaner_interval)"
        [ -n "$interval" ] || interval=30

        case "$interval" in
                ''|*[!0-9]*) interval=30 ;;
        esac
        [ "$interval" -ge 5 ] || interval=5

        procd_open_instance
        procd_set_param command /usr/sbin/gale-swap-cleaner "$interval"
        procd_set_param respawn 3600 5 5
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}
CLEANERINIT

  cat > "${SRC}/files/usr/sbin/gale-swap-cleaner" <<'CLEANER'
#!/bin/sh
set -u

interval_minutes="${1:-30}"
case "$interval_minutes" in
        ''|*[!0-9]*) interval_minutes=30 ;;
esac
[ "$interval_minutes" -ge 5 ] || interval_minutes=5

while true; do
        sleep $((interval_minutes * 60))

        [ "$(uci -q get gale-memory.main.swap_cleaner_enabled)" = "1" ] ||
                continue

        file="$(uci -q get gale-memory.main.swapfile)"
        [ -n "$file" ] || file="/overlay/swapfile"

        grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null || continue

        swap_used_kb="$(awk -v f="$file" '$1==f {print $3}' /proc/swaps)"
        mem_available_kb="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
        reserve_mb="$(uci -q get gale-memory.main.swap_cleaner_reserve_mb)"
        priority="$(uci -q get gale-memory.main.swap_priority)"

        [ -n "$swap_used_kb" ] || swap_used_kb=0
        [ -n "$mem_available_kb" ] || mem_available_kb=0
        [ -n "$reserve_mb" ] || reserve_mb=64
        [ -n "$priority" ] || priority=10

        required_kb=$((swap_used_kb + reserve_mb * 1024))

        # Chỉ thu hồi swap khi RAM khả dụng đủ chứa toàn bộ dữ liệu đang swap
        # cộng thêm vùng dự phòng. Điều này tránh swapoff gây OOM.
        if [ "$swap_used_kb" -gt 0 ] &&
           [ "$mem_available_kb" -gt "$required_kb" ]; then
                logger -t gale-swap-cleaner \
                        "Thu hồi ${swap_used_kb} KiB từ swapfile về RAM/ZRAM"

                if busybox swapoff "$file"; then
                        busybox swapon -p "$priority" "$file" ||
                                logger -t gale-swap-cleaner -p daemon.err \
                                        "Không thể bật lại swapfile $file"
                else
                        logger -t gale-swap-cleaner -p daemon.warning \
                                "Bỏ qua: swapoff thất bại"
                fi
        fi
done
CLEANER

  cat > "${SRC}/files/usr/sbin/gale-memory" <<'MEMTOOL'
#!/bin/sh
set -eu

usage() {
        cat <<'EOF'
Usage:
  gale-memory status
  gale-memory zram-restart
  gale-memory zram-size <64-480 MiB>
  gale-memory swap-on [size MiB]
  gale-memory swap-off
  gale-memory swap-delete
  gale-memory cleaner-on
  gale-memory cleaner-off
  gale-memory cleaner-run
EOF
}

is_number() {
        case "$1" in
                ''|*[!0-9]*) return 1 ;;
                *) return 0 ;;
        esac
}

cmd="${1:-status}"

case "$cmd" in
        status)
                echo "=== MEMORY ==="
                free
                echo
                echo "=== ACTIVE SWAP ==="
                cat /proc/swaps 2>/dev/null
                echo
                echo "=== ZRAM ==="
                /etc/init.d/zram status 2>/dev/null || true
                echo
                echo "=== CONFIG ==="
                uci show gale-memory 2>/dev/null
                ;;

        zram-restart)
                uci -q set gale-memory.main.zram_enabled='1'
                uci -q set system.@system[0].zram_size_mb="$(
                        uci -q get gale-memory.main.zram_size_mb
                )"
                uci -q set system.@system[0].zram_comp_algo="$(
                        uci -q get gale-memory.main.zram_comp_algo
                )"
                uci -q set system.@system[0].zram_priority="$(
                        uci -q get gale-memory.main.zram_priority
                )"
                uci -q commit gale-memory
                uci -q commit system
                /etc/init.d/zram enable
                /etc/init.d/zram restart
                ;;

        zram-size)
                size="${2:-}"
                is_number "$size" || { usage; exit 1; }
                [ "$size" -ge 64 ] && [ "$size" -le 480 ] || {
                        echo "ZRAM phải nằm trong khoảng 64-480 MiB." >&2
                        exit 1
                }
                uci -q set gale-memory.main.zram_size_mb="$size"
                uci -q set system.@system[0].zram_size_mb="$size"
                uci -q commit gale-memory
                uci -q commit system
                /etc/init.d/zram restart
                ;;

        swap-on)
                size="${2:-$(uci -q get gale-memory.main.swap_size_mb)}"
                [ -n "$size" ] || size=512
                is_number "$size" || { usage; exit 1; }
                [ "$size" -ge 64 ] && [ "$size" -le 2048 ] || {
                        echo "Swapfile phải nằm trong khoảng 64-2048 MiB." >&2
                        exit 1
                }
                /etc/init.d/gale-swap stop 2>/dev/null || true
                uci -q set gale-memory.main.swap_size_mb="$size"
                uci -q set gale-memory.main.swap_enabled='1'
                uci -q commit gale-memory
                /etc/init.d/gale-swap enable
                /etc/init.d/gale-swap start
                ;;

        swap-off)
                /etc/init.d/gale-swap stop 2>/dev/null || true
                uci -q set gale-memory.main.swap_enabled='0'
                uci -q commit gale-memory
                ;;

        swap-delete)
                /etc/init.d/gale-swap stop 2>/dev/null || true
                file="$(uci -q get gale-memory.main.swapfile)"
                [ -n "$file" ] || file="/overlay/swapfile"
                case "$file" in
                        /overlay/*|/mnt/*) rm -f "$file" ;;
                        *) echo "Từ chối xóa đường dẫn không an toàn: $file" >&2; exit 1 ;;
                esac
                uci -q set gale-memory.main.swap_enabled='0'
                uci -q commit gale-memory
                ;;

        cleaner-on)
                uci -q set gale-memory.main.swap_cleaner_enabled='1'
                uci -q commit gale-memory
                /etc/init.d/gale-swap-cleaner enable
                /etc/init.d/gale-swap-cleaner restart
                ;;

        cleaner-off)
                /etc/init.d/gale-swap-cleaner stop 2>/dev/null || true
                /etc/init.d/gale-swap-cleaner disable 2>/dev/null || true
                uci -q set gale-memory.main.swap_cleaner_enabled='0'
                uci -q commit gale-memory
                ;;

        cleaner-run)
                file="$(uci -q get gale-memory.main.swapfile)"
                [ -n "$file" ] || file="/overlay/swapfile"
                grep -q "^${file}[[:space:]]" /proc/swaps 2>/dev/null || {
                        echo "Swapfile chưa hoạt động."
                        exit 0
                }
                used="$(awk -v f="$file" '$1==f {print $3}' /proc/swaps)"
                available="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
                reserve="$(uci -q get gale-memory.main.swap_cleaner_reserve_mb)"
                priority="$(uci -q get gale-memory.main.swap_priority)"
                [ -n "$used" ] || used=0
                [ -n "$available" ] || available=0
                [ -n "$reserve" ] || reserve=64
                [ -n "$priority" ] || priority=10
                required=$((used + reserve * 1024))
                if [ "$used" -gt 0 ] && [ "$available" -gt "$required" ]; then
                        busybox swapoff "$file"
                        busybox swapon -p "$priority" "$file"
                        echo "Đã thu hồi dữ liệu khỏi swapfile."
                else
                        echo "Bỏ qua để tránh thiếu RAM: used=${used} KiB, available=${available} KiB."
                fi
                ;;

        *)
                usage
                exit 1
                ;;
esac
MEMTOOL

  chmod +x "${SRC}/files/usr/sbin/"*
  chmod +x "${SRC}/files/etc/init.d/gale-swap"
  chmod +x "${SRC}/files/etc/init.d/gale-swap-cleaner"
  chmod +x "${SRC}/files/etc/uci-defaults/98-gale-memory"
}

append_packages() {
  local pkg
  for pkg in "$@"; do
    printf 'CONFIG_PACKAGE_%s=y\n' "${pkg}" >> .config
  done
}

write_config() {
  local profile="$1"
  cat > .config <<EOF
CONFIG_TARGET_ipq40xx=y
CONFIG_TARGET_ipq40xx_chromium=y
CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y
CONFIG_CCACHE=y
CONFIG_BUILD_LOG=y
CONFIG_VERSIONOPT=y
CONFIG_VERSION_DIST="X-WRT Gale"
CONFIG_VERSION_NUMBER="${GALE_VERSION}"
CONFIG_VERSION_PRODUCT="Google WiFi Gale ${profile}"
CONFIG_BUSYBOX_CUSTOM=y
CONFIG_BUSYBOX_CONFIG_CKSUM=y
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
EOF
  append_packages "${COMMON_PACKAGES[@]}"
  case "${profile}" in
    lite) append_packages "${LITE_PACKAGES[@]}" ;;
    standard) append_packages "${STANDARD_PACKAGES[@]}" ;;
    ultimate) append_packages "${ULTIMATE_PACKAGES[@]}" ;;
    *) echo "Profile không hợp lệ: ${profile}" >&2; exit 1 ;;
  esac
  make defconfig
}

verify_config() {
  local pkg
  grep -qx 'CONFIG_TARGET_ipq40xx_chromium_DEVICE_google_wifi=y' .config || exit 1
  for pkg in "${REQUIRED_PACKAGES[@]}"; do
    grep -qx "CONFIG_PACKAGE_${pkg}=y" .config || {
      echo "Thiếu package bắt buộc: ${pkg}" >&2
      exit 1
    }
  done
  ! grep -q '^CONFIG_PACKAGE_base-config-setting-ext4fs=y' .config || {
    echo "base-config-setting-ext4fs bị bật lại" >&2
    exit 1
  }
}

build_profile() {
  local profile="$1"
  local out="${SRC}/bin/targets/ipq40xx/chromium"
  local file base
  log "Build ${profile}"
  cd "${SRC}"
  make clean
  write_overlay "${profile}"
  write_config "${profile}"
  verify_config
  cp .config "${LOG_DIR}/config-${profile}"
  make download -j"${JOBS}"
  make -j"${JOBS}" V=s 2>&1 | tee "${LOG_DIR}/build-${profile}.log"
  for file in "${out}"/*google_wifi*factory.bin "${out}"/*google_wifi*sysupgrade.bin "${out}"/*.manifest; do
    [[ -f "${file}" ]] || continue
    base="$(basename "${file}")"
    cp -av "${file}" "${RELEASE_DIR}/xwrt-gale-v${GALE_VERSION}-${profile}-${base}"
  done
}

publish_output() {
  local out="${SRC}/bin/targets/ipq40xx/chromium"
  mkdir -p "${out}"
  cp -av "${RELEASE_DIR}/." "${out}/"
  (cd "${out}" && sha256sum *-factory.bin *-sysupgrade.bin > SHA256SUMS-GALE-V2)
}

main() {
  install_host_deps
  prepare_source
  patch_recovery_loop
  for profile in "${PROFILES[@]}"; do
    build_profile "${profile}"
  done
  publish_output
  log "Hoàn tất Lite, Standard và Ultimate"
}

main "$@"
