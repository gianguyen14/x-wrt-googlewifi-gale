# X-Wrt Google WiFi Gale - A/B Partition Firmware

Custom X-Wrt (OpenWrt fork) firmware for **Google WiFi (Gale/AC-1304)** with **A/B dual rootfs partition** for safe firmware updates and automatic rollback.

## Hardware

| Spec | Value |
|------|-------|
| **SoC** | Qualcomm IPQ4019 |
| **RAM** | 512 MB |
| **Storage** | 4 GB eMMC |
| **WiFi** | 2.4GHz + 5GHz (802.11ac) |
| **Bootloader** | Coreboot/Depthcharge (ChromeOS) |

## Partition Layout

```
┌──────────┬──────────┬──────────┬──────────┬──────────┐
│  KERN-A  │  ROOT-A  │  KERN-B  │  ROOT-B  │   DATA   │
│  16 MB   │  512 MB  │  16 MB   │  512 MB  │  512 MB  │
│ (kernel) │ (rootfs) │ (kernel) │ (rootfs) │ (persist)│
└──────────┴──────────┴──────────┴──────────┴──────────┘
         Slot A              Slot B          Shared Data
```

## Features (Xiaomi Mi Mini WiFi Parity)

- **LuCI** web interface (SSL)
- **Dual-band WiFi**: 2.4GHz + 5GHz
- **VPN**: OpenVPN + WireGuard
- **USB Storage**: Samba4 file sharing
- **QoS**: SQM (CAKE) traffic shaping
- **Ad-blocking**: Adblock
- **NATFlow**: Hardware flow offloading (X-Wrt)
- **A/B Safe Update**: Firmware update with auto-rollback

## Quick Start

### Build Locally (Linux/WSL2)

```bash
# 1. Install dependencies & clone
chmod +x build.sh
./build.sh deps
./build.sh clone

# 2. Setup feeds & apply custom config
./build.sh feeds
./build.sh custom
./build.sh config

# 3. Download & build (1-3 hours first build)
./build.sh download
./build.sh build

# 4. Create A/B factory image
./build.sh image
```

Or run everything at once:
```bash
./build.sh all
```

### Build via GitHub Actions

1. Fork this repository
2. Go to **Actions** → **Build X-Wrt Google WiFi Gale A/B**
3. Click **Run workflow**
4. Download the firmware from the workflow artifacts

## Installation

### First Install (Factory Image)

1. Put Google WiFi into **Developer Mode** (see [OpenWrt Wiki](https://openwrt.org/toh/google/wifi))
2. Connect USB-C hub with power + USB drive containing the factory image
3. Boot from USB and flash to eMMC:
   ```bash
   dd if=xwrt-gale-ab-factory.bin of=/dev/mmcblk0 bs=1M conv=fsync
   ```
4. Reboot and access LuCI at `http://192.168.1.1`

### Firmware Updates (A/B Sysupgrade)

```bash
# Upload new firmware and flash to inactive slot
ab-sysupgrade /tmp/firmware-sysupgrade.bin

# Check current slot status
ab-slot-info

# Manually rollback to previous slot
ab-rollback
```

## A/B Update Commands

| Command | Description |
|---------|-------------|
| `ab-sysupgrade <image>` | Flash firmware to inactive slot & reboot |
| `ab-sysupgrade -t <image>` | Dry run (show what would be done) |
| `ab-slot-info` | Show current slot status & partition info |
| `ab-rollback` | Switch to the other slot & reboot |

## Project Structure

```
├── build.sh                          # Main build script
├── custom/
│   ├── dot.config                    # OpenWrt build configuration
│   ├── target/
│   │   └── chromium-ab.mk           # A/B image generation Makefile
│   └── package/
│       └── xwrt-ab-update/          # A/B update system package
│           ├── Makefile
│           └── files/
│               ├── usr/sbin/
│               │   ├── ab-sysupgrade    # A/B upgrade script
│               │   ├── ab-slot-info     # Slot info display
│               │   └── ab-rollback      # Manual rollback
│               ├── etc/
│               │   ├── init.d/ab-bootcheck         # Boot success marker
│               │   ├── config/ab-update             # UCI config
│               │   └── uci-defaults/99-setup-data-partition
│               └── lib/upgrade/
│                   └── ab-platform.sh   # Sysupgrade integration
└── .github/workflows/
    └── build.yml                     # GitHub Actions CI
```

## License

GPL-2.0 (same as OpenWrt/X-Wrt)
