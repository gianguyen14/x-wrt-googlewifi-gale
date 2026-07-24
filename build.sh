#!/bin/bash
# =============================================================================
# X-Wrt Firmware Build Script for Google WiFi Gale
# With A/B Partition Support (512MB rootfs + 512MB data)
# =============================================================================
set -euo pipefail

# Configuration
XWRT_REPO="https://github.com/x-wrt/x-wrt.git"
XWRT_BRANCH="master"
BUILD_DIR="$(pwd)/x-wrt"
CUSTOM_DIR="$(pwd)/custom"
JOBS=$(nproc)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }

# =============================================================================
# Step 1: Install build dependencies
# =============================================================================
install_deps() {
    log "Installing build dependencies..."
    sudo apt-get update
    sudo apt-get install -y \
        build-essential clang flex bison g++ gawk \
        gcc-multilib g++-multilib gettext git libncurses5-dev \
        libssl-dev python3-distutils python3-setuptools rsync \
        swig unzip zlib1g-dev file wget curl \
        python3 python3-pip libelf-dev ecj fastjar java-propose-classpath \
        device-tree-compiler u-boot-tools fdisk gdisk
    log "Dependencies installed."
}

# =============================================================================
# Step 2: Clone X-Wrt source
# =============================================================================
clone_source() {
    if [ -d "$BUILD_DIR" ]; then
        warn "X-Wrt source already exists at $BUILD_DIR"
        info "Updating existing source..."
        pushd "$BUILD_DIR"
        git pull --rebase || true
        popd
    else
        log "Cloning X-Wrt source..."
        git clone --depth 1 -b "$XWRT_BRANCH" "$XWRT_REPO" "$BUILD_DIR"
    fi
}

# =============================================================================
# Step 3: Update & install feeds
# =============================================================================
setup_feeds() {
    log "Updating feeds..."
    pushd "$BUILD_DIR"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    popd
}

# =============================================================================
# Step 4: Apply custom files (A/B partition, packages, config)
# =============================================================================
apply_custom_files() {
    log "Applying custom files..."

    # Copy custom package: xwrt-ab-update
    mkdir -p "$BUILD_DIR/package/custom/xwrt-ab-update"
    cp -r "$CUSTOM_DIR/package/xwrt-ab-update/"* "$BUILD_DIR/package/custom/xwrt-ab-update/"

    # Copy custom image generation modifications
    if [ -f "$CUSTOM_DIR/target/chromium-ab.mk" ]; then
        cp "$CUSTOM_DIR/target/chromium-ab.mk" \
           "$BUILD_DIR/target/linux/ipq40xx/image/chromium-ab.mk"
    fi

    # Copy custom base-files overlays
    if [ -d "$CUSTOM_DIR/base-files" ]; then
        cp -r "$CUSTOM_DIR/base-files/"* \
           "$BUILD_DIR/target/linux/ipq40xx/base-files/" 2>/dev/null || true
    fi

    # Re-install feeds to pick up custom packages
    pushd "$BUILD_DIR"
    ./scripts/feeds update -a
    ./scripts/feeds install -a
    popd

    log "Custom files applied."
}

# =============================================================================
# Step 5: Configure build
# =============================================================================
configure_build() {
    log "Configuring build..."
    pushd "$BUILD_DIR"

    # Copy our .config
    cp "$CUSTOM_DIR/dot.config" .config

    # Expand config with defaults
    make defconfig

    log "Build configured. Target: ipq40xx/chromium (Google WiFi Gale)"
    popd
}

# =============================================================================
# Step 6: Download sources
# =============================================================================
download_sources() {
    log "Downloading package sources..."
    pushd "$BUILD_DIR"
    make download -j"$JOBS" || make download -j1 V=s
    popd
    log "Sources downloaded."
}

# =============================================================================
# Step 7: Build firmware
# =============================================================================
build_firmware() {
    log "Building firmware (this may take 1-3 hours on first build)..."
    pushd "$BUILD_DIR"
    make -j"$JOBS" V=s 2>&1 | tee build.log

    if [ $? -ne 0 ]; then
        warn "Parallel build failed, retrying with single thread..."
        make -j1 V=s 2>&1 | tee build-retry.log
    fi
    popd
    log "Build complete!"
}

# =============================================================================
# Step 8: Post-build - Create A/B factory image
# =============================================================================
create_ab_image() {
    log "Creating A/B factory image..."

    local OUTPUT_DIR="$BUILD_DIR/bin/targets/ipq40xx/chromium"
    local ROOTFS_IMG=$(find "$OUTPUT_DIR" -name "*google*squashfs*rootfs*" -o -name "*google*squashfs*factory*" | head -1)
    local KERNEL_IMG=$(find "$OUTPUT_DIR" -name "*google*fit*" -o -name "*google*kernel*" | head -1)

    if [ -z "$ROOTFS_IMG" ]; then
        warn "Could not find rootfs image. Listing available images:"
        ls -la "$OUTPUT_DIR/"*google* 2>/dev/null || ls -la "$OUTPUT_DIR/"
        return 1
    fi

    info "Rootfs image: $ROOTFS_IMG"
    info "Kernel image: $KERNEL_IMG"

    local AB_IMG="$OUTPUT_DIR/xwrt-gale-ab-factory.bin"
    local ROOTFS_SIZE=$((512 * 1024 * 1024))  # 512 MB
    local KERN_SIZE=$((16 * 1024 * 1024))      # 16 MB
    local DATA_SIZE=$((512 * 1024 * 1024))     # 512 MB
    local TOTAL_SIZE=$((KERN_SIZE + ROOTFS_SIZE + KERN_SIZE + ROOTFS_SIZE + DATA_SIZE + 2*1024*1024))

    log "Creating ${TOTAL_SIZE} byte A/B image..."

    # Create empty image
    dd if=/dev/zero of="$AB_IMG" bs=1M count=$((TOTAL_SIZE / 1024 / 1024))

    # Create GPT partition table
    sgdisk --clear "$AB_IMG"

    # Partition 1: KERN-A (16MB)
    sgdisk --new=1:2048:+16M --change-name=1:KERN-A \
           --typecode=1:FE3A2A5D-4F32-41A7-B725-ACCC3285A309 "$AB_IMG"

    # Partition 2: ROOT-A (512MB)
    sgdisk --new=2:0:+512M --change-name=2:ROOT-A \
           --typecode=2:3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC "$AB_IMG"

    # Partition 3: KERN-B (16MB)
    sgdisk --new=3:0:+16M --change-name=3:KERN-B \
           --typecode=3:FE3A2A5D-4F32-41A7-B725-ACCC3285A309 "$AB_IMG"

    # Partition 4: ROOT-B (512MB)
    sgdisk --new=4:0:+512M --change-name=4:ROOT-B \
           --typecode=4:3CB8E202-3B7E-47DD-8A3C-7FF2A13CFCEC "$AB_IMG"

    # Partition 5: DATA (512MB)
    sgdisk --new=5:0:+512M --change-name=5:DATA \
           --typecode=5:0FC63DAF-8483-4772-8E79-3D69D8477DE4 "$AB_IMG"

    # Set ChromeOS boot priority attributes for A/B slots
    # Slot A: priority=2, tries=0, successful=1 (active, known good)
    # Slot B: priority=1, tries=0, successful=0 (standby)
    sgdisk --attributes=1:=:0x0100000000000002 "$AB_IMG"  # KERN-A: priority=2, successful
    sgdisk --attributes=3:=:0x0000000000000001 "$AB_IMG"  # KERN-B: priority=1

    # Write kernel to KERN-A and KERN-B
    if [ -n "$KERNEL_IMG" ] && [ -f "$KERNEL_IMG" ]; then
        local KERN_A_OFFSET=$(sgdisk --info=1 "$AB_IMG" 2>/dev/null | grep "First sector" | awk '{print $3}')
        local KERN_B_OFFSET=$(sgdisk --info=3 "$AB_IMG" 2>/dev/null | grep "First sector" | awk '{print $3}')
        dd if="$KERNEL_IMG" of="$AB_IMG" bs=512 seek=$KERN_A_OFFSET conv=notrunc 2>/dev/null
        dd if="$KERNEL_IMG" of="$AB_IMG" bs=512 seek=$KERN_B_OFFSET conv=notrunc 2>/dev/null
    fi

    # Write rootfs to ROOT-A and ROOT-B
    if [ -f "$ROOTFS_IMG" ]; then
        local ROOT_A_OFFSET=$(sgdisk --info=2 "$AB_IMG" 2>/dev/null | grep "First sector" | awk '{print $3}')
        local ROOT_B_OFFSET=$(sgdisk --info=4 "$AB_IMG" 2>/dev/null | grep "First sector" | awk '{print $3}')
        dd if="$ROOTFS_IMG" of="$AB_IMG" bs=512 seek=$ROOT_A_OFFSET conv=notrunc 2>/dev/null
        dd if="$ROOTFS_IMG" of="$AB_IMG" bs=512 seek=$ROOT_B_OFFSET conv=notrunc 2>/dev/null
    fi

    log "A/B factory image created: $AB_IMG"
    log "Partition layout:"
    sgdisk --print "$AB_IMG"

    # Copy final images to output
    mkdir -p "$(pwd)/output"
    cp "$AB_IMG" "$(pwd)/output/"
    cp "$OUTPUT_DIR/"*google*sysupgrade* "$(pwd)/output/" 2>/dev/null || true

    log "=== Build Summary ==="
    info "Output images are in: $(pwd)/output/"
    ls -lh "$(pwd)/output/"
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "=========================================="
    log " X-Wrt Google WiFi Gale Build System"
    log " A/B Partition | rootfs=512MB | data=512MB"
    log "=========================================="

    case "${1:-all}" in
        deps)      install_deps ;;
        clone)     clone_source ;;
        feeds)     setup_feeds ;;
        custom)    apply_custom_files ;;
        config)    configure_build ;;
        download)  download_sources ;;
        build)     build_firmware ;;
        image)     create_ab_image ;;
        all)
            install_deps
            clone_source
            setup_feeds
            apply_custom_files
            configure_build
            download_sources
            build_firmware
            create_ab_image
            ;;
        *)
            echo "Usage: $0 {deps|clone|feeds|custom|config|download|build|image|all}"
            exit 1
            ;;
    esac
}

main "$@"
