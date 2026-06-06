include $(TOPDIR)/rules.mk

PKG_NAME:=unbound-uci-ext
PKG_VERSION:=$(shell cat $(CURDIR)/VERSION)
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Guy Godfroy <guy.godfroy@gugod.fr>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/unbound-uci-ext
  SECTION:=net
  CATEGORY:=Network
  TITLE:=UCI extension for unbound `server:` directives
  URL:=https://github.com/openwrt-iac/unbound-uci-ext
  PKGARCH:=all
  DEPENDS:=+unbound-daemon
endef

define Package/unbound-uci-ext/description
  Exposes unbound `server:` directives that OpenWrt's main unbound package
  deliberately keeps out of UCI (`interface:`, `outgoing-interface:`,
  `ip-transparent:`, plus a raw passthrough). Generates the directives
  into a managed region of /etc/unbound/unbound_srv.conf - unbound's
  documented extended-conf seam - and restarts unbound. UCI namespace
  is /etc/config/unbound_ext.
endef

define Package/unbound-uci-ext/conffiles
/etc/config/unbound_ext
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/unbound-uci-ext/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/lib/unbound-uci-ext

	$(INSTALL_CONF) ./files/etc/config/unbound_ext $(1)/etc/config/unbound_ext
	$(INSTALL_BIN)  ./files/etc/init.d/unbound-uci-ext $(1)/etc/init.d/unbound-uci-ext
	$(INSTALL_BIN)  ./files/usr/lib/unbound-uci-ext/generator.sh $(1)/usr/lib/unbound-uci-ext/generator.sh
endef

define Package/unbound-uci-ext/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Render the managed region once so it's in place from first boot, even if
# the operator hasn't touched /etc/config/unbound_ext yet (the default
# config has `enabled '0'` so this is a no-op until they opt in).
/etc/init.d/unbound-uci-ext enable >/dev/null 2>&1 || true
/etc/init.d/unbound-uci-ext start >/dev/null 2>&1 || true
exit 0
endef

define Package/unbound-uci-ext/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Strip the managed region from /etc/unbound/unbound_srv.conf and restart
# unbound, so removal leaves no stale lines behind.
/etc/init.d/unbound-uci-ext stop >/dev/null 2>&1 || true
/etc/init.d/unbound-uci-ext disable >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,unbound-uci-ext))
