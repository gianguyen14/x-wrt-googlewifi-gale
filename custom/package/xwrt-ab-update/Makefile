#
# xwrt-ab-update - A/B Partition Update System for Google WiFi Gale
#

include $(TOPDIR)/rules.mk

PKG_NAME:=xwrt-ab-update
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=X-Wrt Custom Build
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/xwrt-ab-update
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=A/B Partition Update System
  DEPENDS:=+bash +blkid +fdisk +coreutils-dd +e2fsprogs
  PKGARCH:=all
endef

define Package/xwrt-ab-update/description
  A/B dual root filesystem update system for Google WiFi Gale.
  Provides safe firmware updates with automatic rollback capability.
  Features:
  - Dual rootfs slots (A/B) for safe updates
  - Automatic rollback on boot failure
  - Persistent data partition across updates
  - ChromeOS Depthcharge bootloader integration
endef

define Build/Compile
endef

define Package/xwrt-ab-update/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/ab-sysupgrade $(1)/usr/sbin/ab-sysupgrade
	$(INSTALL_BIN) ./files/usr/sbin/ab-slot-info $(1)/usr/sbin/ab-slot-info
	$(INSTALL_BIN) ./files/usr/sbin/ab-rollback $(1)/usr/sbin/ab-rollback

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/ab-bootcheck $(1)/etc/init.d/ab-bootcheck

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-setup-data-partition $(1)/etc/uci-defaults/99-setup-data-partition

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/ab-update $(1)/etc/config/ab-update

	$(INSTALL_DIR) $(1)/lib/upgrade
	$(INSTALL_BIN) ./files/lib/upgrade/ab-platform.sh $(1)/lib/upgrade/ab-platform.sh
endef

define Package/xwrt-ab-update/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/ab-bootcheck enable
}
endef

$(eval $(call BuildPackage,xwrt-ab-update))
