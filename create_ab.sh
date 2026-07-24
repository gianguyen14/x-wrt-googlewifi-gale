#!/bin/bash
set -e

BUILD_DIR="/build/x-wrt"
OUTPUT_DIR="$BUILD_DIR/bin/targets/ipq40xx/chromium"
DEST_DIR="/mnt/c/Users/mend4/OneDrive/Documents/Project/Xwrt/output"

mkdir -p "$DEST_DIR"

ROOTFS_IMG="$OUTPUT_DIR/openwrt-ipq40xx-chromium-google_wifi-squashfs-factory.bin"
SYSUPGRADE_IMG="$OUTPUT_DIR/openwrt-ipq40xx-chromium-google_wifi-squashfs-sysupgrade.bin"

echo "Found rootfs: $ROOTFS_IMG"
echo "Found sysupgrade: $SYSUPGRADE_IMG"

AB_IMG="$DEST_DIR/xwrt-gale-ab-factory.bin"
ROOTFS_SIZE=$((512 * 1024 * 1024))
KERN_SIZE=$((16 * 1024 * 1024))
DATA_SIZE=$((512 * 1024 * 1024))
TOTAL_SIZE=$((KERN_SIZE + ROOTFS_SIZE + KERN_SIZE + ROOTFS_SIZE + DATA_SIZE + 2*1024*1024))

echo "Creating ${TOTAL_SIZE} byte A/B image..."
dd if=/dev/zero of="$AB_IMG" bs=1M count=$((TOTAL_SIZE / 1024 / 1024)) conv=fsync

sgdisk --clear "$AB_IMG"
sgdisk --new=1:2048:+16M --change-name=1:KERN-A --typecode=1:FE3A2A5D-4F32-41A7-B725-ACCC3285A309 "$AB_IMG"
sgdisk --new=2:0:+512M --change-name=2:ROOT-A --typecode=2:3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC "$AB_IMG"
sgdisk --new=3:0:+16M --change-name=3:KERN-B --typecode=3:FE3A2A5D-4F32-41A7-B725-ACCC3285A309 "$AB_IMG"
sgdisk --new=4:0:+512M --change-name=4:ROOT-B --typecode=4:3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC "$AB_IMG"
sgdisk --new=5:0:+512M --change-name=5:DATA --typecode=5:0FC63DAF-8483-4772-8E79-3D69D8477DE4 "$AB_IMG"

sgdisk --attributes=1:=:0x0100000000000002 "$AB_IMG"
sgdisk --attributes=3:=:0x0000000000000001 "$AB_IMG"

ROOT_A_OFFSET=$(sgdisk --info=2 "$AB_IMG" | grep "First sector" | awk '{print $3}')
ROOT_B_OFFSET=$(sgdisk --info=4 "$AB_IMG" | grep "First sector" | awk '{print $3}')

echo "Writing ROOT-A at sector $ROOT_A_OFFSET and ROOT-B at sector $ROOT_B_OFFSET..."
dd if="$ROOTFS_IMG" of="$AB_IMG" bs=512 seek=$ROOT_A_OFFSET conv=notrunc
dd if="$ROOTFS_IMG" of="$AB_IMG" bs=512 seek=$ROOT_B_OFFSET conv=notrunc

cp "$SYSUPGRADE_IMG" "$DEST_DIR/"
cp "$OUTPUT_DIR/sha256sums" "$DEST_DIR/" 2>/dev/null || true
cp "$OUTPUT_DIR/openwrt-ipq40xx-chromium-google_wifi.manifest" "$DEST_DIR/" 2>/dev/null || true

echo "=== Output Images in $DEST_DIR ==="
ls -lh "$DEST_DIR"
