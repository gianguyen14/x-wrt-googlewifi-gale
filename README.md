# X-WRT for Google WiFi Gen 1 (Gale)

Bộ script và cấu hình build X-WRT dành cho **Google WiFi Gen 1 / Gale** (`ipq40xx/chromium`).

Project sửa lỗi reboot vào Recovery do `base-config-setting-ext4fs` có thể xử lý nhầm `/dev/mmcblk0p1`, vốn là phân vùng ChromeOS kernel.

## Build trên Linux Mint / Ubuntu

```bash
git clone https://github.com/gianguyen14/x-wrt-googlewifi-gale.git
cd x-wrt-googlewifi-gale
chmod +x scripts/build.sh
JOBS=2 ./scripts/build.sh
```

Firmware nằm tại:

```text
~/xwrt-gale-build/x-wrt/bin/targets/ipq40xx/chromium/
```

## Cơ chế bảo vệ

- Tắt `base-config-setting-ext4fs`.
- Vá `disk_ready.preinit` để thoát ngay trên board `google,wifi`.
- Kiểm tra manifest sau build.
- Kiểm tra rootfs không còn `/lib/preinit/79_disk_ready`.

## Kiểm tra sau flash

```sh
blkid /dev/mmcblk0p1
sgdisk -i 1 /dev/mmcblk0
```

Phân vùng 1 phải là `ChromeOS kernel`, không được có `TYPE="ext4"`.

## Trạng thái

- [x] Build X-WRT cho Gale
- [x] Sửa lỗi reboot vào Recovery
- [x] LuCI và package quản trị chính
