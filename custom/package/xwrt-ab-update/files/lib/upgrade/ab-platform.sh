#!/bin/sh
# =============================================================================
# A/B Platform upgrade hooks for OpenWrt sysupgrade integration
# =============================================================================
# This is sourced by the OpenWrt upgrade framework to handle
# platform-specific upgrade behavior for A/B partition scheme.
# =============================================================================

. /lib/functions.sh

AB_EMMC_DEV="/dev/mmcblk0"

platform_ab_check_image() {
    local file="$1"

    # Verify the image is valid
    if [ ! -f "$file" ]; then
        echo "Image file not found: $file"
        return 1
    fi

    local file_size
    file_size=$(stat -c %s "$file" 2>/dev/null)

    # Check size doesn't exceed rootfs partition (512MB)
    local max_size=$((512 * 1024 * 1024))
    if [ "$file_size" -gt "$max_size" ]; then
        echo "Image too large: $file_size bytes > $max_size bytes (512MB)"
        return 1
    fi

    return 0
}

platform_ab_do_upgrade() {
    local file="$1"

    # Use ab-sysupgrade for the actual upgrade
    if [ -x /usr/sbin/ab-sysupgrade ]; then
        /usr/sbin/ab-sysupgrade -f "$file"
    else
        echo "ERROR: ab-sysupgrade not found"
        return 1
    fi
}
