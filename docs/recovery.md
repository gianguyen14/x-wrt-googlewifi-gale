# Recovery notes

Nếu `/dev/mmcblk0p1` đã bị format, cần boot môi trường recovery/USB và flash lại factory image vào eMMC.

Sau khi flash:

```sh
blkid /dev/mmcblk0p1
sgdisk -i 1 /dev/mmcblk0
```

Không cài `base-config-setting-ext4fs`.
